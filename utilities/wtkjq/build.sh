lua5.4 ../../scripts/pack.lua init.lua > packed.c
gcc -DPACKED_LUA -s -O2 `pkg-config --cflags lua5.4` *.c ../../src/wtk.c ../../src/json.c `pkg-config --libs lua5.4` -lm  -static -o wtkjq
