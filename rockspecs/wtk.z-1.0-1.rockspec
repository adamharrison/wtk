package = "wtk.z"
version = "1.0-1"
description = {
   summary = "A port of miniz.",
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
      ["wtk.z.c"] = { sources = {"src/z.c"} }
   }
}
