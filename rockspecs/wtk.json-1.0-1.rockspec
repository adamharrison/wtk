package = "wtk.json"
version = "1.0-1"
description = {
   summary = "A port of cjson.",
   detailed = [[
      Encodes/decodes JSON.
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
      ["wtk.json.c"] = { sources = {"wtk/json.c"}, incdirs = {"wtk"} }
   }
}
