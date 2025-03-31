#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  sqlite3* db;
  int nonblocking;
  int foreign_keys;
} sqlite3_t;

typedef struct {
  int connection;
  sqlite3_stmt* statement;
  sqlite3_t* sqlite;
  size_t columns;
} sqlite3_result_t;

static int lua_iscoroutine(lua_State* L) {
  int is_coroutine = !lua_pushthread(L);
  lua_pop(L, 1);
  return is_coroutine;
}

static sqlite3_result_t* lua_tosqlite3_result(lua_State* L, int index) {
  return (sqlite3_result_t*)lua_touserdata(L, index);
}

static int f_sqlite3_result_close(lua_State* L) {
  sqlite3_result_t* result = lua_tosqlite3_result(L, 1);
  if (sqlite3_finalize(result->statement) != SQLITE_OK) {
    lua_pushnil(L);
    lua_pushstring(L, sqlite3_errmsg(result->sqlite->db));
    return 2;
  }
  return 0;
}

static int f_sqlite3_result_fetchk(lua_State* L, int status, lua_KContext ctx) {
  sqlite3_result_t* sqlite3_result = lua_tosqlite3_result(L, 1);
  switch (sqlite3_step(sqlite3_result->statement)) {
    case SQLITE_ROW: {
      lua_newtable(L);
      for (size_t i = 0; i < sqlite3_result->columns; ++i) {
        switch (sqlite3_column_type(sqlite3_result->statement, i)) {
          case SQLITE_INTEGER: lua_pushinteger(L, sqlite3_column_int64(sqlite3_result->statement, i)); break;
          case SQLITE_FLOAT: lua_pushnumber(L, sqlite3_column_double(sqlite3_result->statement, i)); break;
          case SQLITE_TEXT: lua_pushlstring(L, sqlite3_column_text(sqlite3_result->statement, i), sqlite3_column_bytes(sqlite3_result->statement, i)); break;
          case SQLITE_BLOB: lua_pushlstring(L, sqlite3_column_blob(sqlite3_result->statement, i), sqlite3_column_bytes(sqlite3_result->statement, i)); break;
          case SQLITE_NULL: lua_pushnil(L); break;
        }
        lua_rawseti(L, -2, i + 1);
      }
      return 1;
    }
    case SQLITE_DONE:
      if (f_sqlite3_result_close(L) == 2)
        return 2;
      lua_pushinteger(L, sqlite3_changes64(sqlite3_result->sqlite->db));
      lua_pushinteger(L, sqlite3_last_insert_rowid(sqlite3_result->sqlite->db));
      return 2;
    case SQLITE_BUSY:
      if (sqlite3_result->sqlite->nonblocking && lua_iscoroutine(L))
        return lua_yieldk(L, 0, 0, f_sqlite3_result_fetchk);
      // Deliberate fallthrough.
    default:
      lua_pushnil(L);
      lua_pushstring(L, sqlite3_errmsg(sqlite3_result->sqlite->db));
      return 2;
  }
  return 0;
}

static int f_sqlite3_result_fetch(lua_State* L) {
  return f_sqlite3_result_fetchk(L, 0, 0);
}


static int f_sqlite3_result_gc(lua_State* L) {
  sqlite3_result_t* sqlite3_result = lua_tosqlite3_result(L, 1);
  f_sqlite3_result_close(L);
  luaL_unref(L, LUA_REGISTRYINDEX, sqlite3_result->connection);
  return 0;
}

static const luaL_Reg f_sqlite3_result_api[] = {
  { "__gc",      f_sqlite3_result_gc    },
  { "fetch",     f_sqlite3_result_fetch },
  { "close",     f_sqlite3_result_close },
  { NULL,        NULL                 }
};


static sqlite3_t* lua_tosqlite3(lua_State* L, int index) {
  sqlite3_t* sqlite3 = (sqlite3_t*)lua_touserdata(L, index);
  return sqlite3;
}

static int f_sqlite3_query(lua_State* L) {
  sqlite3_t* sqlite = lua_tosqlite3(L, 1);
  size_t statement_length;
  const char* statement = luaL_checklstring(L, 2, &statement_length);
  sqlite3_stmt* stmt;
  if (sqlite3_prepare_v2(sqlite->db, statement, statement_length, &stmt, NULL) != SQLITE_OK) {
    lua_pushnil(L);
    lua_pushstring(L, sqlite3_errmsg(sqlite->db));
    return 2;
  }
  sqlite3_result_t* result = lua_newuserdata(L, sizeof(sqlite3_result_t));
  lua_pushvalue(L, 1);
  result->statement = stmt;
  result->connection = luaL_ref(L, LUA_REGISTRYINDEX);
  result->sqlite = sqlite;
  result->columns = sqlite3_column_count(stmt);
  lua_getfield(L, 1, "__mysql_result");
  lua_setmetatable(L, -2);
  // If this is a statement that returns no data, run it immediately.
  if (result->columns == 0) {
    int top = lua_gettop(L);
    lua_pushcfunction(L, f_sqlite3_result_fetch);
    lua_pushvalue(L, -2);
    lua_call(L, 1, LUA_MULTRET);
    return lua_gettop(L) - top;
  }
  return 1;
}

static int f_sqlite3_connect(lua_State* L) {
  sqlite3_t* sqlite3 = lua_newuserdata(L, sizeof(sqlite3_t));
  lua_pushvalue(L, 1);
  lua_setmetatable(L, -2);
  lua_getfield(L, 2, "database");
  const char* database = luaL_checkstring(L, -1);
  lua_getfield(L, 2, "nonblocking");
  sqlite3->nonblocking = lua_toboolean(L, -1);
  lua_getfield(L, 2, "foreign_keys");
  sqlite3->foreign_keys = lua_toboolean(L, -1);
  lua_pop(L, 3);
  if (sqlite3_open(database, &sqlite3->db) != SQLITE_OK) {
    lua_pushnil(L);
    lua_pushfstring(L, "can't open %s: %s", database, sqlite3_errmsg(sqlite3->db));
    return 2;
  }
  if (sqlite3->nonblocking)
    sqlite3_busy_timeout(sqlite3->db, 1);
  if (sqlite3->foreign_keys) {
    lua_pushcfunction(L, f_sqlite3_query);
    lua_pushvalue(L, -2);
    lua_pushliteral(L, "PRAGMA foreign_keys = ON");
    lua_call(L, 2, 0);
  }
  return 1;
}

static int f_sqlite3_quote(lua_State* L) {
  luaL_gsub(L, luaL_gsub(L, luaL_checkstring(L, 2), "\\", "\\\\"), "'", "\\'");
  lua_pushliteral(L, "'");
  lua_pushvalue(L, -2);
  lua_pushliteral(L, "'");
  lua_concat(L, 3);
  return 1;
}

static int f_sqlite3_escape(lua_State* L) {
  luaL_gsub(L, luaL_gsub(L, luaL_checkstring(L, 2), "\\", "\\\\"), "\\\"", "\\\"");
  lua_pushliteral(L, "\"");
  lua_pushvalue(L, -2);
  lua_pushliteral(L, "\"");
  lua_concat(L, 3);
  return 1;
}

static int f_sqlite3_close(lua_State* L) {
  sqlite3_t* sqlite3 = lua_tosqlite3(L, 1);
  sqlite3_close(sqlite3->db);
  return 0;
}

static int f_sqlite3_gc(lua_State* L) {
  return f_sqlite3_close(L);
}


static int f_sqlite3_type(lua_State* L) {
  lua_getfield(L, 2, "data_type");
  const char* type = luaL_checkstring(L, -1);
  if (strcmp(type, "string") == 0) {
    lua_pushliteral(L, "text");
  } else if (strcmp(type, "boolean") == 0 || strcmp(type, "int") == 0) {
    lua_pushliteral(L, "integer");
  } else if (strcmp(type, "float") == 0 || strcmp(type, "double") == 0) {
    lua_pushliteral(L, "real");
  }
  return 1;
}

static int f_sqlite3_fd(lua_State* L) {
  return 0;
}

static int f_sqlite3_txn_start(lua_State* L) {
  lua_pushliteral(L, "BEGIN");
  return f_sqlite3_query(L);
}

static int f_sqlite3_txn_commit(lua_State* L) {
  lua_pushliteral(L, "COMMIT");
  return f_sqlite3_query(L);
}

static int f_sqlite3_txn_rollback(lua_State *L) {
  lua_pushliteral(L, "ROLLBACK");
  return f_sqlite3_query(L);
}

static const luaL_Reg f_sqlite3_api[] = {
  { "__gc",          f_sqlite3_gc             },
  { "connect",       f_sqlite3_connect        },
  { "quote",         f_sqlite3_quote          },
  { "escape",        f_sqlite3_escape         },
  { "close",         f_sqlite3_close          },
  { "query",         f_sqlite3_query          },
  { "type",          f_sqlite3_type           },
  { "fd",            f_sqlite3_fd             },
  { "txn_start",     f_sqlite3_txn_start      },
  { "txn_commit",    f_sqlite3_txn_commit     },
  { "txn_rollback",  f_sqlite3_txn_rollback   },
  { NULL,        NULL                       }
};

int luaopen_dbix_sqlite3(lua_State* L) {
  lua_newtable(L);
  luaL_setfuncs(L, f_sqlite3_api, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_newtable(L);
  luaL_setfuncs(L, f_sqlite3_result_api, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_setfield(L, -2, "__sqlite3_result");
  return 1;
}
