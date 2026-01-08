#include <wtk.c>
#include <json.c>
#include <stdio.h>

#ifndef WTKJQ_VERSION
  #define WTKJQ_VERSION "unknown"
#endif

int main(int argc, char* argv[]) {
  lua_State* L = luaL_newstate();
  luaL_openlibs(L);
  lua_pushliteral(L, WTKJQ_VERSION), lua_setglobal(L, "VERSION");
  luaL_requiref(L, "wtk.c", luaopen_wtk_c, 0);
  luaL_requiref(L, "wtk.json.c", luaopen_wtk_json_c, 0);
  if (luaW_signal(L) || luaW_packlua(L) || luaW_loadentry(L, "init") || luaW_run(L, argc, argv)) {
    fprintf(stderr, "%s\n", lua_tostring(L, -1));
    return -1;
  }
  lua_close(L);
  return 0;
}

