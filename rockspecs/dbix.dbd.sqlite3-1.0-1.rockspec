package = "dbix.dbd.sqlite3"
version = "1.0-1"
description = {
   summary = "The dbd for sqlite3 for dbix.",
   license = "MIT"
}
dependencies = {
   "lua >= 5.3"
}
source = {
   url = "https://github.com/adamharrison/lua-dbix.git",
   tag = "v1.0",
}
external_dependencies = {
   LIBSQLITE3 = { header = "sqlite3.h" }
}
build = {
   type = "builtin",
   modules = {
      ["dbix.dbd.sqlite3"] = { sources = {"src/sqlite3.c"}, libraries = {"sqlite3"}, incdirs = {"$(LIBSQLITE3_INCDIR)"}, libdirs = {"$(LIBSQLITE3_LIBDIR)"} }
   }
}
