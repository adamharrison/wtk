# lua simple modules

These are a bunch of non-blocking modules that can be easily packaged into a single binary application.

## Quickstart

Here's an example of a non-blocking webserver server with a database connection.

```lua
local wtk = require "wtk"
local DBIX = require "wtk.dbix"
local Server = require "wtk.server"
local Loop = require "wtk.loop"
local Countdown = require "wtk.countdown"
local loop = Loop.new()
local args = Server.pargs({ ... }, { host = "string", port = "integer", verbose = "flag", timeout = "integer",  })

local schema = DBIX.schema.new()
local users = schema:table({
  name = "users",
  columns = {
    { name = "id", auto_increment = true, data_type = "int", not_null = true },
    { name = "updated", data_type = "datetime", not_null = true },
    { name = "created", data_type = "datetime", not_null = true },
    { name = "first_name", data_type = "string", length = 64 },
    { name = "last_name", data_type = "string", length = 64 },
    { name = "email", data_type = "string", length = 128 }
  },
  primary_key = { "id" }
})

local function get_db()
  return schema:connect('mysql', { 
    database = 'userexample',
    username = 'root',
    password = '',
    hostname = 'localhost',
    port = '3306',
    nonblocking = true
  })
end

server = Server.new({ 
  host = args.host or "0.0.0.0", 
  port = args.port or 9090, 
  timeout = args.timeout or 10,
  verbose = args.verbose,
  handler = function(request)
    local db <close> = get_db()
    if request.method == "GET" then
      if request.path == "/" then
        request.client:file("static/client.html")
      elseif request.path:find("^/static/[^/]+$") then
        request.client:file(request.path:sub(2))
      elseif request.path:find("^/users$") then
        local t = { }
        for user in db.users:each() do
          table.insert(t, string.format("User ID: %d, First Name: %s, Last Name: %s", user.id, user.first_name, user.last_name))
        end
        request:respond(200, { "Content-Type" = "text/plain" }, table.concat(t, "\n"))
      elseif request.path:find("^/ws")
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
  if line then
    if line == "quit" then os.exit(0) end
    local f, err = load(line, "=CLI")
    if f then
      _, err = pcall(f)
    end
    if err then
      server.log:error(err)
    end
  else
    return false
  end
end)
loop:run()
```

And of course, if you want, you can pack the whole thing into a single binary by simply using `git add submodule` to add
this repository into your project, and then simply symlinking the relevant source files you'd like to include into the main
directory, and using the following build script and `main.c`:

```bash
: ${CC=musl-gcc}
: ${CFLAGS=-O3 -s}
: ${BIN=server}
[[ "$@" == "clean" ]] && rm -rf packed.c lua $BIN && exit 0
[[ ! -e "packed.c" && ! -e "lua" ]] && $CC lib/lua/onelua.c -o lua -lm
[[ ! -e "packed.c" ]] && ./lua lib/lua-dbix/scripts/pack.lua *.lua > packed.c
$CC -DMAKE_LIB=1 -Ilib/lua lib/lua/onelua.c *.c -lm -o $BIN -static  $@
```

```c
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#ifdef PACKED_LUA
  extern const char* packed_luac[];
#else
  static const char* packed_luac[] = { NULL, NULL, NULL };
#endif

int luaopen_wtk(lua_State* L);
int luaopen_wtk_server_driver(lua_State* L);

int main(int argc, char* argv[]) {
  lua_State* L = luaL_newstate();
  luaL_openlibs(L);
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, luaopen_wtk);
  lua_setfield(L, -2, "wtk");
  lua_pushcfunction(L, luaopen_wtk_server_driver);
  lua_setfield(L, -2, "wtk.server.driver");
  for (int i = 0; packed_luac[i]; i += 3) {
    if (luaL_loadbuffer(L, packed_luac[i+1], (size_t)packed_luac[i+2], packed_luac[i])) {
      fprintf(stderr, "Error loading %s: %s", packed_luac[i], lua_tostring(L, -1));
      return -1;
    }
    lua_setfield(L, -2, packed_luac[i]);
  }
  lua_pop(L, 1);
  luaL_loadstring(L, "(package.preload.init or loadfile(\"init.lua\"))(...)");
  for (int i = 1; i < argc; ++i) 
    lua_pushstring(L, argv[i]);
  if (lua_pcall(L, argc - 1, LUA_MULTRET, 0))
    fprintf(stderr, "error initializing server: %s\n", lua_tostring(L, -1));
  lua_close(L);
  return 0;
}
```

All in all, this packed binary can be statically linked, and copied into almost any linux environment,
including an [Alpine](https://alpinelinux.org/) linux container.

```dockerfile
FROM alpine:latest

COPY static .
COPY server .
CMD ["./server", "--port=80"]
```

This allows for *extremely* small alpine containers that are pretty quick and very low memory.

A basic container application that uses this webserver takes up `9.46MB`, and approximately `1.078MiB`
of RAM at rest.

For portability reasons, you can simply build inside the conatiner if you want:

```dockerfile
FROM alpine:latest

RUN apk add gcc musl-dev
COPY lib lib
COPY static static
COPY *.lua *.c build.sh .
RUN gcc -DMAKE_LIB=1 -Ilib/lua lib/lua/onelua.c *.c -lm -O3 -s -o dawoot
RUN apk del gcc musl-dev
CMD ["./dawoot", "--port=80"]
```

Although this will grealty increase the size of the container to about `167MB`, so if you are on a limited
server, you may wish to compile locally.

## Utilities

In addition to various modules, I'm also posting a number of small utilities that I use to replace common, yet annoying anti-ergonomic utilities.

The benefit to these is that they're all, small, speedy, statically compiled binaries, for linux. So you don't need an entire python environment just to run `jq`.

`wtkjq`: `jq` with a sensible, lua-based interface. Slightly faster than regular `jq`.

