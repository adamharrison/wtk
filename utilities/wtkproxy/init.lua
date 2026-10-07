local wtk = require "wtk.c"
local system = require "wtk.c.system"
local json = require "wtk.json.c"
local proc = require "wtk.proc.c"
local Server = require "wtk.server"
local Client = require "wtk.client.c"
local base64 = (require "wtk.server.c").base64

local function arrayify(t) if type(t) == 'table' then return t else return { t } end end
local function base64url(data) return base64.encode(data):gsub("%+", "-"):gsub("/", "_"):gsub("=", "") end
wtk.monitor = monitor

assert(ACME, "requires ACME to be defined by main.c")
ACME.__index = ACME
-- https://datatracker.ietf.org/doc/rfc8555/
function ACME.new(options) return setmetatable(merge({ test = false, log = Server.Log.new(), configdir = nil, private_key = nil, poll_interval = 5, client = Client.new({ cookies = false }), nonce = nil, token = function(domain, token, body) end }, options), ACME) end
function ACME:resolve(path) if path:find("^http") then return path end return string.format("https://%s.api.letsencrypt.org%s", self.test and "acme-staging-v02" or "acme-v02", path) end
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
  self.log:verbose("> %s", json.encode(payload))
  local body, res = self.client:post(url, json.encode(request_body), {}, { ['Content-Type'] = "application/jose+json" })
  self.nonce = assert(res.headers['replay-nonce'], "can't find Replay-Nonce")
  self.log:verbose("< %s", body)
  if res.headers['content-type']:find("json") then body = json.decode(body) end
  return body, res
end
function ACME:get_nonce() self.log:verbose("HEAD %s", self:resolve(self:directory().newNonce)) return assert(self.client:head(self:resolve(self:directory().newNonce)).headers['replay-nonce'], "unable to get nonce") end
function ACME:directory() if not self._directory then self.log:verbose("GET %s", self:resolve("/directory")) local r = assert(self.client:get(self:resolve("/directory"))) self._directory = json.decode(r) end return self._directory end
function ACME:get_account(email) -- by the ACME standard, this will not create a new account, if using the same public key
  local body, res = self:request(self:directory().newAccount, { termsOfServiceAgreed = true, contact = { "mailto:" .. email } })
  return assert(res.headers.location, "can't find account")
end
function ACME:create_order(domains, options) return self:request(self:directory().newOrder, { identifiers = map(function(e) return { type = "dns", value = e } end, type(domains) == 'table' and domains or domains), notBefore = options.notBefore, notAfter = options.notAfter }) end
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
          func(domain, challenge.token, challenge.token .. "." .. base64url(ACME.sha256(string.format('{"e":"%s","kty":"RSA","n":"%s"}', jwk.e, jwk.n))))
          self:request(challenge.url, json.empty_object)
        elseif authorization.status == "valid" then
          break
        end
        coroutine.yield(options.poll_interval or self.poll_interval)
      end
    end
    if not result.certificate then
      local subjectOids = merge({ CN = domains[1], C = "CA", ST = "QC", L = "Montreal", O = "Independent" }, options)
      subjectOids = table.concat(map(function(e) return e .. "=" .. subjectOids[e] end, filter(function(e) return subjectOids[e] end, { "CN", "C", "ST", "O", "E", "L", "OU", "SERIALNUMBER" })),",")
      self:request(result.finalize, { csr = base64url(ACME.csr(key, subjectOids, arrayify(domains))) })
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
  quiet = "flag",
  verbose = "flag",
  vverbose = "flag",
  debug = "flag",
  config = "string",
  console = "flag",
  acme = "string",
  live = "flag",
  run = "flag"
})
if args.vverbose then args.verbose = true end
if args.version then
  io.stdout:write(VERSION .. "\n")
  os.exit(0)
elseif args.help or (not args.config and #args == 0) then
  io.stderr:write([[
wtkproxy - A medium-performance proxy server.

Listens on a specified port for incoming HTTP(s) requests.

The following options are available:

  --version             show the version
  --[v]verbose          become verbose
  --debug               enables debug mode
  --config              read and follow specified configuration a-la-nginx
  --live                monitor the config file for changes, and automatically reload on modification
  --acme                uses the ACME protocol to generate/renew certificates as needed for those servers don't have one; takes an email
  --help                show the help

In order to handle requests, you have a two options.

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
        "forward": "http://127.0.0.1:5888",
        "execute": {
          "bin": ["/var/www/server", "--port", "5888"],
          "idle": 600
        }
      }, {
        "hostname": ["www.test2.com", "test2.com"],
        "ssl": true,
        "forward": "http://127.0.0.1:4765"
      }, {
        "hostname": ["*.test3.com"],
        "location": {
          "/": {
            "static": "/var/www/server/root"
          }
        }
      }, {
        "hostname": ["*.test4.com"],
        "handler": "request:forward('http://127.0.0.1', { headers = { ['X-Forwarded-For'] = request.client.peer } }):set_headers({ ['X-Responding-Server'] = '127.0.0.1' })"
      }]
    }
  ]
}

If you do not specify a handler, or a config, wtkproxy will interpret the comamnd command line.
You can specify things exactly as in the server; separate servers with --server, and specify all keys at the server and host level with --key.
The above config can be replicated by doing:

wtkproxy --http 80 --https 443
  --host --hostname www.test.com test.com --ssl.key_path /var/www/server/key.key --ssl.cert_path /var/www/server/cert.crt --forward 'http://127.0.0.1:5888' --execute.bin "/var/www/server \\--port 5888" --execute.idle 600 
  --host --hostname www.test2.com test2.com --ssl true --forward 'http://127.0.0.1:4765'
  --host --hostname '*.test3.com' --location / --static /var/www/server/root
  --host --hostname '*.test4.com' --handler "request:forward('http://127.0.0.1', { headers = { ['X-Forwarded-For'] = request.client.peer } }):set_headers({ ['X-Responding-Server'] = '127.0.0.1' })"
]])
  os.exit(0)
end


function Server.Request:forward(uri, options)
  if not options then options = {} end
  local PACKET_SIZE = options.chunk or 1024
  local protocol, hostname, port, url = Client.componentsURI(uri)
  local agent = assert(Client:open(assert(protocol, { code = 400, message = "unable to parse uri: " .. uri }), hostname, port), { code = 502 })
  local headers = merge(self.headers or {}, {})
  if not options.suppress_forwards then
    headers['x-forwarded-host'] = self.headers.host
    headers['x-forwarded-for'] = self.client.peer
    headers['x-forwarded-proto'] = self.client.server.host and self.client.server.host:find("^unix://") and "unix" or (self.client.server.ssl and "https" or "http")
    headers['host'] = nil
  end
  local res = agent:request({ 
    log = self.client.server.vverbose and function(chunk, direction) self.log:verbose("%s %s", direction == "write" and ">" or "<", chunk) end, 
    method = options.method or self.method, 
    url = uri, 
    path = self.path,
    headers = headers,
    body = options.method ~= "GET" and options.method ~= "HEAD" and function() return self:read(PACKET_SIZE) end 
  })
  if res.code == 101 and res.headers.upgrade == "websocket" then 
    self.log:verbose("Request forward transforming to websocket.")
    self:respond(Server.Response.new(options.code or res.code, res.headers))
    -- shuttle data back and forth
    loop:job(function() while not self.client.closed and not res.socket.closed do res.socket:write(self.client:read(PACKET_SIZE)) end self.client:close() res.socket:close() end)
    loop:job(function() while not res.socket.closed and not self.client.closed do self.client:write(res.socket:read(PACKET_SIZE)) end self.client:close() res.socket:close() end)
  else
    self:respond(Server.Response.new(options.code or res.code, merge(res.headers, options.headers or {}), function() return res:read(PACKET_SIZE) end))
    agent:close()
    if res.headers.connection == "close" then self.client:close() end
  end
end

function Server:get_host(host)
  if host then host = host:gsub(":.*$", "") end
  for _, server_host in ipairs(self.hosts) do
    if not server_host.hostname then return server_host end
    for _, hostname in ipairs(server_host.hostname) do
      hostname = hostname:gsub("%.", "%%."):gsub("%-", "%%-"):gsub("%*", ".*")
      if host and host:find("^" .. hostname .. "$") then
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
      return location.location, request.path:sub(e + 1)
    end
  end
  return nil
end

function Server:get_log(host, server, request)

end


local proxy = {}
proxy.agent = Client.new({ cookies = false })
proxy.log = Server.Log.new(args.verbose)
if args.quiet then proxy.log.log = function() end end
proxy.servers = {}
proxy.challenges = {}

function Server.Client:handshake()
  if self.server.ssl then
    local status, err
    while true do
      status, err = self.socket:handshake(function(hostname)
        local host = assert(self.server:get_host(hostname), "can't find host " .. hostname)
        return assert(host.ssl and host.ssl.key, "can't find ssl key for " .. hostname), assert(host.ssl and host.ssl.cert, "can't find ssl cert for "  .. hostname)
      end)
      print("STATUS", status, err)
      self:yield(assert((err == "write" or err == "read") and err, err))
    end
  end
end



function proxy.parse_text(text) return text:find("{[{%%]") and Server.Template.parse(text) or text end
function proxy.render_text(text, request) 
  if getmetatable(text) == Server.Template then
    return text:render({ request = request })
  elseif type(text) == 'table' then 
    local t = {} for k,v in pairs(text) do t[k] = proxy.render_text(t[k], request) end return t 
  end 
  return text 
end

function proxy.startup_process(execute)
  proxy.log:info("Spinning up executable for %s.", execute.bin[1])
  local process = proc.new(assert(execute.bin, "missing bin option"), { wd = execute.wd, uid = execute.user })
  loop:job(function() while true do local chunk = process.stdout:read(1024) if not chunk then break end io.stdout:write(chunk) end end)
  loop:job(function() while true do local chunk = process.stderr:read(1024) if not chunk then break end io.stderr:write(chunk) end end)
  return process
end

function proxy.handler(self, request)
  request.host = request.headers.host and request.headers.host:gsub("%:%d+$", "")
  if request.headers.host and proxy.challenges[request.headers.host] then 
    local token = request.path:match("^/%.well%-known/acme%-challenge/([^/]+)$")
    if token and proxy.challenges[request.headers.host][token] then 
      proxy.log:info("Responding to challenge for %s at %s.", request.headers.host, token)
      return request:respond(200, { ['Content-Type'] = "application/octet-stream" }, proxy.challenges[request.headers.host][token])
    else
      proxy.log:info("Unknown challenge attempt for %s at %s.", request.headers.host, token)
    end
  end
  local host = assert(self:get_host(request.headers.host), { code = 404, message = "can't find host " .. (request.headers.host or "unknown") })
  local location, remainder = self:get_location(host, request)
  local target = location or host
  local path = (remainder or request.path)
  if target.log then
    local logfile = proxy.render_text(target.log, request)
    if request.client.logfile ~= logfile then
      request.client.log = Server.Log.new(args.verbose or false, assert(wtk.io.file(logfile, "ab")))
      request.client.logfile = logfile
    end
    request.log = request.client.log
  end
  request.log:verbose("REQ %s %s %s", request.method, request.path, request.client.peer)
  assert(not path:find("%/%.%."), { code = 403, message = "invalid path " .. path })
  target.last_request = os.time()
  if target.execute and (not target.running or target.running:status()) then
    target.running = proxy.startup_process(target.execute)
    if target.execute.idle then
      loop:job(function() while true do 
        local timeout = target.execute.idle - (os.time() - target.last_request)
        if target.running:status() or timeout <= 0 then
          request.log:info("Terminating executable for %s...", request.headers.host)
          request.log:info("Finished terminating executable for %s, exit code %d.", request.headers.host, target.running:term(target.execute.termout or 10))
          target.running = nil
          break
        else
          coroutine.yield(timeout) 
        end
      end end):fail(function(err)
        request.log:error("Error in idle check %s", err)
      end)
    end
    coroutine.yield(target.spinup or 0.1)
  end
  local headers = proxy.render_text(target.headers, request)
  if target.handler then
    request.log:verbose("Running custom handler...")
    target.handler(self, request)
  elseif target.forward then
    local forward = proxy.render_text(target.forward, request)
    request.log:verbose("Forwarding request to %s...", forward)
    request:forward(forward, merge(target, { headers = headers }))
  elseif target.static then
    local static = proxy.render_text(target.static, request)
    request.log:verbose("Serving static directory %s.", static .. path)
    request:file(static .. path, headers)
  elseif target.file then
    local file = proxy.render_text(target.file, request)
    request.log:verbose("Serving static file %s.", file)
    request:file(file, headers)
  elseif target.redirect then
    local redirect = proxy.render_text(target.redirect, request)
    request.log:verbose("Redirecting to %s.", redirect)
    request:redirect(redirect, headers)
  elseif target.code then
    request.log:verbose("Responding with code %d.", target.code)
    request:respond(tonumber(target.code), headers, proxy.render_text(target.body or '', request))
  else
    request.log:verbose("Unknown target action.", target.code)
    error({ code = 404 })
  end
  request.log._stream:flush()
end

local function load_handler(handler, param_names)
  if handler:find("%.lua$") then
    handler = assert(loadfile(handler))()
    assert(type(handler) == 'function', "Map file does not return a function.")
  else
    handler = assert(load("return function(" .. table.concat(param_names, ", ") .. ") " .. handler .. " end", "=handler"))()
  end
  return handler
end

local function compute_templates(t)
  for _, k in ipairs({ "forward", "static", "file", "redirect", "body", "log" }) do if t[k] ~= nil then t[k] = proxy.parse_text(t[k]) end end
  if t.headers then for k, v in pairs(t.headers) do t.headers[k] = proxy.parse_text(v) end end
  return t
end

local function decode_hosts(hosts)
  for i, host in ipairs(hosts or {}) do
    if host.ssl then
      if host.ssl == true then host.ssl = {} end
      if not host.ssl.key and host.ssl.key_path then host.ssl.key = assert(wtk.io.file(host.ssl.key_path, "rb")):read("*all") assert(ACME.component(host.ssl.key), "key specified at " .. host.ssl.key_path .. " is invalid") end
      if not host.ssl.cert and host.ssl.cert_path then host.ssl.cert = assert(wtk.io.file(host.ssl.cert_path, "rb")):read("*all") assert(ACME.cert(host.ssl.cert), "cert specified at " .. host.ssl.cert_path .. " is invalid") end
    end
    for path, location in pairs(host.locations or {}) do
      for k,v in pairs(host) do if location[k] == nil then location[k] = compute_templates(v) end end
    end
    if host.hostname then host.hostname = arrayify(host.hostname) end
    if host.handler then host.handler = load_handler(host.handler, { "server", "request" }) end
    if host.execute and not host.execute.idle then loop:add(function() host.running = proxy.startup_process(host.execute) end) end
    if host.jobs then host.jobs = map(function(e) return load_handler(e, { "host", "proxy" }) end, host.jobs) end
    compute_templates(host)
  end
  return hosts
end


local function load_config(config)
  local add_acme = args.acme
  for i, server in ipairs(proxy.servers) do 
    server:stop(loop)
    for _, host in ipairs(server.hosts) do
      if host.running then host.running:term(5) host.running = nil end
      for i,v in ipairs(host.jobs or {}) do loop:rm(v) end host.jobs = {}
    end
  end
  proxy.servers = {}
  collectgarbage()
  proxy.log:verbose("Loading configuration %s.", json.encode(config))
  for _, server in ipairs(config.servers) do
    local hosts = server.hosts and decode_hosts(server.hosts) or decode_hosts({ merge(server, { }) })
    for _, http in ipairs(arrayify(server.http)) do
      local bind, port = http:match("^([^:]+):?([^:]-)$")
      assert(bind, "can't decode bind " .. http)
      if not port or port == "" then port, bind = bind, "0.0.0.0" end
      if port then port = tonumber(port) end
      if port == 80 then add_acme = false end
      table.insert(proxy.servers, Server.new(merge(args, { port = port, host = bind, hosts = hosts, handler = proxy.handler }, proxy)):add(loop))
    end
    for _, https in ipairs(arrayify(server.https)) do
      local bind, port = https:match("^([^:]+):?([^:]-)$")
      assert(bind, "can't decode bind " .. https)
      if not port or port == "" then port, bind = bind, "0.0.0.0" end
      if port then port = tonumber(port) end
      table.insert(proxy.servers, Server.new(merge(args, { port = port, host = bind, ssl = true, hosts = hosts, handler = proxy.handler }, proxy)):add(loop))
    end
    for _, host in ipairs(hosts or {}) do host.jobs = map(function(v) 
      proxy.log:verbose("Spinning up job for " .. host.hostname[1] .. "...")
      return loop:job(function() coroutine.yield() v(host, proxy) end):fail(function(err) proxy.log:error("%s", err) proxy.log:error("%s", err.stack) end)
    end, host.jobs or {}) end
  end
  if add_acme then table.insert(proxy.servers, Server.new(merge(args, { name = "ACME Server", port = 80, host = "0.0.0.0", handler = proxy.handler })):add(loop)) end
  assert(#proxy.servers > 0, "you have listed no active servers")
end

local function split(splitter, str)
  local o = 1
  local res = {}
  while true do
      local s, e = str:find(splitter, o)
      table.insert(res, str:sub(o, s and (s - 1) or #str))
      if not s then break end
      o = e + 1
  end
  return res
end

local function transpile_config(contents)
  contents = contents:gsub("\n%s*%/%/.-\n", "\n"):gsub("```(.-)```", function(e) return '"' .. table.concat(split("\n", e:gsub('"', '\\"')), "\\n") .. '"' end)
  return assert(json.decode(contents))
end

local function load_config_path(path)
  proxy.log:info("Loading configuration from %s...", path)
  return load_config(transpile_config(assert(wtk.io.file(path, "rb")):read("*all")))
end

-- ./wtkproxy --http 80 --https 443\
--     --host --hostname www.test.com test.com --ssl.key_path /var/www/server/key.key --ssl.cert_path /var/www/server/cert.crt --forward 'http://127.0.0.1:5888' --execute.bin /var/www/server \\--port 5888 --execute.idle 600\
--     --host --hostname www.test2.com test2.com --ssl true --forward 'http://127.0.0.1:4765'\
--     --host --hostname '.*%.test3%.com' --location / --static /var/www/server/root

local function load_arg_config(args)
  proxy.log:info("Loading configuration from arguments...")
  local config = { servers = {} }
  if args[1] ~= "--server" then table.insert(args, 1, "--server") end
  local array_keys = { server = 1, host = 2  }
  local hash_keys = { location = 3 }
  local target = { }
  local function get(orig, target) for i = 1, #target do if type(target[i]) == 'string' then for _, v in ipairs(split('%.', target[i])) do if not orig[v] then orig[v] = {} end orig = orig[v] end else orig = orig[target[i]] end end return orig end
  local function set(orig, target, value) 
    for i = 1, #target do 
      if type(target[i]) == 'string' then 
        local s = split('%.', target[i])
        for j, v in ipairs(s) do 
          if not orig[v] then orig[v] = {} end 
          if i == #target and j == #s  then
            orig[v] = value
          else
            orig = orig[v]
          end
        end 
      else 
        orig = orig[target[i]] 
      end 
    end
  end
  for i, arg in ipairs(args) do
    if arg:find("^%-%-") then 
      if not hash_keys[target[#target]] and type(target[#target]) ~= "number" then table.remove(target) end
      local key = arg:sub(3)
      if array_keys[key] then
        if #target < 2 or target[#target-1] ~= (key .. "s") or type(target[#target]) ~= 'number' then  
          table.insert(target, key .. "s") 
          set(config, target, {}) 
        end
        if #target >= 2 and target[#target - 1] == key .. "s" and type(target[#target]) == 'number' then
          table.remove(target)
        end
        table.insert(get(config, target), {})
        table.insert(target, #get(config, target))
      elseif hash_keys[key] then
        set(config, target, arg)
      else
        table.insert(target, key)
      end
    else
      arg = arg:gsub("^\\", "")
      local value = get(config, target)
      if value ~= nil and type(value) ~= 'table' then
        set(config, target, { value, arg })
      elseif type(value) == 'table' and #value > 0 then
        table.insert(value, arg)
      else
        set(config, target, arg)
      end
    end
  end
  load_config(config)
end

try(function()
  if args.config then 
    load_config_path(args.config)
    loop:signal(SIGHUP, function() proxy.log:info("Received SIGHUP, reloading config.") load_config_path(args.config) end)
    if args.live then
      loop:job(function() 
        local mtime = assert(system.stat(args.config), "can't find config file").mtime
        while true do
          local nmtime = assert(system.stat(args.config), "can't find config file").mtime
          if mtime < nmtime then
            load_config_path(args.config)
            mtime = nmtime
          end
          coroutine.yield(1)
        end
      end)
    end
  else
    load_arg_config(args)
  end
end, function(err)
  proxy.log:error("%s: %s", err, err.stack)
end)


if args.acme then
  proxy.acme = ACME.new({ token = function(domain, token, body)
    if not proxy.challenges[domain] then proxy.challenges[domain] = {} end
    proxy.log:info("Filing challenge for %s of token %s.", domain, token)
    proxy.challenges[domain][token] = body
  end, lenience = 30*24*60*60, configdir = "./.acme", log = proxy.log })
  local certificate_directory_path = proxy.acme.configdir .. "/certificates"
  assert(args.acme:match("%w@%w+%.%w+"), "--acme should take an email")
  function proxy.get_certificate(host, hostnames, key, cert)
    if not key then 
      local key_path = host and host.ssl and host.ssl.key_path or certificate_directory_path .. "/" .. hostnames[1] .. ".key"
      if not system.stat(key_path) then 
        proxy.log:info("Generating %s private key, storing at %s (this can take a while on slower systems)...", hostnames[1], key_path)
        key = assert(proc.run(function() local private_key = assert(ACME.keypair()) io.stdout:write(private_key):close() end))
        proxy.log:info("%s private key generated at %s.", host.hostname[1], key_path)
        assert(wtk.io.file(key_path, "wb")):write(key):close()
      else
        key = assert(wtk.io.file(key_path, "rb")):read("*all")
      end
    end
    local cert_path = host and host.ssl and host.ssl.cert_path or certificate_directory_path .. "/" .. hostnames[1] .. ".crt"
    if not cert then
      cert = system.stat(cert_path) and assert(wtk.io.file(cert_path, "rb")):read("*all")
    end
    if #hostnames > 0 and (not cert or (assert(ACME.cert(cert)).valid_to - os.time()) < proxy.acme.lenience) then
      proxy.log:info("%s SSL certificate for %s...", cert and "Generating" or "Renewing", table.concat(hostnames, ", "))
      cert = proxy.acme:get_certificate(args.acme, key, hostnames)
      proxy.log:info("Successfully renewed SSL certificate for %s; writing to %s.", table.concat(arrayify(hostnames), ", "), cert_path)
      assert(wtk.io.file(cert_path, "wb")):write(cert):close()
    end
    return key, cert
  end
  
  loop:job(function() 
    proxy.log:info("Initializing ACME loop...")
    while true do
      proxy.log:info("Performing SSL ACME check...")
      if not system.stat(proxy.acme.configdir) then assert(system.mkdir(proxy.acme.configdir)) end
      local key_path = proxy.acme.configdir .. "/lets-encrypt.key"
      if not system.stat(key_path) then 
        proxy.log:info("Generating ACME private key, storing at %s (this can take a while on slower systems)...", key_path)
        proxy.acme.private_key = assert(proc.run(function() local private_key = assert(ACME.keypair()) io.stdout:write(private_key):close() end))
        proxy.log:info("ACME private key generated at %s.", key_path)
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
              if #hostnames > 0 then
                host.ssl.key, host.ssl.cert = proxy.get_certificate(host, hostnames, host.ssl.key, host.ssl.cert)                
              end
            end
          end
        end
      end
      proxy.log:info("SSL ACME check loop complete.")
      coroutine.yield(60*60)
    end
  end):fail(function(err) 
    proxy.log:error("Error during ACME loop: %s", err)
    proxy.log:verbose(err.stack)
  end)
end

if args.run ~= false then loop:run() end
