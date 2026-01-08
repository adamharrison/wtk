package = "wtk.dbix.dbd.postgres"
version = "1.0-1"
description = {
   summary = "The dbd for postgres for dbix.",
   license = "MIT"
}
dependencies = {
   "lua >= 5.3"
}
source = {
   url = "git://github.com/adamharrison/wtk.git"
}
external_dependencies = {
   LIBPOSTGRES = { header = "postgresql/libpq-fe.h" }
}
build = {
   type = "builtin",
   modules = {
      ["wtk.dbix.dbd.postgres.c"] = { sources = {"src/dbd/postgres.c"}, libraries = {"pq"}, incdirs = {"$(LIBPOSTGRES_INCDIR)/postgresql"}, libdirs = {"$(LIBPOSTGRES_LIBDIR)"} }
   }
}
