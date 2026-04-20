#include <wtk.c>
#include <server.c>
#include <client.c>
#include <stdio.h>

#ifndef WTKPROXY_VERSION
  #define WTKPROXY_VERSION "unknown"
#endif

int main(int argc, char* argv[]) {
  lua_State* L = luaL_newstate();
  luaL_openlibs(L);
  luaW_requiref(L, "wtk.server.c", luaopen_wtk_server_c);
  luaW_requiref(L, "wtk.client.c", luaopen_wtk_client_c);
  lua_pushliteral(L, WTKPROXY_VERSION), lua_setglobal(L, "VERSION");
  luaL_requiref(L, "wtk.c", luaopen_wtk_c, 0);
  if (luaW_signal(L) || luaW_packlua(L, ".") || luaW_loadentry(L, "init") || luaW_run(L, argc, argv)) {
    fprintf(stderr, "%s\n", lua_tostring(L, -1));
    return -1;
  }
  lua_close(L);
  return 0;
}

