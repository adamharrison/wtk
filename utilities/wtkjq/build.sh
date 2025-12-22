gcc -s -O2 `pkg-config --cflags lua5.4` main.c ../../src/wtk.c ../../src/json.c `pkg-config --libs lua5.4` -lm  -static -o wtkjq
