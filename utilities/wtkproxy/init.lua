local wtk = require "wtk.c"
local system = require "wtk.c.system"
local json = require "wtk.json.c"
local proc = require "wtk.proc.c"
local Server = require "wtk.server"
local Client = require "wtk.client.c"
local base64 = (require "wtk.server.c").base64

local function arrayify(t) if type(t) == 'table' then return t else return { t } end end
local function merge(...) local r = {} for _, t in ipairs({ ... }) do for k, v in pairs(t) do r[k] = v end end return r end
local function filter(func, t) local r = {} for i, v in ipairs(t) do if func(v,i) then table.insert(r, v)  end end return r end
local function map(func, t) local r = {} for i, v in ipairs(t) do table.insert(r, func(v,i)) end return r end
local function base64url(data) return base64.encode(data):gsub("%+", "-"):gsub("/", "_"):gsub("=", "") end

assert(ACME, "requires ACME to be defined by main.c")
ACME.__index = ACME
-- https://datatracker.ietf.org/doc/rfc8555/
function ACME.new(options) return setmetatable(merge({ test = false, log = Server.Log.new(), configdir = nil, private_key = nil, poll_interval = 5, client = Client.new({ cookies = false }), nonce = nil, token = function(domain, token, body) end }, options), ACME) end
function ACME:resolve(path) if path:find("^http") then return path end return string.format("https://%s.api.letsencrypt.org/acme%s", self.test and "acme-staging-v02" or "acme-v02", path) end
function ACME:jwk() local components = assert(ACME.components(self.private_key)) return { kty = "RSA", n = base64url(components.n), e = base64url(components.e) } end
function ACME:request(url, payload)
  local request_body = { 
    protected = base64url(json.encode(merge({ 
      alg = "RS256", 
      nonce = self.nonce or self:get_nonce(), 
      url = self:resolve(url) 
    }, self.account and { 
      kid = self.account 
    } or {
      jwk = self:jwk()
    }))),
    payload = payload and base64url(json.encode(payload)) or ""
  }
  request_body.signature = base64url(assert(ACME.sign(self.private_key, request_body.protected .. "." .. request_body.payload)))
  local url = self:resolve(url)
  self.log:verbose("POST %s", url)
  local body, res = self.client:post(url, json.encode(request_body), {}, { ['Content-Type'] = "application/jose+json" })
  self.nonce = assert(res.headers['replay-nonce'], "can't find Replay-Nonce")
  self.log:verbose("< %s", body)
  return json.decode(body), res
end
function ACME:get_nonce() self.log:verbose("HEAD %s", self:resolve("/new-nonce")) return assert(self.client:head(self:resolve("/new-nonce")).headers['replay-nonce'], "unable to get nonce") end
function ACME:get_account(email) -- by the ACME standard, this will not create a new account, if using the same public key
  local body, res = self:request("/new-acct", { termsOfServiceAgreed = true, contact = { "mailto:" .. email } })
  return assert(res.headers.location, "can't find account")
end
function ACME:create_order(domains, options) return self:request("/new-order", { identifiers = map(function(e) return { type = "dns", value = e } end, type(domains) == 'table' and domains or domains), notBefore = options.notBefore, notAfter = options.notAfter }) end
function ACME:get_certificate(email, key, domains, options) 
  options = options or {}
  self.account = self:get_account(email)
  local result, req = self:create_order(domains, options)
  local order = req.headers.location
  if not result.certificate and result.authorizations then
    for i, v in ipairs(result.authorizations) do
      while true do
        local authorization = self:request(v)
        local domain = authorization.identifier.value
        if authorization.status == "pending" then
          local challenge = assert(filter(function(e) return e.type == "http-01" end, authorization.challenges)[1], "cannot find http-01 challenge")
          local func = options.token or self.token
          local jwk = self:jwk()
          func(domain, challenge.token, challenge.token .. "." .. ACME.sha256(string.format('{"e":"%s","kty":"RSA","n":"%s"}', jwk.e, jwk.n)))
          self:request(challenge.url, json.empty_object)
        elseif authorization.challenge == "valid" then
          break
        end
        coroutine.yield(options.poll_interval or self.poll_interval)
      end
    end
    if not result.certificate then
      self:request(result.finalize, ACME.csr(key, arraify(domains)))
    end
    while not result.certificate do
      result = self:request(order)
      coroutine.yield(options.poll_interval or self.poll_interval)
    end
    return self:request(result.certificate)
  end
end

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
  acme = "string",
  live = "flag",
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
  --live                monitor the config file for changes, and autoamtically reload on modification
  --acme                uses the ACME protocol to generate/renew certificates as needed for those servers don't have one; takes an email
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
            "key_path": "/var/www/server/key.key",
            "cert_path": "/var/www/server/cert.crt"
          },
          "execute": {
            "bin": ["/var/www/server"],
            "idle": 600
          }
        }, {
          "hostname": ["www.test2.com", "test2.com"],
          "ssl": true,
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
        return assert(host.ssl.key, "can't find ssl key"), assert(host.ssl.cert, "can't find ssl cert")
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
  challenges = {},
  handler = function(self, request)
    local host = assert(self:get_host(request.headers.host), { code = 404, message = "can't find host " .. (request.headers.host or "unknown") })
    if proxy.challenges[host] then 
      local token = request.path:match("/.well-known/acme-challenge/([^/]+)")
      if token and proxy.challenges[token] then 
        proxy.log:info("Responding to challenge for %s at %s.", host, request.path)
        return request:respond(200, { ['Content-Type'] = "application/octet-stream" }, proxy.challenges[token])
      end
    end
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

local function decode_hosts(server)
  if server.ssl then
    for i, host in ipairs(server.hosts) do
      if host.ssl then
        if host.ssl == true then host.ssl = {} end
        if not host.ssl.key and host.ssl.key_path then host.ssl.key = assert(wtk.io.file(host.ssl.key_path, "rb")):read("*all") assert(ACME.component(host.ssl.key), "key specified at " .. host.ssl.key_path .. " is invalid") end
        if not host.ssl.cert and host.ssl.cert_path then host.ssl.cert = assert(wtk.io.file(host.ssl.cert_path, "rb")):read("*all") assert(ACME.cert(host.ssl.cert), "cert specified at " .. host.ssl.cert_path .. " is invalid") end
        if host.hostname then host.hostname = arrayify(host.hostname) end
      end
    end
  end
  return server
end

local function load_config(path)
  local add_acme = args.acme
  proxy.log:info("Loading configuration from %s...", path)
  for i, server in ipairs(proxy.servers) do server:stop(loop) end
  proxy.servers = {}
  local config = assert(json.decode(assert(wtk.io.file(path, "rb")):read("*all")))
  for _, server in ipairs(config.servers) do
    for _, http in ipairs(arrayify(server.http)) do
      local bind, port = http:match("^([^:]+):([^:]+)$")
      if port == 80 then add_acme = false end
      assert(bind, "can't decode bind " .. http)
      if port then port = tonumber(port) end
      table.insert(proxy.servers, decode_hosts(Server.new(merge(args, { port = port, host = bind, hosts = server.hosts, handler = handler }, proxy))):add(loop))
    end
    for _, https in ipairs(arrayify(server.https)) do
      local bind, port = https:match("^([^:]+):([^:]+)$")
      assert(bind, "can't decode bind " .. https)
      if port then port = tonumber(port) end
      table.insert(proxy.servers, decode_hosts(Server.new(merge(args, { port = port, host = bind, ssl = true, hosts = server.hosts, handler = handler }, proxy))):add(loop))
    end
  end
  if add_acme then table.insert(proxy.servers, Server.new(merge(args, { name = "ACME Server", port = 80, host = "0.0.0.0", handler = handler })):add(loop)) end
end

if args.config then 
  load_config(args.config)
  loop:signal(SIGHUP, function() load_config(args.config) end)
  if args.live then
    loop:job(function() 
      local mtime = assert(system.stat(args.config), "can't find config file").mtime
      while true do
        local nmtime = assert(system.stat(args.config), "can't find config file").mtime
        if mtime < nmtime then
          load_config(args.config)
          mtime = nmtime
        end
        coroutine.yield(1)
      end
    end)
  end
else
  Server.new(merge(proxy, args, { handler = handler })):add(loop)
end


if args.acme then
  proxy.acme = ACME.new({ token = function(domain, token, body)
    if not proxy.challenges[domain] then proxy.challenges[domain] = {} end
    proxy.challenges[domain][token] = body
  end, lenience = 30*24*60*60, directory = "./.acme", test = true, log = proxy.log })
  assert(args.acme:match("%w@%w+%.%w+"), "--acme should take an email")
  loop:job(function() 
    while true do
      proxy.log:info("Initializing ACME loop...")
      if not system.stat(proxy.acme.directory) then assert(system.mkdir(proxy.acme.directory)) end
      local key_path = proxy.acme.directory .. "/lets-encrypt.key"
      local certificate_directory_path = proxy.acme.directory .. "/certificates"
      if not system.stat(key_path) then 
        proxy.log:info("Generating ACME private key, storing at %s.", key_path)
        proxy.acme.private_key = proc.run(function() local private_key = assert(ACME.keypair()) io.stdout:write(private_key):close() end)
        assert(wtk.io.file(key_path, "wb")):write(proxy.acme.private_key):close()
      else
        proxy.acme.private_key = assert(wtk.io.file(key_path, "rb")):read("*all")
      end
      assert(ACME.components(proxy.acme.private_key))
      if not system.stat(certificate_directory_path) then assert(system.mkdir(certificate_directory_path)) end
      for _, server in ipairs(proxy.servers) do
        if server.ssl then
          for _, host in ipairs(server.hosts) do
            if host.ssl then
              local hostnames = filter(function(h) return not h:find("%*") end, host.hostname)
              if not host.ssl.key then host.ssl.key = proxy.acme.private_key end
              if #hostnames > 0 and (not host.ssl.cert or (os.time() - assert(ACME.cert(host.ssl.cert)).valid) < proxy.acme.lenience) then
                proxy.log:info("%s SSL certificate for %s...", host.ssl.cert and "Generating" or "Renewing", table.concat(host.hostname, ", "))
                host.ssl.cert = proxy.acme:get_certificate(args.acme, key, host.hostname)
                local target = host.ssl.cert_path or certificate_directory_path .. "/" .. host.hostname[1] .. ".crt"
                proxy.log:info("Successfully renewed SSL certificate for %s; writing to %s.", table.concat(arrayify(host.hostname), ", "), target)
                assert(wtk.io.file(target, "wb")):write(host.ssl.cert):close()
              end
            end
          end
        end
      end
      coroutine.yield(60*60)
    end
  end):fail(function(err) 
    proxy.log:error("Error during ACME loop: %s", err)
    proxy.log:verbose(err.stack)
  end)
end


loop:run()
