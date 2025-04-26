# lua-sserver

This is a `luarocks` module that creates a really simple coroutine-yielding webserver that supports websockets.

## Key Principles

Below are my general goals for this project, some of them achieved, others aspirational.

1. Smol.
2. Simple.
3. Some magic, but not too much.
4. Optionally nonblockable via lua coroutines.
7. Stand-alone; doesn't require `restty` or `lapis` or anything else.
8. Well documented.

## Quickstart

To install, use `luarocks`:

```sh
luarocks install sserver
```

This will build the drivers as well as the module; you don't need all of these, 
only really just one.

```lua
local Server = require "wtk.server"
local loop = Server.Loop.new()
local args = Server.pargs({ ... }, { host = "string", port = "integer", verbose = "flag", timeout = "integer"  })
server = Server.new({ 
  host = args.host or "0.0.0.0", 
  port = args.port or 9090, 
  timeout = args.timeout or 10,
  verbose = args.verbose,
  handler = function(request)
    if request.method == "GET" then
      if request.path == "/" then
        request.client:file("static/client.html")
      elseif request.path:find("^/static/[^/]+$") then
        request.client:file(request.path:sub(2))
      elseif request.path:find("/ws")
        local ws = request:websocket()
        ws:send("This is a packet in a websocket.")
        while true do
          coroutine.yield({ timeout = 10 })
          ws:send("This was sent after 10 seconds.")
        end
        ws:close()
      else
        request:respond(404, { }, "Not Found")
      end
    end
  end
}):add(loop)
-- give a basic console
loop:add(0, function()
  local line = io.stdin:read("*line")
  if not line then return false end
  if line == "quit" then os.exit(0) end
  local f, err = load(line, "=CLI")
  if f then _, err = pcall(f) end
  if err then server.log:error(err) end
end)
loop:run()
```
