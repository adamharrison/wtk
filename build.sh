#!/bin/bash

: ${CC=gcc}
: ${MAKE=make}

if [[ "$@" == "test" ]]; then
  $CC -Iwtk t/test.c -o test -lm
  ./test $2
elif [[ "$@" == "clean" ]]; then
  rm -rf wtk.bin lib/mbedtls/build lib/sqlite/libsqlite3.a packed.lua.c packer test
  exit 0
fi
if [[ "$@" != *"-lmbedtls"* && "$@" != *"-lmbedcrypto"* && "$@" != *"-lmbedx509"* ]]; then
  [ ! -e "lib/mbedtls/build" ] && { cd lib/mbedtls && mkdir build && cd build && CFLAGS="-DMBEDTLS_MD4_C=1 -DMBEDTLS_DEBUG_C -w -fPIC" cmake ..  -G "Unix Makefiles" -DPOSITION_INDEPENDENT_CODE=ON -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF && CFLAGS="-DMBEDTLS_MD4_C=1 -w -fPIC" $MAKE -j 4 && cd ../../../ || exit -1; }
  LDFLAGS="$LDFLAGS -Llib/mbedtls/build/library -lmbedtls -lmbedx509 -lmbedcrypto"
fi
if [[ "$@" != *"-lsqlite3"* ]]; then
  [ ! -e "lib/sqlite/libsqlite3.a" ] && { cd lib/sqlite && ./configure --disable-shared && $MAKE -j 4 &&  cd ../../ || exit -1; }
  LDFLAGS="$LDFLAGS -Llib/sqlite -l:libsqlite3.a"
fi
{ [ -f packer ] || gcc -Iwtk wtk/wtk.c $@ $CFLAGS -DWTK_MAKE_PACKER -o packer -lm $LDFLAGS; } && ./packer wtk/dbix.lua wtk/server.lua wtk/xml.lua > packed.lua.c
$CC -I. -Iwtk wtk/runtime.c -lm $@ -o wtk.bin $LDFLAGS 
