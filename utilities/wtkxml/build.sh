#!/bin/bash
CFLAGS="$CFLAGS -I. -Iwtk"
[[ "$CC" == "" ]] && CC=gcc
[[ "$@" == "clean" ]] && { rm -f packer packed.lua.c wtkjq; exit 0; }
[[ "$@" != *"-g" && "$@" != "-O" ]] && CFLAGS="$CFLAGS -O2 -s"
[[ "$@" != *"-DWTK_UNPACKED"* ]] && { [ -f packer ] || gcc main.c $@ $CFLAGS -DWTK_MAKE_PACKER -o packer -lm; } && ./packer *.lua wtk/xml.lua > packed.lua.c
$CC  -DWTKXML_VERSION='"1.0"' main.c $@ $CFLAGS -lm -o wtkxml
