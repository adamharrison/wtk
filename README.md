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
this repository into your project, and then simply symlinking the `wtk` directory to your main directory
directory, and using the following build script and `main.c`:

```bash
#!/bin/bash
CFLAGS="$CFLAGS -I. -Iwtk"
[[ "$CC" == "" ]] && CC=gcc
[[ "$@" == "clean" ]] && { rm -f packer packed.lua.c wtkjq; exit 0; }
[[ "$@" != *"-g" && "$@" != "-O" ]] && CFLAGS="$CFLAGS -O2 -s"
[[ "$@" != *"-DWTK_UNPACKED"* ]] && { [ -f packer ] || gcc main.c $@ $CFLAGS -DWTK_MAKE_PACKER -o packer -lm; } && ./packer *.lua > packed.lua.c
$CC  -DWTKJQ_VERSION='"1.0"' main.c $@ $CFLAGS -lm -o wtkjq
```

```c
#include <wtk.c>
#include <json.c>
#include <stdio.h>

#ifndef WTKJQ_VERSION
  #define WTKJQ_VERSION "unknown"
#endif

int main(int argc, char* argv[]) {
  lua_State* L = luaL_newstate();
  luaL_openlibs(L);
  lua_pushliteral(L, WTKJQ_VERSION), lua_setglobal(L, "VERSION");
  luaW_requiref(L, "wtk.c", luaopen_wtk_c);
  luaW_requiref(L, "wtk.json.c", luaopen_wtk_json_c);
  if (luaW_signal(L) || luaW_packlua(L) || luaW_loadentry(L, "init") || luaW_run(L, argc, argv)) {
    fprintf(stderr, "%s\n", lua_tostring(L, -1));
    return -1;
  }
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

## Conventions

* All modules can be either dynamically linked with `require`, statically linked with in the build, or `#include`d into a program.
* By default, your build should always `-I.`, and either `-I<path_to_wtk>`, or symlink the relevant modules into your `src` directory, in that order.
* Most applications should be a single `main.c` file, and a single `packed.lua.c` file, generated from the packer of all your lua files; with at least `init.lua` existing.
* Most build scripts should be able to function like the following, only purely bash.
* All lua modules are accessible via `wtk.<module_name>`. All C modules are available via `wtk.<module_name>.c`.
* Any submodules (i.e. part of the same module) are as follows: `wtk.<module_name>(.c).<submodule_name>`.
* Methods of building can vary; small programs should simple `#include <json.c>`; other programs may prefer to build individual objects. Using `luaW_requiref` should work both ways.

```bash
./build.sh clean # Resets all files.
./build.sh `pkg-config lua5.4 --cflags --libs` -DWTK_UNPACKED # Builds with system lua, -O2 -s, local lua files.
./build.sh -g -DWTK_UNPACKED # Builds with static lua, -g, local lua files.
./build.sh # Builds with static lua, -O2 -s, lua files bundled into executable.
./build.sh -static # Completely static build.
./build.sh -g # Builds a debug build.
```


## Utilities

In addition to various modules, I'm also posting a number of small utilities that I use to replace common, yet annoying anti-ergonomic utilities.

The benefit to these is that they're all, small, speedy, statically compiled binaries, for linux. So you don't need an entire python environment just to run `jq`.

`wtkjq`: `jq` with a sensible, lua-based interface. Slightly faster than regular `jq`.

