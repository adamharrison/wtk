#include <wtk.c>
#include <server.c>
#include <client.c>
#include <dbd/sqlite3.c>
#include <proc.c>
#include <json.c>
#include <z.c>
#include <stdio.h>

int main(int argc, char* argv[]) {
  lua_State* L = luaL_newstate();
  luaL_openlibs(L);
  luaW_requiref(L, "wtk.c", luaopen_wtk_c);
  luaW_requiref(L, "wtk.proc.c", luaopen_wtk_proc_c);
  luaW_requiref(L, "wtk.json.c", luaopen_wtk_json_c);
  luaW_requiref(L, "wtk.server.c", luaopen_wtk_server_c);
  luaW_requiref(L, "wtk.dbd.sqlite3.c", luaopen_wtk_dbd_sqlite3_c);
  if (argc < 2) {
    fprintf(stderr, "usage: %s file [args]\n", argv[0]);
    return -1;
  }
  if (luaW_signal(L) || luaW_packlua(L, "src") || luaL_loadfile(L, argv[1]) || luaW_run(L, argc, argv)) {  
    fprintf(stderr, "%s\n", lua_tostring(L, -1));
    return -1;
  }
  lua_close(L);
  return 0;
}

