package = "wtk.dbix.dbd.mysql"
version = "1.0-1"
description = {
   summary = "The dbd for mysql for dbix.",
   license = "MIT"
}
dependencies = {
   "lua >= 5.3"
}
source = {
   url = "git://github.com/adamharrison/wtk.git"
}
external_dependencies = {
   LIBMYSQL = { header = "mysql/mysql.h" }
}
build = {
   type = "builtin",
   modules = {
      ["wtk.dbix.dbd.mysql"] = { sources = {"src/dbd/mysql.c"}, libraries = {"mysqlclient"}, incdirs = {"$(LIBMYSQL_INCDIR)/mysql"}, libdirs = {"$(LIBMYSQL_LIBDIR)"} }
   }
}
