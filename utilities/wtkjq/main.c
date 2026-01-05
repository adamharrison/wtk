#include "wtk.c"
#include "json.c"
#include <stdio.h>

#ifndef WTKJQ_VERSION
  #define WTKJQ_VERSION "unknown"
#endif

int main(int argc, char* argv[]) {
  lua_State* L = luaL_newstate();
  luaL_openlibs(L);
  lua_pushliteral(L, WTKJQ_VERSION), lua_setglobal(L, "VERSION");
  if (luaW_signal(L) || luaW_packlua(L) || luaW_loadlib(L, "wtk", luaopen_wtk) || luaW_loadlib(L, "wtk.json", luaopen_wtk_json) || luaW_loadentry(L, "init") || luaW_run(L, argc, argv)) {
    fprintf(stderr, "%s\n", lua_tostring(L, -1));
    return -1;
  }
  lua_close(L);
  return 0;
}

