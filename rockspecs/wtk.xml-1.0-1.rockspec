package = "wtk.xml"
version = "1.0-1"
description = {
   summary = "A simple XML parser/writer.",
   detailed = [[
      Parses/writes XML data.
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
      ["wtk.xml"] = "wtk/xml.lua"
   }
}
