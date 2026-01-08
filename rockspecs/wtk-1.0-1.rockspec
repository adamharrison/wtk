package = "wtk"
version = "1.0-1"
description = {
   summary = "Base utility routines for wtk.",
   detailed = [[
      
   ]],
   license = "MIT"
}
dependencies = {
   "lua >= 5.3"
}
source = {
   url = "git://github.com/adamharrison/wtk.git"
}
build = {
   type = "builtin",
   modules = {
      ["wtk"] = { sources = {"wtk/wtk.c"} }
   }
}
