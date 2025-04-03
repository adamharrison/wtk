package = "dbix.dbd.postgres"
version = "1.0-1"
description = {
   summary = "The dbd for postgres for dbix.",
   license = "MIT"
}
dependencies = {
   "lua >= 5.3"
}
source = {
   url = "git://github.com/adamharrison/lua-dbix.git"
}
external_dependencies = {
   LIBPOSTGRES = { header = "postgresql/libpq-fe.h" }
}
build = {
   type = "builtin",
   modules = {
      ["dbix.dbd.postgres"] = { sources = {"src/postgres.c"}, libraries = {"pq"}, incdirs = {"$(LIBPOSTGRES_INCDIR)/postgresql"}, libdirs = {"$(LIBPOSTGRES_LIBDIR)"} }
   }
}
