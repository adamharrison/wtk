package = "wtk.client"
version = "1.0-1"
description = {
   summary = "A simple non-blocking webclient.",
   detailed = [[
      Allows for non-blocking use via coroutines.
   ]],
   license = "MIT"
}
dependencies = {
   "lua >= 5.3"
}
source = {
   url = "git://github.com/adamharrison/wtk.git"
}
external_dependencies = {
   LIBMBEDTLS = { header = "mbedtls/ssl.h" }
}
build = {
   type = "builtin",
   modules = {
      ["wtk.client.c"] = { sources = {"wtk/client.c"}, libraries = {"mbedtls"}, incdirs = {"$(LIBMBEDTLS_INCDIR)","wtk"}, libdirs = {"$(LIBMBEDTLS_LIBDIR)"} }
   }
}
