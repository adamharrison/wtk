#!/bin/bash

: {$CC=gcc}

if [[ "$1" == "test" ]] then
  $CC -Iwtk t/test.c -o test -lm
  ./test $2
fi
