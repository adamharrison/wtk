package = "wtk.proc"
version = "1.0-1"
description = {
   summary = "A process library.",
   detailed = [[
      Inflates/deflates data.
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
      ["wtk.proc.c"] = { sources = {"wtk/proc.c"}, incdirs = {"wtk"} }
   }
}
