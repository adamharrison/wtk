#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <libpq-fe.h>
#include <stdlib.h>
#include <string.h>


#define 	BOOLOID   16
#define 	BYTEAOID   17
#define 	CHAROID   18
#define 	NAMEOID   19
#define 	INT8OID   20
#define 	INT2OID   21
#define 	INT4OID   23
#define 	FLOAT4OID   700
#define 	FLOAT8OID   701
#define 	NUMERICOID   1700

typedef struct {
  PGconn* db;
  int nonblocking;
  int nonbuffering;
} postgres_t;

typedef struct {
  int connection;
  postgres_t* postgres;
  PGresult* result;
  int current_row;
  int columns;
  int rows;
} postgres_result_t;

static int lua_iscoroutine(lua_State* L) {
  int is_coroutine = !lua_pushthread(L);
  lua_pop(L, 1);
  return is_coroutine;
}

static postgres_result_t* lua_topostgres_result(lua_State* L, int index) {
  return (postgres_result_t*)lua_touserdata(L, index);
}

static int lua_yieldpostgres(lua_State* L, postgres_t* postgres, lua_KContext ctx, lua_KFunction func) {
  lua_newtable(L);
  lua_pushinteger(L, PQsocket(postgres->db));
  lua_setfield(L, -2, "socket");
  return lua_yieldk(L, 1, ctx, func);
}

static int f_postgres_result_closek(lua_State* L, int status, lua_KContext should_yield) {
  postgres_result_t* postgres_result = lua_topostgres_result(L, 1);
  while (postgres_result->result) {
    if (PQconsumeInput(postgres_result->postgres->db) == 0) {
      lua_pushnil(L);
      lua_pushstring(L, PQerrorMessage(postgres_result->postgres->db));
      if (postgres_result->result)
        PQclear(postgres_result->result);
      return 2;
    }
    if (PQisBusy(postgres_result->postgres->db)) {
      if (should_yield) 
        return lua_yieldpostgres(L, postgres_result->postgres, should_yield, f_postgres_result_closek);
      return -1;
    }
    if (postgres_result->result)
      PQclear(postgres_result->result);
    postgres_result->result = PQgetResult(postgres_result->postgres->db);
  }
  return 0;
}

static int f_postgres_result_close(lua_State* L) {
  return f_postgres_result_closek(L, 0, 1);
}

static int postgres_get_result(postgres_result_t* result, int nonblocking) {
  if (nonblocking) {
    if (PQconsumeInput(result->postgres->db) == 0)
      return -1;
    if (PQisBusy(result->postgres->db))
      return LUA_YIELD;
  }
  if (result->result)
    PQclear(result->result);
  result->result = PQgetResult(result->postgres->db);
  if (result->result) {
    result->rows = PQntuples(result->result);
    result->columns = PQnfields(result->result);
  }
  return 0;
}

static int f_postgres_result_fetchk(lua_State* L, int state, lua_KContext ctx) {
  postgres_result_t* postgres_result = lua_topostgres_result(L, 1);
  if (postgres_result->result && postgres_result->current_row >= postgres_result->rows) {
    int status = postgres_get_result(postgres_result, postgres_result->postgres->nonblocking && lua_iscoroutine(L));
    if (status == LUA_YIELD) {
        return lua_yieldpostgres(L, postgres_result->postgres, ctx, f_postgres_result_fetchk);
    } else if (status == -1) {
      lua_pushnil(L);
      lua_pushstring(L, PQerrorMessage(postgres_result->postgres->db));
      return 2;
    }
  }
  if (!postgres_result->result)
    return 0;
  lua_newtable(L);
  for (int i = 0; i < postgres_result->columns; ++i) {
    if (!PQgetisnull(postgres_result->result, postgres_result->current_row, i)) {
      const char* value = PQgetvalue(postgres_result->result, postgres_result->current_row, i);
      size_t length = PQgetlength(postgres_result->result, postgres_result->current_row, i);
      switch (PQftype(postgres_result->result, i)) {
        case BOOLOID: lua_pushboolean(L, strcmp(value, "t") == 0); break;
        case INT2OID:
        case INT4OID:
        case INT8OID:
          lua_pushinteger(L, atoll(value)); 
        break;
        case FLOAT4OID: 
        case FLOAT8OID: 
        case NUMERICOID:
          lua_pushnumber(L, atof(value)); 
        break;
        default: lua_pushlstring(L, value, length); break;
      }
    } else
      lua_pushnil(L);
    lua_rawseti(L, -2, i + 1);
  }
  postgres_result->current_row++;
  return 1;
}

static int f_postgres_result_fetch(lua_State* L) {
  return f_postgres_result_fetchk(L, 0, 0);
}


static int f_postgres_result_gc(lua_State* L) {
  postgres_result_t* postgres_result = lua_topostgres_result(L, 1);
  if (f_postgres_result_closek(L, 0, 0) == -1) {
    // in this case, we should've yielded. we *have* to block here.
    while (postgres_result->result) {
      if (postgres_result->result)
        PQclear(postgres_result->result);
      postgres_result->result = PQgetResult(postgres_result->postgres->db);
    }
  }
  luaL_unref(L, LUA_REGISTRYINDEX, postgres_result->connection);
  return 0;
}

static const luaL_Reg f_postgres_result_api[] = {
  { "__gc",      f_postgres_result_gc    },
  { "fetch",     f_postgres_result_fetch },
  { "close",     f_postgres_result_close },
  { NULL,        NULL                 }
};


static postgres_t* lua_topostgres(lua_State* L, int index) {
  postgres_t* postgres = (postgres_t*)lua_touserdata(L, index);
  return postgres;
}

typedef enum {
  CONNECTION_INIT,
  CONNECTION_STARTED_WAIT_WRITE,
  CONNECTION_STARTED_WAIT_READ,
  CONNECTION_READY
} postgres_connection_e;

static int f_postgres_connectk(lua_State* L, int status, lua_KContext ctx) {
  postgres_t* postgres = lua_topostgres(L, 3);
  switch(ctx) {
    case CONNECTION_INIT: {
      lua_getfield(L, 2, "hostname");
      const char* hostname = luaL_checkstring(L, -1);
      lua_getfield(L, 2, "database");
      const char* database = luaL_checkstring(L, -1);
      lua_getfield(L, 2, "username");
      const char* username = luaL_checkstring(L, -1);
      lua_getfield(L, 2, "password");
      const char* password = luaL_checkstring(L, -1);
      lua_getfield(L, 2, "port");
      int port = lua_isnil(L, -1) ? 5432 : luaL_checkinteger(L, -1);
      const char* keywords[] = { "host", "user", "password", "dbname", "port", NULL };
      char port_value[16];
      const char* values[] = { hostname, username, password, database, port_value, NULL };
      snprintf(port_value, sizeof(port_value), "%d", port);
      if (lua_iscoroutine(L) && postgres->nonblocking) {
        postgres->db = PQconnectStartParams(keywords, values, 0);
        ctx = CONNECTION_STARTED_WAIT_WRITE;
      } else {
        postgres->db = PQconnectdbParams(keywords, values, 0);
        ctx = CONNECTION_READY;
      }
      if (!postgres->db) {
        lua_pushnil(L);
        lua_pushstring(L, PQerrorMessage(postgres->db));
        lua_pop(L, 5);
        return 2;
      }
      lua_pop(L, 5);
      if (ctx == CONNECTION_READY)
        goto ready;
    }
    // deliberate fallthrough
    case CONNECTION_STARTED_WAIT_READ:
    case CONNECTION_STARTED_WAIT_WRITE: {
      int fd = PQsocket(postgres->db);
      int result = PQsocketPoll(fd, ctx == CONNECTION_STARTED_WAIT_READ, ctx == CONNECTION_STARTED_WAIT_WRITE, 0);
      if (result < 0) {
        lua_pushnil(L);
        lua_pushstring(L, PQerrorMessage(postgres->db));
        return 2;
      } else if (result == 0) {
        return lua_yieldpostgres(L, postgres, ctx, f_postgres_connectk);
      }
      int poll = PQconnectPoll(postgres->db);
      switch (poll) {
        case PGRES_POLLING_READING: return lua_yieldpostgres(L, postgres, CONNECTION_STARTED_WAIT_READ, f_postgres_connectk);
        case PGRES_POLLING_WRITING: return lua_yieldpostgres(L, postgres, CONNECTION_STARTED_WAIT_WRITE, f_postgres_connectk);
        case PGRES_POLLING_FAILED:
          lua_pushnil(L);
          lua_pushstring(L, PQerrorMessage(postgres->db));
          return 2;
        case PGRES_POLLING_OK:
          goto ready;
      }
    } break;
    case CONNECTION_READY: break;
  }
  ready:
  if (PQstatus(postgres->db) == CONNECTION_BAD) {
    lua_pushnil(L);
    lua_pushstring(L, PQerrorMessage(postgres->db));
    return 2;
  }
  return 1;
}


static int f_postgres_connect(lua_State* L) {
  postgres_t* postgres = lua_newuserdata(L, sizeof(postgres_t));
  lua_pushvalue(L, 1);
  lua_setmetatable(L, -2);
  lua_getfield(L, 2, "nonblocking");
  postgres->nonblocking = lua_toboolean(L, -1);
  lua_getfield(L, 2, "nonbuffering");
  postgres->nonbuffering = lua_toboolean(L, -1);
  lua_pop(L, 2);
  return f_postgres_connectk(L, 0, 0);
}


static int f_postgres_quote(lua_State* L) {
  postgres_t* postgres = lua_topostgres(L, 1);
  size_t from_length;
  const char* from = luaL_checklstring(L, 2, &from_length);
  size_t to_max_length = from_length*2 + 1;
  char quote_buffer[4096];
  char* to = to_max_length > sizeof(quote_buffer) ? malloc(to_max_length) : quote_buffer;
  if (!to)
    return luaL_error(L, "can't allocate memory");
  int err;
  size_t to_length = PQescapeStringConn(postgres->db, to, from, from_length, &err);
  lua_pushlstring(L, to, to_length);
  if (to_max_length > sizeof(quote_buffer))
    free(to);
  return 1;
}

static int f_postgres_escape(lua_State* L) {
  postgres_t* postgres = lua_topostgres(L, 1);
  size_t from_length;
  const char* from = luaL_checklstring(L, 2, &from_length);
  char* str = PQescapeIdentifier(postgres->db, from, from_length);
  lua_pushstring(L, str);
  PQfreemem(str);
  return 1;
}

static int f_postgres_close(lua_State* L) {
  postgres_t* postgres = lua_topostgres(L, 1);
  if (postgres->db) {
    PQfinish(postgres->db);
    postgres->db = NULL;
  }
  return 0;
}

static int f_postgres_gc(lua_State* L) {
  return f_postgres_close(L);
}

typedef enum {
  QUERY_INIT,
  QUERY_WAITING
} query_status_e;

static int f_postgres_queryk(lua_State* L, int state, lua_KContext ctx) {
  postgres_t* postgres = lua_topostgres(L, 1);
  switch (ctx) {
    case QUERY_INIT: {
      size_t statement_length;
      const char* statement = luaL_checklstring(L, 2, &statement_length);
      if (PQsendQuery(postgres->db, statement) == 0) {
        lua_pushnil(L);
        lua_pushstring(L, PQerrorMessage(postgres->db));
        return 2;
      }
      postgres_result_t* result = lua_newuserdata(L, sizeof(postgres_result_t));
      result->postgres = postgres;
      result->result = NULL;
      result->current_row = 0;
      result->columns = -1;
      result->rows = -1;
      lua_getfield(L, 1, "__postgres_result");
      lua_setmetatable(L, -2);
    } // deliberate fallthrough
    case QUERY_WAITING: {
      postgres_result_t* result = lua_touserdata(L, -1);
      int status = postgres_get_result(result, postgres->nonblocking && lua_iscoroutine(L)); // get first result
      if (status == LUA_YIELD) {
        return lua_yieldpostgres(L, postgres, QUERY_WAITING, f_postgres_queryk);
      } else if (status == -1) {
        lua_pushnil(L);
        lua_pushstring(L, PQerrorMessage(postgres->db));
        return 2;
      }
      switch (PQresultStatus(result->result)) {
        case PGRES_NONFATAL_ERROR:
        case PGRES_COMMAND_OK:
          lua_pushinteger(L, atoll(PQcmdTuples(result->result)));
          Oid insertedValue = PQoidValue(result->result);
          if (insertedValue == InvalidOid)
            lua_pushnil(L);
          else
            lua_pushinteger(L, insertedValue);
          int status = postgres_get_result(result, postgres->nonblocking && lua_iscoroutine(L)); 
          if (status == LUA_YIELD) {
            return lua_yieldpostgres(L, postgres, QUERY_WAITING, f_postgres_queryk);
          } else if (status == -1) {
            lua_pushnil(L);
            lua_pushstring(L, PQerrorMessage(postgres->db));
          }
          return 2;
        case PGRES_TUPLES_OK:
        case PGRES_SINGLE_TUPLE:
          break;
        case PGRES_FATAL_ERROR:
          lua_pushnil(L);
          lua_pushstring(L, PQerrorMessage(postgres->db));
          return 2;
        default:
          return 0;
      }
      return 1;
    }
  }
}

static int f_postgres_query(lua_State* L) {
  return f_postgres_queryk(L, 0, QUERY_INIT);
}

static int f_postgres_type(lua_State* L) {
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
  } else if (strcmp(type, "datetime") == 0) {
    lua_pushliteral(L, "timestamp");
  }
  lua_getfield(L, 2, "auto_increment");
  if (lua_isboolean(L, -1)) {
    lua_pushliteral(L, "serial");
  } else {
    lua_pop(L, 1);
  }
  return 1;
}

static int f_postgres_fd(lua_State* L) {
  postgres_t* postgres = lua_topostgres(L, 1);
  lua_pushinteger(L, PQsocket(postgres->db));
  return 1;
}

static int f_postgres_txn_start(lua_State* L) {
  lua_pushliteral(L, "START TRANSACTION");
  return f_postgres_query(L);
}

static int f_postgres_txn_commit(lua_State* L) {
  lua_pushliteral(L, "COMMIT");
  return f_postgres_query(L);
}

static int f_postgres_txn_rollback(lua_State *L) {
  lua_pushliteral(L, "ROLLBACK");
  return f_postgres_query(L);
}

static const luaL_Reg f_postgres_api[] = {
  { "__gc",          f_postgres_gc             },
  { "connect",       f_postgres_connect        },
  { "quote",         f_postgres_quote          },
  { "escape",        f_postgres_escape         },
  { "close",         f_postgres_close          },
  { "query",         f_postgres_query          },
  { "type",          f_postgres_type           },
  { "fd",            f_postgres_fd             },
  { "txn_start",     f_postgres_txn_start      },
  { "txn_commit",    f_postgres_txn_commit     },
  { "txn_rollback",  f_postgres_txn_rollback   },
  { NULL,        NULL                       }
};

int luaopen_dbix_dbd_postgres(lua_State* L) {
  lua_newtable(L);
  luaL_setfuncs(L, f_postgres_api, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_newtable(L);
  luaL_setfuncs(L, f_postgres_result_api, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_setfield(L, -2, "__postgres_result");
  return 1;
}
