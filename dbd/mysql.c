#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <mysql/mysql.h>
#include <stdlib.h>

typedef struct {
  int connection;
  MYSQL_RES* result;
  MYSQL_FIELD* fields;
  size_t columns;
} mysql_result_t;

static mysql_result_t* lua_tomysql_result(lua_State* L, int index) {
  mysql_result_t* mysql_result = (mysql_result_t*)lua_touserdata(L, 1);
  return mysql_result;
}

static int f_mysql_result_fetch(lua_State* L) {
  mysql_result_t* mysql_result = lua_tomysql_result(L, 1);
  MYSQL_ROW row = mysql_fetch_row(mysql_result->result);
  if (!row)
    return 0;
  lua_newtable(L);
  unsigned long* lengths = mysql_fetch_lengths(mysql_result->result);
  for (size_t i = 0; i < mysql_result->columns; i++) {
    if (row[i]) {
      switch (mysql_result->fields[i].type) {
        case MYSQL_TYPE_TINY:
        case MYSQL_TYPE_SHORT:
        case MYSQL_TYPE_LONG:
        case MYSQL_TYPE_LONGLONG:
        case MYSQL_TYPE_INT24:
          lua_pushinteger(L, atoll(row[i]));
        break;
        case MYSQL_TYPE_FLOAT:
        case MYSQL_TYPE_DOUBLE:
          lua_pushnumber(L, atof(row[i]));
        break;
        case MYSQL_TYPE_NULL: lua_pushnil(L); break;
        default: lua_pushlstring(L, row[i], lengths[i]); break;
      }
    } else {
      lua_pushnil(L);
    }
    lua_rawseti(L, -2, i + 1);
  }
  lua_pushinteger(L, mysql_result->columns);
  return 2;
}

static int f_mysql_result_close(lua_State* L) {
  mysql_result_t* mysql_result = lua_tomysql_result(L, 1);
  mysql_free_result(mysql_result->result);
  luaL_unref(L, LUA_REGISTRYINDEX, mysql_result->connection);
  return 0;
}

static int f_mysql_result_gc(lua_State* L) {
  return f_mysql_result_close(L);
}

static const luaL_Reg f_mysql_result_api[] = {
  { "__gc",      f_mysql_result_gc    },
  { "fetch",     f_mysql_result_fetch },
  { "close",     f_mysql_result_close },
  { NULL,        NULL                 }
};

typedef struct {
  MYSQL* db;
  int nonblocking;
} mysql_t;

static mysql_t* lua_tomysql(lua_State* L, int index) {
  mysql_t* mysql = (mysql_t*)lua_touserdata(L, 1);
  return mysql;
}

static int f_mysql_connect(lua_State* L) {
  mysql_t* mysql = lua_newuserdata(L, sizeof(mysql_t));
  lua_pushvalue(L, 1);
  lua_setmetatable(L, -2);
  mysql->db = mysql_init(NULL);
  lua_getfield(L, 2, "nonblock");
  mysql->nonblocking = lua_toboolean(L, -1);
  lua_getfield(L, 2, "hostname");
  const char* hostname = luaL_checkstring(L, -1);
  lua_getfield(L, 2, "database");
  const char* database = luaL_checkstring(L, -1);
  lua_getfield(L, 2, "username");
  const char* user = luaL_checkstring(L, -1);
  lua_getfield(L, 2, "password");
  const char* password = luaL_checkstring(L, -1);
  lua_getfield(L, 2, "port");
  int port = lua_isnil(L, -1) ? 3306 : luaL_checkinteger(L, -1);
  if (mysql->nonblocking) {
    return luaL_error(L, "unsupported");
  } else {
    if (!mysql_real_connect(mysql->db, hostname, user, password, database, port, NULL, 0)) {
      lua_pushnil(L);
      lua_pushstring(L, mysql_error(mysql->db));
      return 2;
    }
  }
  lua_pop(L, 6);
  return 1;
}


static int f_mysql_quote(lua_State* L) {
  
  luaL_gsub(L, luaL_gsub(L, luaL_checkstring(L, 2), "\\", "\\\\"), "\"", "\\\"");
  lua_pushliteral(L, "\"");
  lua_pushvalue(L, -2);
  lua_pushliteral(L, "\"");
  lua_concat(L, 3);
  return 1;
}

static int f_mysql_escape(lua_State* L) {
  mysql_t* mysql = lua_tomysql(L, 1);
  size_t from_length;
  const char* from = luaL_checklstring(L, 2, &from_length);
  size_t to_max_length = from_length*2 + 1;
  char quote_buffer[4096];
  char* to = to_max_length > sizeof(quote_buffer) ? malloc(to_max_length) : quote_buffer;
  if (!to)
    return luaL_error(L, "can't allocate memory");
  size_t to_length = mysql_real_escape_string_quote(mysql->db, to, from, from_length, '`');
  lua_pushlstring(L, to, to_length);
  if (to_max_length > sizeof(quote_buffer))
    free(to);
  return 1;
}

static int f_mysql_close(lua_State* L) {
  mysql_t* mysql = lua_tomysql(L, 1);
  mysql_close(mysql->db);
  return 0;
}

static int f_mysql_gc(lua_State* L) {
  return f_mysql_close(L);
}

static int f_mysql_query(lua_State* L) {
  mysql_t* mysql = lua_tomysql(L, 1);
  if (mysql->nonblocking) {
    return luaL_error(L, "unsupported");
  } else {
    size_t statement_length;
    const char* statement = luaL_checklstring(L, 2, &statement_length);
    if (mysql_real_query(mysql->db, statement, statement_length)) {
      lua_pushnil(L);
      lua_pushstring(L, mysql_error(mysql->db));
      return 2;
    }
    MYSQL_RES* response = mysql_store_result(mysql->db);
    if (response) {  
      mysql_result_t* result = lua_newuserdata(L, sizeof(mysql_result_t));
      lua_pushvalue(L, 1);
      result->result = response;
      result->columns = mysql_num_fields(response);
      result->fields = mysql_fetch_fields(response);
      result->connection = luaL_ref(L, LUA_REGISTRYINDEX);
      lua_getfield(L, 1, "__mysql_result");
      lua_setmetatable(L, -2);
      return 1;
    } else {
      if (mysql_field_count(mysql->db) == 0) {
        lua_pushinteger(L, mysql_affected_rows(mysql->db));
        return 1;
      } else {
        lua_pushnil(L);
        lua_pushstring(L, mysql_error(mysql->db));
        return 2;
      }
    }
  }
  return 0;
}

static int f_mysql_txn_start(lua_State* L) {
  lua_pushcfunction(L, f_mysql_query);
  lua_pushliteral(L, "BEGIN");
  lua_call(L, 1, 2);
  return 2;
}

static int f_mysql_txn_commit(lua_State* L) {
  mysql_t* mysql = lua_tomysql(L, 1);
  if (mysql_commit(mysql->db)) {
    lua_pushnil(L);
    lua_pushstring(L, mysql_error(mysql->db));
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int f_mysql_txn_rollback(lua_State *L) {
  mysql_t* mysql = lua_tomysql(L, 1);
  if (mysql_rollback(mysql->db)) {
    lua_pushnil(L);
    lua_pushstring(L, mysql_error(mysql->db));
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static const luaL_Reg f_mysql_api[] = {
  { "__gc",          f_mysql_gc             },
  { "connect",       f_mysql_connect        },
  { "quote",         f_mysql_quote          },
  { "escape",        f_mysql_escape         },
  { "close",         f_mysql_close          },
  { "query",         f_mysql_query          },
  { "txn_start",     f_mysql_txn_start      },
  { "txn_commit",    f_mysql_txn_commit     },
  { "txn_rollback",  f_mysql_txn_rollback   },
  { NULL,        NULL                       }
};

int luaopen_dba_mysql(lua_State* L) {
  lua_newtable(L);
  luaL_setfuncs(L, f_mysql_api, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_newtable(L);
  luaL_setfuncs(L, f_mysql_result_api, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_setfield(L, -2, "__mysql_result");
  return 1;
}
