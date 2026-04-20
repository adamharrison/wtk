local wtk = require "wtk.c"
local system = require "wtk.c.system"
local Server = require "wtk.server"
local Client = require "wtk.client.c"

local function merge(...) local r = {} for _, t in ipairs({ ... }) do for k, v in pairs(t) do r[k] = v end end return r end

local loop = wtk.Loop.new()
local args = wtk.pargs({ ... }, {
  help = "flag",
  version = "flag",
  verbose = "flag",
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
  --console             enables a console on stdin
  --help                show the help

  In order to forward requests, you have a couple options.
  
  --handler function        specifies a lua file, or a lua chunk that routes the request

  Example handlers are:

  return request:forward("http://127.0.0.1", { headers = { ["X-Forwarded-For"] = request.client.peer } }):set_headers({ ["X-Responding-Server"] = "127.0.0.1" })
]])
  os.exit(0)
end

local handler = assert(args.handler, "Please specify a handler function.")
if handler:find("%.lua$") then
  handler = assert(loadfile(handler))()
  assert(type(handler) == 'function', "Map file does not return a function.")
else
  handler = assert(load("return function(server, request) " .. handler .. " end", "=handler"))()
end

function Server.Request:forward(uri, options)
  local _, res = self.client.server.agent:request(options and options.method or self.method, uri, function() return self:read(options and options.chunk or 4096) end, { body = "nonblocking", timeout = self.client.server.timeout }, merge(self.headers, options and options.headers or {}))
  return Server.Response.new(res.code, res.headers, function() return res:read(options and options.chunk or 4096) end)
end

local server = Server.new({
  host = args.host or "0.0.0.0",
  agent = Client.new({ cookies = false }),
  port = args.port or 9090,
  timeout = args.timeout or 10,
  verbose = args.verbose,
  debug = args.debug,
  handler = handler
}):add(loop)
if args.console then loop:add(0, function() server:console() end) end
loop:run()
