package = "sserver"
version = "1.0-1"
description = {
   summary = "A simple non-blocking webserver.",
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
      sserver = "sserver.lua",
      ["sserver.driver"] = { sources = {"src/sserver/driver.c"} }
   }
}
