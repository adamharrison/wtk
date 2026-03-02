-- We go for simplicity above all else.
local wtk = require "wtk.c"
local driver = require "wtk.server.c"
local system = wtk.system
local socket, sha1, base64 = driver.socket, driver.sha1, driver.base64
local PACKET_SIZE = 4096

local function merge(t1, t2) local t = {} for k,v in pairs(t1) do t[k] = v end for k,v in pairs(t2) do t[k] = v end return t end
local Server = { Socket = driver.socket, sha1 = driver.sha1, base64 = driver.base64 }
Server.__index = Server


Server.Websocket = { op = { CONT = 0x0, TEXT = 0x1, BINARY = 0x2, CLOSE = 0x8, PING = 0x9, PONG = 0xA } }
Server.Websocket.__index = Server.Websocket
function Server.Websocket.new(client) return setmetatable({ client = client }, Server.Websocket) end
function Server.Websocket:handshake(request)
  assert(request.headers["sec-websocket-key"], "Missing required header.")
  request:respond(101, { Upgrade = "websocket", Connection = "Upgrade", ["Sec-WebSocket-Accept"] = base64.encode(sha1.binary(request.headers["sec-websocket-key"] .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")) })
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
  self.client:write_block(table.concat(t))
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
      self:write_block(Server.Websocket.op.PONG, accumulator)
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


Server.Response = { }
Server.Response.__index = Server.Response
function Server.Response.new(code, headers, body) return setmetatable({ code = code, headers = headers or {}, body = body }, Server.Response) end
function Server.Response:write_header(client)
  if client.closed then return end
  local parts = { string.format("%s %d %s\r\n", "HTTP/1.1", self.code, client.server.codes[self.code]) }
  if self.body and type(self.body) == 'string' and not self.headers['content-length'] and self.headers['transfer-encoding'] ~= 'chunked' then self.headers['content-length'] = #self.body end
  if not self.headers['connection'] or self.headers['connection']:find("^%s*%") then self.headers['connection'] = 'keep-alive' end
  if not self.headers['date'] or self.headers['date']:find("^%s*%") then self.headers['date'] = os.date("!%a, %d %b %Y %H:%M:%S GMT") end
  for key,value in pairs(self.headers) do table.insert(parts, string.format("%s: %s\r\n", key, value)) end
  table.insert(parts, "\r\n")
  client:write_block(table.concat(parts))
end

function Server.Response:write_encoded(client, chunk)
  if self.headers['transfer-encoding'] == 'chunked' then
    client:write_block(string.format("%x\r\n", #chunk))
    client:write_block(chunk)
    client:write_block('\r\n')
  else
    client:write_block(chunk)
  end
end

function Server.Response:write(client)
  if client.closed then return end
  self:write_header(client)
  if self.body then 
    if type(self.body) == 'function' then
      for chunk in self.body do
        if #chunk > 0 then
          if client.closed then 
            if self.code == 206 then break end
            error({ code = 400, message = "Client unexpectedly closed connection.", verbose = true }) 
          end
          self:write_encoded(client, chunk)
        end
        coroutine.yield()
      end
    else
      self:write_encoded(client, self.body)
    end
  end
  self:write_encoded(client, '') -- for chunked
  if self.code ~= 101 and not self.headers['content-length'] and self.headers['transfer-encoding'] ~= 'chunked' then client:close() end
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
function Request:parse_form(form)
  local params = {}
  for key,value in form:gmatch("([^=&%?]+)=([^&]+)") do 
    value = value:gsub("%%([a-fA-F0-9][a-fA-F0-9])", function(e) return string.char(tonumber(e, 16)) end) 
    if params[key] then 
      if type(params[key]) ~= 'table' then
        params[key] = { params[key] }
      end
      table.insert(params[key], value)
    else
      params[key] = value
    end
  end
  return params
end
function Request:parse_headers()
  while #self.buffer == 0 or not self.buffer[#self.buffer]:find("\r\n\r\n") do
    local packet = self.client:read(PACKET_SIZE)
    if packet then
      table.insert(self.buffer, packet)
    elseif #self.buffer > 0 then
      error({ code = 500, message = "Client unexpectedly closed connection.", verbose = true })
    else
      return nil
    end
  end
  local headers, remainder
  self.method, self.path, self.version, headers, remainder = table.concat(self.buffer):match("^(%S+) (%S+) (%S+)\r\n(.-\r\n)\r\n(.*)$")
  self.params, self.path, self.search = {}, self.path:match("^([^?]+)(%??[^?]*)$")
  assert(self.method and self.path, "malformed request")
  if self.search then self.params = self:parse_form(self.search) end
  for key,value in headers:gmatch("([^%:]+):%s*(.-)\r\n") do self.headers[key:lower()] = value end
  for key,value in (self.headers.cookie or ""):gmatch("([^=;%s]+)=([^;]+)") do self.cookies[key] = value:gsub("%%([a-fA-F0-9][a-fA-F0-9])", function(e) return string.char(tonumber(e, 16)) end) end
  if #remainder > 0 then self.client.buffer = remainder end
  assert(self.method ~= "POST" or self.headers['content-length'], "malformed request, requires content-length")
  self.client.server.log:verbose("REQ %s %s %s", self.method, self.path, self.client.peer)
  return self
end
function Request:websocket()
  self.client.websocket = Server.Websocket.new(self.client):handshake(self)
  return self.client.websocket
end
function Request:body() 
  if (self.method ~= "POST" and self.method ~= "PUT") or self._body then 
    return self._body 
  end 
  local chunks = { }
  while self.length_read < tonumber(self.headers['content-length']) do
    local chunk = assert(self:read(tonumber(self.headers['content-length']) - self.length_read))
    if chunk and #chunk > 0 then
      table.insert(chunks, chunk)
    end
  end
  self._body = table.concat(chunks)
  return self._body 
end
function Request:read(len) 
  local to_read = math.min(self.headers['content-length'] and (self.headers['content-length'] - self.length_read) or (self.method == "POST" and math.huge or 0), len)
  if to_read == 0 then return nil end
  local str = self.client:read(to_read)
  self.length_read = self.length_read + #str 
  return str 
end
function Request:respond(code, headers, body) 
  self.responded = true 
  if headers and not headers['set-cookie'] and self.cookies then 
    local cookies = {}
    for key,value in pairs(self.cookies) do table.insert(cookies, key .. "=" .. tostring(value):gsub("[%c:/?#%[%]@!$&'\"%(%)*+,;=%%]", function(e) return "%" .. string.format("%02x", e:byte(1)) end)) end
    if #cookies > 0 then headers['set-cookie'] = table.concat(cookies, ';') end
  end
  local res = (type(code) == 'table' and getmetatable(code) == Server.Response and code or Server.Response.new(code, headers, body))
  res:write(self.client)
  return res
end
function Request:redirect(path) return self:respond(302, { ["location"] = path }) end
function Request:file(path, headers)
  assert(not path:find("%.%."), "invalid path") 
  if not wtk.system.stat(path) then
    return self:respond(200, merge({ ['content-type'] = self.client.server:mimetype(path) }, headers or {}), assert(packed[path], { code = 404 }))
  end
  local stat = assert(wtk.system.stat(path), { code = 404 })
  assert(stat.type == "file", { code = 404 })
  local s, e = 0, stat.size
  if self.headers['range'] then
    local hs, he = self.headers['range']:match("(%d*)%-(%d*)")
    s, e = tonumber(hs), he ~= "" and tonumber(he) or stat.size
  end
  headers = merge({ ['last-modified'] = os.date("%a, %d %b %Y %H:%M:%S GMT", stat.mtime), ['content-length'] = e - s, ['accept-ranges'] = 'bytes', ['content-type'] = self.client.server:mimetype(path), ["cache-control"] = not self.client.server.debug and "max-age=86400" or nil }, headers or {})
  local f = assert(wtk.io.file(path, "rb"), { code = 404 })
  if self.headers['range'] then
    headers['content-range'] = string.format("bytes %d-%d/%d", s, e - 1, stat.size)
    f:seek("set", s)
  end
  return self:respond(self.headers['range'] and 206 or 200, headers, function() 
    if s >= e then return nil end
    local chunk = f:read(math.min(16*1024, e - s)) 
    if not chunk then return nil end
    s = s + #chunk
    return chunk
  end) 
end
function Request:attachment(path, headers) return self:file(path, merge(headers or {}, { ["Content-Disposition"] = "attachment; filename=\"" .. path:gsub(".*/", ""):gsub("\"", "") .. "\"" })) end
function Request:parts()
  local boundary = self.headers['content-type']:match("multipart/form-data;%s+boundary=(.+)$")
  if not boundary then return function() return nil end end
  local content_length = assert(self.headers['content-length'], { code = 400, message = "requries a content-length" })
  local chunk = ""
  return function()
    while true do
      chunk = chunk .. self:read(math.min(content_length - self.length_read, 4096))
      local s, e = chunk:find("\r\n\r\n")
      if s then 
        local header_text = chunk:sub(1, s - 1)
        local remainder = chunk:sub(e + 1)
        local bs, be = remainder:find(boundary)
        local finished = false
        if bs then 
          remainder = remainder:sub(1, bs - 1) 
          chunk = remainder:sub(be + 1)
          finished = true
        end
        local headers = {}
        for key,value in header_text:gmatch("([^%:]+):%s*(.-)\r\n") do headers[key:lower()] = value end
        return {
          buffer = remainder,
          finished = finished,
          headers = headers,
          read = function(file, length) 
            if file.finished then return nil end
            file.buffer = file.buffer .. self:read(length or 4096)
            local bs, be = file.buffer:find(boundary)
            if not bs then
              local internal = file.buffer:sub(1, #file.buffer - #boundary)
              file.buffer = file.buffer:sub(#file.buffer - #boundary + 1)
              return internal
            else
              file.finished = true
              local internal = file.buffer:sub(1, bs - 1)
              chunk = file.buffer:find(be + 1)
              return internal
            end
          end
        }
      end
    end
  end
end

local Client = {}
Client.__index = Client
function Client.new(server, socket) return setmetatable({ last_activity = os.time(), server = server, waiting = nil, socket = socket, responsed = false, peer = select(2, socket:peer()) }, Client) end
function Client:write(buf) 
  self.last_activity = os.time() 
  return self.socket:send(buf) 
end
function Client:write_block(buf)
  while #buf > 0 do
    local len, err = self:write(buf)
    if not len and err == "timeout" then 
      self:yield("write") 
    elseif not len and (err == "reset" or err == "pipe") then
      self.closed = true
      break
    elseif len and len >= #buf then
      break
    elseif len then
      buf = buf:sub(len + 1)
    else
      error({ code = 500, message = "Error writing to socket: " .. err })
    end
  end
end
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
    elseif err == "closed" or err == "reset" or err == "pipe" then
      self.closed = true
    else
      error({ code = 500, message = "Failed reading from socket: " .. err })
    end
  end
end
function Client:close() self.server.log:verbose("Manually closing connnection.") self.socket:close() self.closed = true end
function Client:yield(type) coroutine.yield({ socket = self.socket, type = type or "read" }) end

function Server.new(t) 
  t.socket = assert(socket.bind(t.host or "0.0.0.0", t.port or (t.debug and 8080 or 80)), "unable to bind")
  t.mimes = { ["svg"] = "image/svg+xml", ["jpeg"] = "image/jpeg", ["jpg"] = "image/jpeg", ["png"] = "image/png", ["gif"] = "image/gif", ["js"] = "text/javascript", ["html"] = "text/html", ["css"] = "text/css", ["txt"] = "text/plain" }
  t.codes = { [101] = "Switching Protocols", [200] = "OK", [201] = "Created", [204] = "No Content", [206] = "Partial Content", [301] = "Moved Permanently", [302] = "Found", [400] = "Bad Request", [403] = "Forbidden", [404] = "Not Found", [500] = "Internal Server Error" }
  t.routes = { GET = { }, POST = { }, PUT = { }, DELETE = { } }
  local self = setmetatable(t, Server) 
  self.log = t.log or Server.Log.new(t.verbose)
  local type, address, port = self.socket:peer()
  if type == "unix" then
    self.log:info("Server up at %s", address)
  else 
    self.log:info("Server up on %s:%s", address, port)
  end
  return self
end

function Server:default_error_handler(request, err, client, meta)
  local msg, code = nil, 500
  if type(err) == 'table' and err.code and type(err.code) == "number" then
    msg, code = string.format("%d Error", err.code), err.code
    if err.message then msg = msg .. ": " .. err.message end
    if request and not request.responded then request:respond(err.code, { ["Content-Type"] = "text/plain; charset=UTF-8" }, (err.message or (err.code .. " " .. self.codes[err.code])) .. "\n") end
  else
    msg = string.format("Unhandled Error: %s", err) 
    if request and not request.responded then request:respond(500, { ["Content-Type"] = "text/plain; charset=UTF-8" }, "500 Internal Server Error") end
  end
  if self.verbose or not err.verbose then self.log:error((self.verbose and (self.very_verbose or code == 500)) and (msg .. "\n" .. meta.stack) or msg) end
  if not request then client:close() end
  if request and request.client.websocket then request.client.websocket:close() end
end
Server.error_handler = Server.default_error_handler

function Server:accept()
  local socket = self.socket:accept()
  if socket then 
    local client = Client.new(self, socket)
    self.log:verbose("Incoming connection from '%s'", select(2, socket:peer()))
    client.job = self.loop:job(function()
      while not client.closed do
        local request
        try(function()
          request = Request.new(client):parse_headers()
          if request then
            self:accepted(client, request)
            if not request.responded then error({ code = 404 }) end
          end
        end, function(err)
          try(function()
            self:error_handler(request, err.error, client, err)
          end, function(err)
            self.log:error("Error in error handler: %s\n%s", err.error, err.stack)
          end)
        end)
        -- clear out buffer if it wasn't read
        if request then request:body() end
      end
    end)
    return client
  else
    log:error("Error accepting client.")
  end
end
function Server:add(loop)
  loop:add(self.socket, function() 
    self:accept()
  end, "read")
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
      return true, route.handler(request, table.unpack(results))
    end
  end
  return false
end
function Server:route(method, path, func) 
  local target_path = "^" .. path .. "$"
  for _, method in ipairs(type(method) == 'table' and method or { method }) do
    for i,v in ipairs(self.routes[method]) do
      if v.path == target_path then
        v.handler = func
        return
      end
    end
    table.insert(self.routes[method], { path = target_path, handler = func }) 
    table.sort(self.routes[method], function(a,b) return #a.path > #b.path end) 
  end
end
function Server:get(path, func) return self:route("GET", path, func) end
function Server:post(path, func) return self:route("POST", path, func) end
function Server:put(path, func) return self:route("PUT", path, func) end
function Server:delete(path, func) return self:route("DELETE", path, func) end

Server.Log = {}
Server.Log.__index = Server.Log
function Server.Log.new(verbose) return setmetatable({ _verbose = verbose }, Server.Log) end
function Server.Log:log(type, message, ...) wtk.io.stdout:write(string.format("[%5s][%s.%03d]: " .. message .. "\n", type, os.date("%Y-%m-%dT%H:%M:%S"), (math.floor(wtk.system.time() * 1000.0) % 1000), ...)):flush() end
function Server.Log:verbose(message, ...) if self._verbose then self:log("VERB", message, ...) end end
function Server.Log:info(message, ...) self:log("INFO", message, ...) end
function Server.Log:error(message, ...) self:log("ERROR", message, ...) end
function Server.Log:warn(message, ...) self:log("WARN", message, ...) end

function Server:hot_reload(loop, file, options)
  if not system.mtime(file) then return self.log:warn("Can't find " .. file .. ", so cannot hot reload.") end
  local old_modified = not package.preload.init and system.mtime(file) or 0
  loop:add(wtk.countdown.new(0, 0.25), function()
    if old_modified < system.mtime(file) then
      local status, err = pcall(function()
        for k,v in pairs(package.loaded) do if not k:find("%.c$") and not k:find("%.c%.") then package.loaded[k] = nil end end
        assert(load(wtk.file.open(file, "rb"):read("*all"), "=" .. file))()
        self.log:info("Hot reloaded " ..  file .. ".")
        collectgarbage()
      end)
      if not status then self.log:error("Attempt to reload routes failed: " .. err) end
      old_modified = system.mtime(file)
    end
  end)
end

-- loop:add(0, function() server:console() end)
function Server:console()
  local line = io.stdin:read("*line")
  if not line then return false end
  if line == "quit" then os.exit(0) end
  local f, err = load(line, "=CLI")
  if f then _, err = pcall(f) end
  if err then self.log:error(err) end
end

function Server.escapeURI(param) return param:gsub("[^A-Za-z0-9%-_%.%!~%*'%(%)]", function(e) return string.format("%%%02x", e:byte(1)) end) end
function Server.unescapeURI(param) return param:gsub("%%([a-f0-9A-F][a-f0-9A-F])", function(e) return string.char(tonumber(e, 16)) end) end


return Server
