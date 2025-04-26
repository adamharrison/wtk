package = "wtk.server"
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
   url = "git://github.com/adamharrison/wtk.git"
}
build = {
   type = "builtin",
   modules = {
      ["wtk.server"] = "server.lua",
      ["wtk.server.driver"] = { sources = {"src/server/driver.c"} }
   }
}
