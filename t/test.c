#define WTK_UNPACKED
#include <wtk.c>
#include <server.c>
#include <proc.c>
#include <json.c>
#include <stdio.h>

int main(int argc, char* argv[]) {
  lua_State* L = luaL_newstate();
  luaL_openlibs(L);
  luaW_requiref(L, "wtk.c", luaopen_wtk_c);
  luaW_requiref(L, "wtk.proc.c", luaopen_wtk_proc_c);
  luaW_requiref(L, "wtk.json.c", luaopen_wtk_json_c);
  luaW_requiref(L, "wtk.server.c", luaopen_wtk_server_c);
  if (argc > 0 && (luaW_signal(L) || luaW_packlua(L, "src") || luaL_loadfile(L, argv[1]) || luaW_run(L, argc, argv))) {
    fprintf(stderr, "%s\n", lua_tostring(L, -1));
    return -1;
  }
  lua_close(L);
  return 0;
}

