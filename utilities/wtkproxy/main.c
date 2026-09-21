#define WTK_SERVER_SSL

#include <wtk.c>
#include <server.c>
#include <client.c>
#include <json.c>
#include <stdio.h>

#ifndef WTKPROXY_VERSION
  #define WTKPROXY_VERSION "unknown"
#endif

static int f_generate_keypair(lua_State* L) {
  return 0;
}

static int f_generate_cert(lua_State* L) {
  return 0;
}

static int f_generate_csr(lua_State* L) {
  return 0;
}


static const luaL_Reg acme_lib[] = {
  { "generate_keypair",  f_generate_keypair   },
  { "generate_cert",     f_generate_cert      },
  { "generate_csr",      f_generate_csr       },
  { NULL,        NULL }
};

int main(int argc, char* argv[]) {
  lua_State* L = luaL_newstate();
  luaL_openlibs(L);
  void** extra = lua_getextraspace(L);
  luaW_requiref(L, "wtk.server.c", luaopen_wtk_server_c);
  luaW_requiref(L, "wtk.client.c", luaopen_wtk_client_c);
  luaW_requiref(L, "wtk.json.c", luaopen_wtk_json_c);
  lua_pushliteral(L, WTKPROXY_VERSION), lua_setglobal(L, "VERSION");
  luaL_requiref(L, "wtk.c", luaopen_wtk_c, 0);
  lua_newtable(L);
  luaL_setfuncs(L, acme_lib, 0);
  lua_setglobal(L, "acme");
  if (luaW_signal(L) || luaW_packlua(L, ".") || luaW_loadentry(L, "init") || luaW_run(L, argc, argv)) {
    fprintf(stderr, "%s\n", lua_tostring(L, -1));
    return -1;
  }
  lua_close(L);
  return 0;
}

