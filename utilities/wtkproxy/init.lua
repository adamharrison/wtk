local wtk = require "wtk.c"
local system = require "wtk.c.system"
local json = require "wtk.json.c"
local Server = require "wtk.server"
local Client = require "wtk.client.c"

local function arrayify(t) if type(t) == 'table' then return t else return { t } end end
local function merge(...) local r = {} for _, t in ipairs({ ... }) do for k, v in pairs(t) do r[k] = v end end return r end

local loop = wtk.Loop.new()
local args = wtk.pargs({ ... }, {
  help = "flag",
  version = "flag",
  verbose = "flag",
  debug = "flag",
  config = "string",
  console = "flag",
  host = "string",
  port = "string",
  handler = "string"
})
if args.version then
  io.stdout:write(VERSION .. "\n")
  os.exit(0)
elseif args.help then
  io.stderr:write([[
wtkproxy - A medium-performance proxy server.

Listens on a specified port for incoming HTTP requests, 

The following options are available:

  --host                host to listen on, by default 0.0.0.0.
  --port                port to listen on; can be either a path or integer
  --version             show the version
  --debug               enables debug mode
  --config              read and follow specified configuration a-la-nginx
  --cert                uses the ACME protocol to generate/renew a certificate
  --help                show the help

  In order to forward requests, you have a couple options.
  
  --handler function        specifies a lua file, or a lua chunk that routes the request

  Example handlers are:

  return request:forward("http://127.0.0.1", { headers = { ["X-Forwarded-For"] = request.client.peer } }):set_headers({ ["X-Responding-Server"] = "127.0.0.1" })

  If you want to use a config, you can have a JSON config file that looks something like this:

  {
    "servers": [
      {
        "http": ["0.0.0.0:80"],
        "https": ["0.0.0.0:443"],
        "hosts": [{
          "hostname": ["www.test.com", "test.com"],
          "ssl": {
            "key": "/var/www/server/key.key",
            "cert": "/var/www/server/cert.crt"
          },
          "execute": {
            "bin": ["/var/www/server"],
            "idle": 600
          }
        }, {
          "hostname": ["www.test2.com", "test2.com"],
          "ssl": {
            "key": "/var/www/server/key.key",
            "cert": "/var/www/server/cert.crt"
          },
          "forward": "http://127.0.0.1:4765"
        }, {
          "hostname": [".*%.test3%.com"],
          "location": {
            "/": {
              "static": "/var/www/server/root"
            }
          }
        }]
      }
    ]
  }
]])
  os.exit(0)
end

if args.handler then
  if args.handler:find("%.lua$") then
    args.handler = assert(loadfile(args.handler))()
    assert(type(args.handler) == 'function', "Map file does not return a function.")
  else
    args.handler = assert(load("return function(server, request) " .. args.handler .. " end", "=handler"))()
  end
end

function Server.Request:forward(uri, options)
  if not options then options = {} end
  local PACKET_SIZE = options.chunk or 4096
  local _, res = self.client.server.agent:request(options.method or self.method, uri, function() return self:read(chunk) end, { body = "nonblocking", timeout = self.client.server.timeout }, self.headers)
  if res.code == 101 and res.headers.upgrade == "websocket" then 
    self:respond(Server.Response.new(options.code or res.code, res.headers))
    -- shuttle data back and forth
    loop:job(function() while not self.client.closed and not res.socket.closed do res.socket:write(self.client:read(PACKET_SIZE)) end self.client:close() res.socket:close() end)
    loop:job(function() while not res.socket.closed and not self.client.closed do self.client:write(res.socket:read(PACKET_SIZE)) end self.client:close() res.socket:close() end)
  else
    return Server.Response.new(options.code or res.code, merge(res.headers, options.headers or {}), function() return res:read(PACKET_SIZE) end)
  end
end

function Server:get_host(host)
  host = host:gsub(":.*$", "")
  for _, server_host in ipairs(self.hosts or {}) do
    for _, hostname in ipairs(arrayify(server_host.hostname)) do
      if host:find("^" .. hostname .. "$") then
        return server_host
      end
    end
  end
  return nil
end

function Server:get_location(host, request)
  local t = {}
  for path, location in pairs(host.locations or {}) do
    table.insert(t, { path = path, location = location })
  end
  table.sort(t, function(a,b) return #a.path > #b.path end)
  for _, location in ipairs(t) do
    local s, e = request.path:find("^" .. location.path)
    if s then
      return merge(host, location.location), request.path:sub(e + 1)
    end
  end
  return nil
end

function Server.Client:handshake(client)
  if self.server.ssl then
    while true do
      local status, err = client.socket:handshake(function(hostname)
        local host = assert(self:get_host(hostname), "can't find host " .. hostname)
        return assert(host.ssl, "can't find ssl key"), assert(host.ssl, "can't find ssl cert")
      end)
      if status then break end
      client:yield(assert(err == "write" or err == "read" and err, err))
    end
  end
end


local proxy = {
  agent = Client.new({ cookies = false }),
  log = Server.Log.new(args.verbose),
  servers = {},
  handler = function(self, request)
    local host = assert(self:get_host(request.headers.host), { code = 404, message = "can't find host " .. (request.headers.host or "unknown") })
    local location, remainder = self:get_location(host, request)
    local target = location or host
    if target.forward then
      self.log:verbose("Forwarding request to %s...", target.forward)
      return request:forward(target.forward, target)
    elseif target.static then
      return request:file(target.static .. remainder, target.headers)
    elseif target.code then
      return request:respond(target.code, target.headers, target.body)
    else
      error({ code = 404 })
    end
  end
}

local function load_config(path)
  proxy.log:info("Loading configuration from %s...", path)
  for i, server in ipairs(proxy.servers) do server:stop(loop) end
  proxy.servers = {}
  local config = assert(json.decode(assert(io.open(path, "rb")):read("*all")))
  for _, server in ipairs(config.servers) do
    for _, http in ipairs(arrayify(server.http)) do
      local bind, port = http:match("^([^:]+):([^:]+)$")
      assert(bind, "can't decode bind " .. http)
      if port then port = tonumber(port) end
      table.insert(proxy.servers, Server.new(merge(args, { port = port, host = bind, hosts = server.hosts }, proxy)):add(loop))
    end
    for _, https in ipairs(arrayify(server.https)) do
      local bind, port = https:match("^([^:]+):([^:]+)$")
      assert(bind, "can't decode bind " .. https)
      if port then port = tonumber(port) end
      table.insert(proxy.servers, Server.new(merge(args, { port = port, host = bind, ssl = true, hosts = server.hosts }, proxy)):add(loop))
    end
  end
end

if args.config then 
  load_config(args.config)
  loop:signal(SIGHUP, function() load_config(args.config) end)
else
  Server.new(merge(proxy, args, { handler = handler })):add(loop)
end

local ACME = { test = false }
function ACME:ask_certify_domain(domain) end
function ACME:complete_certify_domain(domain) end
function ACME:issue_certificate(domain, public_key) end


loop:run()
