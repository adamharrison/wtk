-- We go for simplicity above all else.
local driver = require "wtk.server.driver"
local socket, loop, sha1, base64 = driver.socket, driver.loop, driver.sha1, driver.base64
local PACKET_SIZE = 4096

local Server = { Loop = driver.loop, Socket = driver.socket, sha1 = driver.sha1, base64 = driver.base64 }
Server.__index = Server


Server.Websocket = { op = { CONT = 0x0, TEXT = 0x1, BINARY = 0x2, CLOSE = 0x8, PING = 0x9, PONG = 0xA } }
Server.Websocket.__index = Server.Websocket
function Server.Websocket.new(client) return setmetatable({ client = client }, Server.Websocket) end
function Server.Websocket:handshake(request)
  assert(request.headers["sec-websocket-key"], "Missing required header.")
  self.client:respond(101, { Upgrade = "websocket", Connection = "Upgrade", ["Sec-WebSocket-Accept"] = base64.encode(sha1.binary(request.headers["sec-websocket-key"] .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")) })
  return self
end
function Server.Websocket:write(message, opcode)
  if not opcode then opcode = Server.Websocket.op.TEXT end
  local fin, rsv1, rsv2, rsv3, opcode, masked = 1, 0, 0, 0, Server.Websocket.op.TEXT, 0
  local first_byte = ((fin << 7) | (rsv1 << 6) | (rsv2 << 5) | (rsv3 << 4)) | opcode
  local t = { string.pack("I1", first_byte) }
  if #message <= 125 then
    table.insert(t, string.pack("!1>I1", (masked << 7) | #message))
  elseif #message <= 65535 then
    table.insert(t, string.pack("!1>I1I2", (masked << 7) | 126, #message))
  else
    table.insert(t, string.pack("!1>I1I8", (masked << 7) | 127, #message))
  end
  table.insert(t, message)
  self.client:write(table.concat(t))
end
function Server.Websocket:read()
  local accumulator, original_opcode = ""
  while true do
    local packet = self.client:read(2)
    if not packet then return nil end
    local fin, rsv1, rsv2, rsv3, opcode, masked = packet:byte(1) >> 7, (packet:byte(1) >> 6) & 0x1, (packet:byte(1) >> 5) & 0x1, (packet:byte(1) >> 4) & 0x1, (packet:byte(1) & 0xF), packet:byte(2) >> 7
    if opcode ~= 0 then original_opcode = opcode end
    local length = packet:byte(2) & 0x7F
    if length == 126 then
      length = string.unpack(">I2", self.client:read(2))
    elseif length == 127 then
      length = string.unpack(">I8", self.client:read(8))
    end
    assert(masked, "making bit should be set")
    local mask = self.client:read(4)
    local encoded = self.client:read(length)
    local decoded = {}
    for i = 1, #encoded do table.insert(decoded, string.char(encoded:byte(i) ~ mask:byte(((i - 1) % 4) + 1))) end
    accumulator = table.concat(decoded)
    if opcode == Server.Websocket.op.PING then 
      self:write(Server.Websocket.op.PONG, accumulator)
      accumulator, original_opcode = "", nil
    elseif opcode == Server.Websocket.op.CLOSE then
      self.client:close()
      return nil, original_opcode
    elseif fin then
      break
    end
  end
  return accumulator, original_opcode
end


local Response = { }
Response.__index = Response
function Response.new(code, headers, body) return setmetatable({ code = code, headers = headers or {}, body = body }, Response) end
function Response:write(client)
  local parts = { string.format("%s %d %s\r\n", "HTTP/1.1", self.code, client.server.codes[self.code]) }
  if self.body and not self.headers['content-length'] then self.headers['content-length'] = #self.body end
  if not self.headers['connection'] then self.headers['connection'] = 'keep-alive' end
  for key,value in pairs(self.headers) do table.insert(parts, string.format("%s: %s\r\n", key, value)) end
  table.insert(parts, "\r\n")
  client:write(table.concat(parts))
  if self.body then client:write(self.body) end
  if client.server.verbose then
    if self.code >= 300 and self.code < 400 then
      client.server.log:verbose("RES %s %s %s", self.code, client.peer, self.headers.location)
    else
      client.server.log:verbose("RES %s %s", self.code, client.peer)
    end
  end
end

local Request = { }
Server.Request = Request
Request.__index = Request
function Request.new(client) 
  return setmetatable({ method = nil, client = client, path = nil, version = nil, headers = {}, buffer = {}, cookies = {}, responded = false, length_read = 0 }, Request) 
end
function Request:parse_headers()
  while #self.buffer == 0 or not self.buffer[#self.buffer]:find("\r\n\r\n") do
    local packet = self.client:read(PACKET_SIZE)
    if packet then
      table.insert(self.buffer, packet)
    else
      error({ code = 500, message = "Client unexpectedly closed connection.", verbose = true })
    end
  end
  local headers, remainder
  self.method, self.path, self.version, headers, remainder = table.concat(self.buffer):match("^(%S+) (%S+) (%S+)\r\n(.-\r\n)\r\n(.*)$")
  self.params, self.path, self.search = {}, self.path:match("^([^?]+)(%??[^?]*)$")
  assert(self.method and self.path, "malformed request")
  if self.search then for key,value in self.search:gmatch("([^=]+)=([^&]+)") do self.params[key] = value:gsub("%%([a-fA-F0-9][a-fA-F0-9])", function(e) return string.char(tonumber(e, 16)) end) end end
  for key,value in headers:gmatch("([^%:]+):%s*(.-)\r\n") do self.headers[key:lower()] = value end
  for key,value in (self.headers.cookie or ""):gmatch("([^=]+)=([^;]+)") do self.cookies[key] = value:gsub("%%([a-fA-F0-9][a-fA-F0-9])", function(e) return string.char(tonumber(e, 16)) end) end
  if #remainder > 0 then self.client.buffer = remainder end
  assert(self.method == "GET" or self.headers['content-length'], "malformed request, requires content-length")
  self.client.server.log:verbose("REQ %s %s %s", self.method, self.path, self.client.socket:peer())
  return self
end
function Request:websocket()
  self.client.websocket = Server.Websocket.new(self.client):handshake(self)
  return self.client.websocket
end
function Request:body() if self.method == "GET" or self._body then return self._body end self._body = self:read(self.headers['content-length'] - self.length_read) return self._body end
function Request:read(len) local str = self.client:read(len) self.length_read = self.length_read + #str return str end
function Request:respond(code, headers, body) 
  self.responded = true 
  if not headers['set-cookie'] and self.cookies then 
    local cookies = {}
    for key,value in pairs(self.cookies) do table.insert(cookies, key .. "=" .. tostring(value):gsub("[%c:/?#%[%]@!$&'\"%(%)*+,;=%%]", function(e) return "%" .. string.format("%02x", e) end)) end
    if #cookies > 0 then headers['set-cookie'] = table.concat(cookies, ';') end
  end
  Response.new(code, headers, body):write(self.client) 
  return self 
end
function Request:redirect(path) return self:respond(302, { ["location"] = path }) end
function Request:file(path) return self:respond(200, { ['content-type'] = self.client.server:mimetype(path) }, assert(io.open(path, "rb"), { code = 404 }):read("*all")) end

local Client = {}
Client.__index = Client
function Client.new(server, socket) return setmetatable({ last_activity = os.time(), server = server, waiting = nil, socket = socket, responsed = false, peer = socket:peer() }, Client) end
function Client:write(buf) self.last_activity = os.time() return self.socket:send(buf) end
function Client:read(len) 
  self.last_activity = os.time() 
  if self.buffer then
    local buffer = self.buffer
    if #self.buffer > len then
      self.buffer = buffer:sub(len + 1)
      return buffer:sub(1, len)
    else
      self.buffer = nil
      return buffer
    end
  end
  while not self.closed do
    local packet, err = self.socket:recv(len) 
    if packet and #packet > 0 then return packet end
    if err == "timeout" then
      self:yield()
    elseif err == "closed" then
      self.closed = true
    else
      error({ code = 500, message = "Failed reading from socket: " .. err })
    end
  end
end
function Client:close() self.server.log:verbose("Manually closing connnection.") self.socket:close() self.closed = true end
function Client:yield() coroutine.yield({ socket = self.socket, edge = true }) end
function Client:process()
  while coroutine.status(self.co) ~= "dead" do
    local status, result = coroutine.resume(self.co)
    if coroutine.status(self.co) ~= "dead" and result then
      if self.waiting and self.waiting ~= result.socket then 
        self.server.loop:rm(self.waiting) 
        self.waiting = nil 
      end
      if not self.waiting and (result.socket or result.waiting) then
        self.waiting = self.server.loop:add(result.socket or timer.new(result.timeout), function() self:process() end, result.edge)
      end
      break
    end
  end
  if self.waiting then
    self.server.loop:rm(self.waiting)
  end
end

function Server.new(t) 
  t.socket = assert(socket.bind(t.host or "0.0.0.0", t.port or 80), "unable to bind")
  t.mimes = { ["jpeg"] = "image/jpeg", ["jpg"] = "image/jpeg", ["png"] = "image/png", ["gif"] = "image/gif", ["js"] = "text/javascript", ["html"] = "text/html", ["css"] = "text/css", ["txt"] = "text/plain" }
  t.codes = { [101] = "Switching Protocols", [200] = "OK", [201] = "Created", [204] = "No Content", [301] = "Moved Permanently", [302] = "Found", [400] = "Bad Request", [403] = "Forbidden", [404] = "Not Found", [500] = "Internal Server Error" }
  t.routes = { GET = { }, POST = { }, PUT = { }, DELETE = { } }
  local self = setmetatable(t, Server) 
  self.log._verbose = t.verbose
  self.log:info("Server up on %s:%s", self.socket:peer())
  return self
end

function Server:accept()
  local socket = self.socket:accept()
  if socket then 
    local client = Client.new(self, socket)
    self.log:verbose("Incoming connection from '%s'", socket:peer())
    client.co = coroutine.create(function() 
      while not client.closed do
        local request
        xpcall(function()
          request = Request.new(client):parse_headers()
          self:accepted(client, request)
          if not request.responded then error({ code = 404 }) end
        end, function(err)
          if type(err) == 'table' and err.code and type(err.code) == "number" then
            local msg = string.format("%d Error", err.code)
            if err.message then msg = msg .. ": " .. err.message end
            if self.verbose or not err.verbose then self.log:error(msg) end
            if not request.responded then request:respond(err.code, { ["Content-Type"] = "text/plain; charset=UTF-8" }, err.code .. " " .. self.codes[err.code] .. "\n") end
          else
            local msg = string.format("Unhandled Error: %s", err) 
            if self.verbose then self.log:error(debug.traceback(msg, 3)) else self.log:error(msg) end
            if not request.responded then request:respond(500, { ["Content-Type"] = "text/plain; charset=UTF-8" }, "500 Internal Server Error") end
          end
        end)
        -- clear out buffer if it wasn't read
        request:body()
      end
    end)
    return client
  else
    log:error("Error accepting client.")
  end
end
function Server:add(loop)
  loop:add(self.socket, function() 
    self:accept():process() 
  end)
  self.loop = loop
  return self
end
function Server:stop(loop) self.loop:remove(self.socket) end
function Server:accepted(client, request)
  (self.handler or self.default_handler)(self, request)
end
function Server:mimetype(file)
  local extension = file:match("%.(%w+)$")
  return extension and self.mimes[extension] or "text/plain"
end

function Server:default_handler(request)
  for i, route in pairs(self.routes[request.method] or {}) do
    local results = { request.path:match(route.path) }
    if results and #results > 0 then
      for i,v in ipairs(results) do if v == "" then results[i] = false end end
      return route.handler(request, table.unpack(results))
    end
  end
end
function Server:route(method, path, func) table.insert(self.routes[method], { path = "^" .. path .. "$", handler = func }) table.sort(self.routes[method], function(a,b) return #a.path > #b.path end) end
function Server:get(path, func) return self:route("GET", path, func) end
function Server:post(path, func) return self:route("POST", path, func) end
function Server:put(path, func) return self:route("PUT", path, func) end
function Server:delete(path, func) return self:route("DELETE", path, func) end

Server.log = {}
function Server.log:log(type, message, ...) io.stdout:write(string.format("[%5s][%s]: " .. message .. "\n", type, os.date("%Y-%m-%dT%H:%M:%S"), ...)):flush() end
function Server.log:verbose(message, ...) if self._verbose then self:log("VERB", message, ...) end end
function Server.log:info(message, ...) self:log("INFO", message, ...) end
function Server.log:error(message, ...) self:log("ERROR", message, ...) end

function Server.escapeURI(param) return param:gsub("[^A-Za-z0-9%-_%.%!~%*'%(%)]", function(e) return string.format("%%%02x", e:byte(1)) end) end
function Server.pargs(arguments, options)
  local args = {}
  local i = 1
  for k,v in pairs(arguments) do if math.type(k) ~= "integer" then args[k] = v end end
  while i <= #arguments do
    local s,e, option, value = arguments[i]:find("%-%-([^=]+)=?(.*)")
    local option_name = s and (options[option] and option or option:gsub("^no%-", ""))
    if options[option_name] then
      local flag_type = options[option_name]
      if flag_type == "flag" then
        args[option] = (option_name == option or not option:find("^no-")) and true or false
      elseif flag_type == "string" or flag_type == "number" or flag_type == "array" then
        if not value or value == "" then
          if i == #arguments then error("option " .. option .. " requires a " .. flag_type) end
          value = arguments[i+1]
          i = i + 1
        end
        if flag_type == "number" and tonumber(flag_type) == nil then error("option " .. option .. " should be a number") end
        if flag_type == "array" then
          args[option] = args[option] or {}
          table.insert(args[option], value)
        else
          args[option] = value
        end
      end
    else
      table.insert(args, arguments[i])
    end
    i = i + 1
  end
  return args
end



return Server
