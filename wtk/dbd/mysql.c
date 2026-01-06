#ifndef lua_h
    #include <lua.h>
#endif
#ifndef lualib_h
    #include <lualib.h>
#endif
#ifndef lauxlib_h
    #include <lauxlib.h>
#endif
#include <mysql.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  MYSQL* db;
  int nonblocking;
  int nonbuffering;
} mysql_t;

typedef struct {
  int connection;
  mysql_t* mysql;
  MYSQL_RES* result;
  MYSQL_FIELD* fields;
  size_t columns;
} mysql_result_t;


static mysql_t* lua_tomysql(lua_State* L, int index) {
  mysql_t* mysql = (mysql_t*)lua_touserdata(L, index);
  return mysql;
}

static int lua_yieldmysql(lua_State* L, mysql_t* mysql, lua_KContext ctx, lua_KFunction func) {
  lua_newtable(L);
  lua_pushinteger(L, mysql->db->net.fd);
  lua_setfield(L, -2, "socket");
  return lua_yieldk(L, 1, ctx, func);
}

static int f_mysql_fd(lua_State* L) {
  mysql_t* mysql = lua_tomysql(L, 1);
  lua_pushinteger(L, mysql->db->net.fd);
  return 1;
}


static int lua_iscoroutine(lua_State* L) {
  int is_coroutine = !lua_pushthread(L);
  lua_pop(L, 1);
  return is_coroutine;
}

static mysql_result_t* lua_tomysql_result(lua_State* L, int index) {
  return (mysql_result_t*)lua_touserdata(L, index);
}

/* The actual operations. */
static enum net_async_status f_mysql_fetch_row(int nonblocking, MYSQL_RES* result, MYSQL_ROW* row) {
  if (nonblocking) {
    return mysql_fetch_row_nonblocking(result, row);
  } else {
    *row = mysql_fetch_row(result);
    return NET_ASYNC_COMPLETE;
  }
}

static enum net_async_status f_mysql_real_connect(mysql_t* mysql, int nonblocking, const char* hostname, const char* username, const char* password, const char* database, int port) {
  if (nonblocking) {
    return mysql_real_connect_nonblocking(mysql->db, hostname, username, password, database, port, NULL, 0);
  }
  mysql->db = mysql_real_connect(mysql->db, hostname, username, password, database, port, NULL, 0);
  return mysql->db ? NET_ASYNC_COMPLETE : NET_ASYNC_ERROR;
}


static enum net_async_status f_mysql_real_query(mysql_t* mysql, int nonblocking, const char* statement, size_t statement_length) {
  if (nonblocking)
    return mysql_real_query_nonblocking(mysql->db, statement, statement_length);
  return mysql_real_query(mysql->db, statement, statement_length) ? NET_ASYNC_ERROR : NET_ASYNC_COMPLETE;
}

static enum net_async_status f_mysql_get_result(mysql_t* mysql, int nonblocking, int nonbuffering, MYSQL_RES** result) {
  if (nonbuffering) {
    *result = mysql_use_result(mysql->db);
    if (!result)
      return NET_ASYNC_ERROR;
    return NET_ASYNC_COMPLETE;
  } else {
    if (nonblocking)
      return mysql_store_result_nonblocking(mysql->db, result);
    *result = mysql_store_result(mysql->db);
    if (!result && mysql_field_count(mysql->db) > 0)
      return NET_ASYNC_ERROR;
    return NET_ASYNC_COMPLETE;
  }
}
/* The actual operations. */

typedef enum {
  MYSQL_RESULT_FETCH_STATUS_FETCHING,
  MYSQL_RESULT_FETCH_STATUS_DONE
} mysql_result_fetch_status_e;


static int f_mysql_result_closek(lua_State* L, int status, lua_KContext ctx) {
  mysql_result_t* mysql_result = lua_tomysql_result(L, 1);
  if (mysql_result->result) {
    if (mysql_result->mysql->nonblocking && lua_iscoroutine(L)) {
      switch (mysql_free_result_nonblocking(mysql_result->result)) {
        case NET_ASYNC_ERROR:
          lua_pushnil(L);
          lua_pushstring(L, mysql_error(mysql_result->mysql->db));
          return 2;
        case NET_ASYNC_NOT_READY:
          return lua_yieldmysql(L, mysql_result->mysql, ctx, f_mysql_result_closek);
      }
    } else {
      mysql_free_result(mysql_result->result);
    }
    mysql_result->result = NULL;
  }
  return 0;
}

static int f_mysql_result_close(lua_State* L) {
  return f_mysql_result_closek(L, 0, 0);
}

static int f_mysql_result_fetchk(lua_State* L, int state, lua_KContext ctx) {
  mysql_result_t* mysql_result = lua_tomysql_result(L, 1);
  if (!mysql_result->result)
    return 0;
  mysql_result_fetch_status_e status = ctx;
  switch (status) {
    case MYSQL_RESULT_FETCH_STATUS_FETCHING: {
      MYSQL_ROW row;
      switch (f_mysql_fetch_row(mysql_result->mysql->nonblocking && lua_iscoroutine(L), mysql_result->result, &row)) {
        case NET_ASYNC_ERROR:
          lua_pushnil(L);
          lua_pushstring(L, mysql_error(mysql_result->mysql->db));
          return 2;
        case NET_ASYNC_NOT_READY:
          return lua_yieldmysql(L, mysql_result->mysql, status, f_mysql_result_fetchk);
      }
      if (row) {
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
      } else {
        status = MYSQL_RESULT_FETCH_STATUS_DONE;
      }
    }
    case MYSQL_RESULT_FETCH_STATUS_DONE: {
      return f_mysql_result_closek(L, 0, status);
    }
  }
}

static int f_mysql_result_fetch(lua_State* L) {
  return f_mysql_result_fetchk(L, 0, 0);
}


static int f_mysql_result_gc(lua_State* L) {
  mysql_result_t* mysql_result = lua_tomysql_result(L, 1);
  f_mysql_result_close(L);
  luaL_unref(L, LUA_REGISTRYINDEX, mysql_result->connection);
  return 0;
}

static const luaL_Reg f_mysql_result_api[] = {
  { "__gc",      f_mysql_result_gc    },
  { "fetch",     f_mysql_result_fetch },
  { "close",     f_mysql_result_close },
  { NULL,        NULL                 }
};


static int f_mysql_connectk(lua_State* L, int status, lua_KContext ctx) {
  mysql_t* mysql = lua_tomysql(L, 3);
  lua_getfield(L, 2, "hostname");
  const char* hostname = luaL_checkstring(L, -1);
  lua_getfield(L, 2, "database");
  const char* database = luaL_checkstring(L, -1);
  lua_getfield(L, 2, "username");
  const char* username = luaL_checkstring(L, -1);
  lua_getfield(L, 2, "password");
  const char* password = luaL_checkstring(L, -1);
  lua_getfield(L, 2, "port");
  int port = lua_isnil(L, -1) ? 3306 : luaL_checkinteger(L, -1);
  switch (f_mysql_real_connect(mysql, mysql->nonblocking && lua_iscoroutine(L), hostname, username, password, database, port)) {
    case NET_ASYNC_ERROR:
      lua_pushnil(L);
      lua_pushstring(L, mysql_error(mysql->db));
      return 2;
    case NET_ASYNC_NOT_READY: {
      lua_pop(L, 5);
      return lua_yieldmysql(L, mysql, ctx, f_mysql_connectk);
    }
  }
  lua_pop(L, 5);
  return 1;
}

static int f_mysql_connect(lua_State* L) {
  mysql_t* mysql = lua_newuserdata(L, sizeof(mysql_t));
  mysql->db = mysql_init(NULL);
  lua_pushvalue(L, 1);
  lua_setmetatable(L, -2);
  lua_getfield(L, 2, "nonblocking");
  mysql->nonblocking = lua_toboolean(L, -1);
  lua_getfield(L, 2, "nonbuffering");
  mysql->nonbuffering = lua_toboolean(L, -1);
  lua_getfield(L, 2, "nonautocommitting");
  mysql_autocommit(mysql->db, !lua_toboolean(L, -1));
  lua_pop(L, 3);
  return f_mysql_connectk(L, 0, 0);
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
  if (mysql->db) {
    mysql_close(mysql->db);
    mysql->db = NULL;
  }
  return 0;
}

static int f_mysql_gc(lua_State* L) {
  return f_mysql_close(L);
}


typedef enum {
  STATUS_QUERY,
  STATUS_STORE
} query_status_e;

static int f_mysql_queryk(lua_State* L, int state, lua_KContext ctx) {
  mysql_t* mysql = lua_tomysql(L, 1);
  size_t statement_length;
  const char* statement = luaL_checklstring(L, 2, &statement_length);
  switch (ctx) {
    case STATUS_QUERY: {
      switch (f_mysql_real_query(mysql, mysql->nonblocking && lua_iscoroutine(L),  statement, statement_length)) {
        case NET_ASYNC_ERROR:
          lua_pushnil(L);
          lua_pushstring(L, mysql_error(mysql->db));
          return 2;
        case NET_ASYNC_NOT_READY:
          return lua_yieldmysql(L, mysql, ctx, f_mysql_queryk);
      }
      ctx = STATUS_STORE;
    }
    case STATUS_STORE: {
      MYSQL_RES* response = NULL;
      switch (f_mysql_get_result(mysql, mysql->nonblocking && lua_iscoroutine(L), mysql->nonbuffering, &response)) {
        case NET_ASYNC_ERROR:
          lua_pushnil(L);
          lua_pushstring(L, mysql_error(mysql->db));
          return 2;
        case NET_ASYNC_NOT_READY:
          return lua_yieldmysql(L, mysql, ctx, f_mysql_queryk);
      }
      if (response) {  
        mysql_result_t* result = lua_newuserdata(L, sizeof(mysql_result_t));
        lua_pushvalue(L, 1);
        result->result = response;
        result->mysql = mysql;
        result->columns = mysql_num_fields(response);
        result->fields = mysql_fetch_fields(response);
        result->connection = luaL_ref(L, LUA_REGISTRYINDEX);
        lua_getfield(L, 1, "__mysql_result");
        lua_setmetatable(L, -2);
        return 1;
      } else {
        lua_pushinteger(L, mysql_affected_rows(mysql->db));
        lua_pushinteger(L, mysql_insert_id(mysql->db));
        return 2;
      }
    }
  }
  return 0;
}

static int f_mysql_query(lua_State* L) {
  return f_mysql_queryk(L, 0, STATUS_QUERY);
}

static int f_mysql_type(lua_State* L) {
  lua_getfield(L, 2, "data_type");
  const char* type = luaL_checkstring(L, -1);
  if (strcmp(type, "string") == 0) {
    lua_pushliteral(L, "varchar(");
    lua_getfield(L, 2, "length");
    if (lua_type(L, -1) != LUA_TNUMBER) {
      lua_pop(L, 1);
      lua_pushinteger(L, 255);
    }
    lua_pushliteral(L, ")");
    lua_concat(L, 3);
  } else if (strcmp(type, "boolean") == 0) {
    lua_pushliteral(L, "tinyint(1)");
  }
  lua_getfield(L, 2, "auto_increment");
  if (lua_isboolean(L, -1)) {
    lua_pop(L, 1);
    lua_pushliteral(L, " AUTO_INCREMENT");
    lua_concat(L, 2);
  } else {
    lua_pop(L, 1);
  }
  return 1;
}

static int f_mysql_txn_start(lua_State* L) {
  lua_pushliteral(L, "BEGIN");
  lua_replace(L, -2);
  return f_mysql_queryk(L, 0, STATUS_QUERY);
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
  { "type",          f_mysql_type           },
  { "fd",            f_mysql_fd             },
  { "txn_start",     f_mysql_txn_start      },
  { "txn_commit",    f_mysql_txn_commit     },
  { "txn_rollback",  f_mysql_txn_rollback   },
  { NULL,        NULL                       }
};

int luaopen_wtk_dbix_dbd_mysql_c(lua_State* L) {
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
