package = "dbix"
version = "1.0-1"
description = {
   summary = "An alternate dbi module, inspired by perl's DBIx::Class.",
   detailed = [[
      Allows for non-blocking use via coroutines.
   ]],
   license = "MIT"
}
dependencies = {
   "lua >= 5.1"
}
source = {
   url = "https://github.com/adamharrison/lua-dbix.git",
   tag = "v1.0",
}
build = {
   type = "builtin",
   modules = {
      dbix = "init.lua"
   }
}
