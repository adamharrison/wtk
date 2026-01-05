#!/bin/sh
[ "$CC" = "" ] && CC=gcc
([ -f packer ] || gcc wtk.c -DWTK_BUNDLED_LUA -DWTK_MAKE_PACKER -o packer -lm) && ./packer *.lua > packed.c
$CC -DWTK_PACKED -DWTK_BUNDLED_LUA -DWTKJQ_VERSION='"1.0"' $@ main.c -lm  -static -o wtkjq
