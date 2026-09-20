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
  debug = "flag",
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

--local handler = assert(args.handler, "Please specify a handler function.")
--if handler:find("%.lua$") then
--  handler = assert(loadfile(handler))()
--  assert(type(handler) == 'function', "Map file does not return a function.")
--else
--  handler = assert(load("return function(server, request) " .. handler .. " end", "=handler"))()
--end

function Server.Request:forward(uri, options)
  if not options then options = {} end
  local PACKET_SIZE = options.chunk or 4096
  local _, res = self.client.server.agent:request(options.method or self.method, uri, function() return self:read(chunk) end, { body = "nonblocking", timeout = self.client.server.timeout }, merge(self.headers, options.headers or {}))
  if res.code == 101 and res.headers.upgrade == "websocket" then 
    self:respond(Server.Response.new(res.code, res.headers))
    -- shuttle data back and forth
    loop:job(function() while not self.client.closed and not res.socket.closed do res.socket:write(self.client:read(PACKET_SIZE)) end self.client:close() res.socket:close() end)
    loop:job(function() while not res.socket.closed and not self.client.closed do self.client:write(res.socket:read(PACKET_SIZE)) end self.client:close() res.socket:close() end)
  else
    return Server.Response.new(res.code, res.headers, function() return res:read(PACKET_SIZE) end)
  end
end

local server = Server.new(merge(args, {
  agent = Client.new({ cookies = false })
}):add(loop)

if args.console then loop:add(0, function() server:console() end) end
loop:run()
