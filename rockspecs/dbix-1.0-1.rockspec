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
   url = "git://github.com/adamharrison/lua-dbix.git"
}
build = {
   type = "builtin",
   modules = {
      dbix = "init.lua"
   }
}
