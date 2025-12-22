#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <math.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/epoll.h>
#include <sys/timerfd.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/time.h>

typedef struct { int fd; } generic_fd_t;
typedef struct { int fd; double recurring; } countdown_t;

#define lua_newobject(L, name) lua_newuserdata(L, sizeof(name##_t)); luaL_setmetatable(L, "wtk." #name);

static int f_loop_new(lua_State* L) {
	lua_newtable(L);
	int epollfd = epoll_create1(0);
	lua_pushinteger(L, epollfd); lua_setfield(L, -2, "epollfd");
	lua_newtable(L); lua_setfield(L, -2, "fds");
	lua_newtable(L); lua_setfield(L, -2, "deferred");
	luaL_setmetatable(L, "wtk.loop");
  return 1;
}

static int lua_tofd(lua_State* L, int index) {
	if (lua_type(L, index) == LUA_TNUMBER) {
		return lua_tointeger(L, index);
	} else {
		luaL_checktype(L, index, LUA_TUSERDATA);
		generic_fd_t* fd = lua_touserdata(L, index);
		return fd->fd;
	}
}

static int f_loop_add(lua_State* L) {
	if (lua_type(L, 2) == LUA_TFUNCTION) {
		luaL_getsubtable(L, 1, "deferred");
		int length = lua_rawlen(L, -1);
		luaL_checktype(L, 2, LUA_TFUNCTION);
		lua_pushvalue(L, 2);
		lua_rawseti(L, -2, length + 1);
		lua_pushvalue(L, 1);
		return 1;
	}
	int mask = EPOLLRDHUP | EPOLLPRI | EPOLLERR | EPOLLHUP;
	if (lua_type(L, 4) == LUA_TSTRING)	{
		const char* type = lua_tostring(L, 4);
		if (strcmp(type, "read") == 0 || strcmp(type, "both") == 0)
			mask |= EPOLLIN;
		if (strcmp(type, "write") == 0 || strcmp(type, "both") == 0)
			mask |= EPOLLOUT;
	} else
		mask |= EPOLLIN;
	if (lua_isboolean(L, 5))
		mask |= EPOLLET;
	lua_getfield(L, 1, "epollfd");
	int epollfd = luaL_checkinteger(L, -1);
	lua_pop(L, 1);
	int is_table = lua_type(L, 2) == LUA_TTABLE;
	int length = is_table ? lua_rawlen(L, 2) : 1;

	lua_newtable(L);
	luaL_checktype(L, 3, LUA_TFUNCTION);
	lua_pushvalue(L, 3);
	lua_rawseti(L, -2, 1);
	lua_pushvalue(L, 2);
	lua_rawseti(L, -2, 2);
	int table = lua_gettop(L);

	for (int i = 0; i < length; ++i) {
		int fd;
		if (is_table) {
			lua_rawgeti(L, 2, i + 1);
			fd = lua_tofd(L, -1);
			lua_pop(L, 1);
		} else {
			fd = lua_tofd(L, 2);
		}
		struct epoll_event event = { .events = mask, .data = { .fd = fd } };
		epoll_ctl(epollfd, EPOLL_CTL_ADD, fd, &event);
		luaL_getsubtable(L, 1, "fds");
		lua_pushinteger(L, fd); 
		lua_pushvalue(L, table);
		lua_rawset(L, -3);
		lua_pushinteger(L, fd); // Should probably fix this up to actually handle muliptle FDs correctly.
	}
  return 1;
}

static int f_loop_rm(lua_State* L) {
	lua_getfield(L, 1, "epollfd");
	int fd = lua_tofd(L, 2);
	epoll_ctl(luaL_checkinteger(L, -1), EPOLL_CTL_DEL, fd, NULL);
	luaL_getsubtable(L, 1, "fds");
	lua_pushinteger(L, fd);
	lua_pushnil(L); 
	lua_rawset(L, -3);
	lua_pop(L, 1);
  return 1;
}

static int f_loop_run(lua_State* L) {
	lua_getfield(L, 1, "epollfd");
	int epollfd = luaL_checkinteger(L, -1);
	struct epoll_event ev, events[100];
	luaL_getsubtable(L, 1, "fds");
	while (1) {
		luaL_getsubtable(L, 1, "deferred");
		size_t len = lua_rawlen(L, -1);
		if (len) {
			for (int i = 1; i <= len; ++i) {
				lua_rawgeti(L, -1, i);
				lua_call(L, 0, 0);
			}
			lua_newtable(L);
			lua_setfield(L, 1, "deferred");
		}
		lua_pop(L, 1);
		int nfds = epoll_wait(epollfd, events, 100, -1);
		for (int n = 0; n < nfds; ++n) {
			lua_pushinteger(L, events[n].data.fd);
			lua_rawget(L, -2);
			lua_rawgeti(L, -1, 2);
			countdown_t* countdown = luaL_testudata(L, -1, "wtk.server.countdown");
			if (countdown) {
				long long length;
				read(countdown->fd, &length, sizeof(length));
			}
			lua_pop(L, 1);
			lua_rawgeti(L, -1, 1);
			if (lua_pcall(L, 0, 1, 0))
				return luaL_error(L, "error running callback: %s", lua_tostring(L, -1));
			if (lua_type(L, -1) == LUA_TBOOLEAN && !lua_toboolean(L, -1))  {
				epoll_ctl(luaL_checkinteger(L, -1), EPOLL_CTL_DEL, events[n].data.fd, NULL);
				luaL_getsubtable(L, 1, "fds");
				lua_pushinteger(L, events[n].data.fd);
				lua_pushnil(L); 
				lua_rawset(L, -3);
			}
			lua_pop(L, 2);
		}
	}
  return 1;
}

static int f_loop_gc(lua_State* L) {
	lua_getfield(L, 1, "epollfd");
	close(luaL_checkinteger(L, -1));
  return 1;
}

static const luaL_Reg loop_lib[] = {
  { "new",      f_loop_new   },
  { "add",      f_loop_add   },
  { "rm",       f_loop_rm    },
  { "run",      f_loop_run   },
  { "__gc",     f_loop_gc    },
  { NULL,       NULL }
};


static int f_system_mtime(lua_State* L) {
	struct stat file;
	if (stat(luaL_checkstring(L, 1), &file)) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	lua_pushnumber(L, file.st_mtime);
  return 1;
}

static int f_system_time(lua_State* L) {
	struct timeval tv;
	gettimeofday(&tv, NULL);
	lua_pushnumber(L, (double)tv.tv_sec + tv.tv_usec / 1000000.0);
  return 1;
}

static int f_system_isatty(lua_State* L){
	lua_pushboolean(L, isatty(luaL_checkinteger(L, 1)));
	return 1;
}

static const luaL_Reg system_lib[] = {
  { "mtime",    f_system_mtime  },
  { "time",     f_system_time   },
  { "isatty",	 f_system_isatty  },
  { NULL,       NULL }
};

static int f_countdown_new(lua_State* L) {
	countdown_t* countdown = lua_newobject(L, countdown);
	countdown->fd = timerfd_create(CLOCK_MONOTONIC, 0);
	double offset = luaL_checknumber(L, 1);
	countdown->recurring = luaL_optnumber(L, 2, 0);
	struct timespec now = {0};
	struct itimerspec new_value = {0};
	if (clock_gettime(CLOCK_MONOTONIC, &now) == -1)
		return luaL_error(L, "can't get time: %s", strerror(errno));
	new_value.it_value.tv_sec = now.tv_sec + (int)offset;
	new_value.it_value.tv_nsec = now.tv_nsec + (int)(fmod(offset, 1.0) * (1000000000.0));
	new_value.it_interval.tv_sec = (int)countdown->recurring;
	new_value.it_interval.tv_nsec = (int)(fmod(countdown->recurring, 1.0) * (1000000000.0));
	if (timerfd_settime(countdown->fd, TFD_TIMER_ABSTIME, &new_value, NULL) == -1)
		return luaL_error(L, "can't set timer: %s", strerror(errno));
  return 1;
}

static int f_countdown_gc(lua_State* L) {
  countdown_t* countdown = luaL_checkudata(L, 1, "wtk.server.socket");
  if (countdown->fd)
		close(countdown->fd);
}

static const luaL_Reg countdown_lib[] = {
  { "new",      f_countdown_new   },
  { "__gc",		 f_countdown_gc },
  { NULL,       NULL }
};


#define luaL_newclass(L, name) lua_pushliteral(L, #name); luaL_newmetatable(L, "wtk." #name); luaL_setfuncs(L, name##_lib, 0); lua_pushvalue(L, -1); lua_setfield(L, -2, "__index"); lua_rawset(L, -3);

int luaopen_wtk(lua_State* L) {
	lua_newtable(L);
  luaL_newclass(L, system);
  luaL_newclass(L, countdown);
  luaL_newclass(L, loop);
  const char* init_code = "local wtk = ...\n\
  wtk.Loop = wtk.loop\n\
  package.loaded['wtk.loop'] = wtk.loop\n\
  package.loaded['wtk.system'] = wtk.system\n\
	function wtk.pargs(arguments, options, short_options)\n\
		local args = {}\n\
		local i = 1\n\
		for k,v in pairs(arguments) do if math.type(k) ~= 'integer' then args[k] = v end end\n\
		while i <= #arguments do\n\
			local s,e, option, value = arguments[i]:find('%-%-([^=]+)=?(.*)')\n\
			local option_name = s and (options[option] and option or option:gsub('^no%-', ''))\n\
			if options[option_name] then\n\
				local flag_type = options[option_name]\n\
				if flag_type == 'flag' then\n\
					args[option] = (option_name == option or not option:find('^no-')) and true or false\n\
				elseif flag_type == 'string' or flag_type == 'number' or flag_type == 'array' then\n\
					if not value or value == '' then\n\
						if i == #arguments then error('option ' .. option .. ' requires a ' .. flag_type) end\n\
						value = arguments[i+1]\n\
						i = i + 1\n\
					end\n\
					if flag_type == 'number' and tonumber(value) == nil then error('option ' .. option .. ' should be a number') end\n\
					if flag_type == 'array' then\n\
						args[option] = args[option] or {}\n\
						table.insert(args[option], value)\n\
					else\n\
						args[option] = value\n\
					end\n\
				end\n\
			else\n\
				local flags = nil\n\
				s,e,flags = arguments[i]:find('%-(%w+)')\n\
				if short_options and flags then\n\
					for i = 1, #flags do\n\
						local op = short_options[flags:sub(i, i)]\n\
						if op then\n\
							assert(options[op] == 'flag', 'requries ' .. op .. ' to be a flag')\n\
							args[op] = true\n\
						end\n\
					end\n\
				end\n\
				if not flags then\n\
					table.insert(args, arguments[i])\n\
				end\n\
			end\n\
			i = i + 1\n\
		end\n\
		return args\n\
	end";
	if (luaL_loadstring(L, init_code))
    return lua_error(L);
  lua_pushvalue(L, -2);
  lua_call(L, 1, 0);
  return 1;
}
