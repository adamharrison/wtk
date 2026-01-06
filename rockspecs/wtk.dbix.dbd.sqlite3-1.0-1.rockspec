package = "wtk.dbix.dbd.sqlite3"
version = "1.0-1"
description = {
   summary = "The dbd for sqlite3 for dbix.",
   license = "MIT"
}
dependencies = {
   "lua >= 5.3"
}
source = {
   url = "git://github.com/adamharrison/wtk.git"
}
external_dependencies = {
   LIBSQLITE3 = { header = "sqlite3.h" }
}
build = {
   type = "builtin",
   modules = {
      ["wtk.dbix.dbd.sqlite3.c"] = { sources = {"src/dbd/sqlite3.c"}, libraries = {"sqlite3"}, incdirs = {"$(LIBSQLITE3_INCDIR)"}, libdirs = {"$(LIBSQLITE3_LIBDIR)"} }
   }
}
