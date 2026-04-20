#!/bin/bash
CFLAGS="$CFLAGS -I. -Iwtk"
LDFLAGS="`pkg-config sqlite3 mbedtls --libs --static`"
[[ "$CC" == "" ]] && CC=gcc
[[ "$@" == "clean" ]] && { rm -f packer packed.lua.c wtkproxy; exit 0; }
[[ "$@" != *"-g" && "$@" != "-O" ]] && CFLAGS="$CFLAGS -O2 -s"
[[ "$@" != *"-DWTK_UNPACKED"* ]] && { [ -f packer ] || gcc main.c $@ $CFLAGS -DWTK_MAKE_PACKER -o packer -lm $LDFLAGS; } && ./packer *.lua wtk/server.lua wtk/dbix.lua > packed.lua.c
$CC  -DWTKPROXY_VERSION='"1.0"' main.c $@ $CFLAGS -lm $LDFLAGS -o wtkproxy

