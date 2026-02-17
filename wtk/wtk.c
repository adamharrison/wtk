#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#ifdef WTK_BUNDLED_LUA
	#include "lua.c"
#else
	#pragma message "Using system lua."
#endif
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/time.h>

typedef struct { int fd; } generic_fd_t;
typedef struct { int fd; double recurring; } countdown_t;

#define DIRSEP '/'

#ifndef _WIN32

	#include <sys/un.h>
	#include <sys/epoll.h>
	#include <sys/timerfd.h>

	static int f_loop_new(lua_State* L) {
		lua_newtable(L);
		int epollfd = epoll_create1(0);
		lua_pushinteger(L, epollfd); lua_setfield(L, -2, "epollfd");
		lua_newtable(L); lua_setfield(L, -2, "fds");
		lua_newtable(L); lua_setfield(L, -2, "deferred");
		luaL_setmetatable(L, "wtk.c.loop");
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
				countdown_t* countdown = luaL_testudata(L, -1, "wtk.c.countdown");
				if (countdown) {
					long long length;
					length = read(countdown->fd, &length, sizeof(length));
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
	
	static int f_countdown_new(lua_State* L) {
		double offset = luaL_checknumber(L, 1);
		double recurring = luaL_optnumber(L, 2, 0);
		countdown_t* countdown = lua_newuserdata(L, sizeof(countdown_t));
		luaL_setmetatable(L, "wtk.c.countdown");
		countdown->fd = timerfd_create(CLOCK_MONOTONIC, 0);
		countdown->recurring = recurring;
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
		countdown_t* countdown = luaL_checkudata(L, 1, "wtk.c.countdown");
		if (countdown->fd)
			close(countdown->fd);
		return 0;
	}

	static const luaL_Reg countdown_lib[] = {
		{ "new",      f_countdown_new   },
		{ "__gc",		 f_countdown_gc },
		{ NULL,       NULL }
	};

#endif

static int f_system_ls(lua_State* L) {
	DIR* dir = opendir(luaL_checkstring(L, 1));
	if (!dir) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	struct dirent* entry;
	int i = 1;
	lua_newtable(L);
	while ((entry = readdir(dir)) != NULL) {
		if (strcmp(entry->d_name, "..") == 0 || strcmp(entry->d_name, ".") == 0 )
			continue;
		lua_newtable(L);
		lua_pushstring(L, entry->d_name);
		lua_setfield(L, -2, "name");
		lua_pushstring(L, entry->d_type == DT_DIR ? "dir" : (entry->d_type == DT_REG ? "file" : "other"));
		lua_setfield(L, -2, "type");
		lua_rawseti(L, -2, i++);
	}
	closedir(dir);
	return 1;
}

static int f_system_mkdir(lua_State* L) {
	if (mkdir(luaL_checkstring(L, 1), S_IRWXU | S_IRWXG | S_IROTH | S_IXOTH)) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	lua_pushboolean(L, 1);
	return 1;
}

static int f_system_stat(lua_State* L) {
	struct stat file;
	if (stat(luaL_checkstring(L, 1), &file)) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	lua_newtable(L);
	lua_pushnumber(L, file.st_mtime), lua_setfield(L, -2, "mtime");
	lua_pushinteger(L, file.st_size), lua_setfield(L, -2, "size");
	lua_pushstring(L, S_ISREG(file.st_mode) ? "file" : (S_ISDIR(file.st_mode) ? "dir" : "other")), lua_setfield(L, -2, "type");
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
	{ "ls",       f_system_ls      },
	{ "mkdir",    f_system_mkdir   },
  { "stat",     f_system_stat    },
  { "time",     f_system_time    },
  { "isatty",	 f_system_isatty  },
  { NULL,       NULL }
};

int luaW_loadblock(lua_State* L, const char* name, int line, const char* str) {
	char namebuffer[PATH_MAX];
	snprintf(namebuffer, sizeof(namebuffer), "=%s", strrchr(name, DIRSEP) ? strrchr(name, DIRSEP) + 1 : name);
	size_t len = strlen(str);
	char* strbuffer = malloc(line + len);
	for (int i = 0; i < line - 1; ++i)
		strbuffer[i] = '\n';
	memcpy(&strbuffer[line - 1], str, len);
	int res = luaL_loadbuffer(L, strbuffer, line + len - 1, namebuffer);
	free(strbuffer);
	return res;
}

#define luaW_newclass(L, name) lua_pushliteral(L, #name), luaL_newmetatable(L, "wtk.c." #name), luaL_setfuncs(L, name##_lib, 0), lua_pushvalue(L, -1), lua_setfield(L, -2, "__index"), lua_rawset(L, -3)

int luaopen_wtk_c(lua_State* L) {
	lua_newtable(L);
  luaW_newclass(L, system);
  #ifndef _WIN32
		luaW_newclass(L, countdown);
		luaW_newclass(L, loop);
	#endif
  if (luaW_loadblock(L, __FILE__, __LINE__, "local wtk = ...\n\
  wtk.Loop = wtk.loop\n\
  wtk.Promise = {}\n\
  setmetatable({}, wtk.Promise)\n\
  wtk.Promise.__index = wtk.Promise\n\
	function wtk.Promise.new(hash) local self = setmetatable({ resolved = nil, rejected = nil, doneh = {}, failh = {} }, wtk.Promise) for k,v in pairs(hash or {}) do self[k] = v end return self end\n\
  function wtk.Promise:on(done, fail) if self.resolved and done then done(table.unpack(self.resolved)) end if self.rejected and fail then fail(table.unpack(self.rejected)) end table.insert(self.doneh, done) table.insert(self.failh, fail) return self end\n\
  function wtk.Promise:done(func) return self:on(func) end\n\
  function wtk.Promise:fail(func) return self:on(nil, func) end\n\
  function wtk.Promise:always(func) return self:on(func, func) end\n\
  function wtk.Promise:resolve(...) self.resolved = { ... } for k,v in ipairs(self.doneh) do v(table.unpack(self.resolved)) end return self end\n\
  function wtk.Promise:reject(...) self.rejected = { ... } for k,v in ipairs(self.failh) do v(table.unpack(self.rejected)) end return self end\n\
  wtk.error = {\n\
		__tostring = function(self) return tostring(self.error) end,\n\
		new = function(err, level)\n\
			if type(err) == 'table' and getmetatable(err) == wtk.error then return err end\n\
			return setmetatable({ error = err, stack = debug.traceback(nil, level or 2) }, wtk.error)\n\
		end\n\
	}\n\
  wtk.try = function(func, catch, always, ...)\n\
		local caught_error, catch_error, always_error, status\n\
		local results = { xpcall(func, function(err)\n\
			caught_error = err\n\
			if type(caught_error) ~= 'table' or getmetatable(caught_error) ~= wtk.error then\n\
				caught_error = wtk.error.new(err, 3)\n\
			end\n\
			if catch then\n\
				xpcall(catch, function(err) \n\
					catch_error = wtk.error.new(err, 3)\n\
				end, caught_error)\n\
			else\n\
				catch_error = caught_error\n\
			end\n\
		end, ...) }\n\
		if always then\n\
			xpcall(always, function(err)\n\
				always_error = wtk.error.new(err, 3)\n\
			end, caught_error)\n\
		end\n\
		if always_error or catch_error then\n\
			error(always_error or catch_error, 0)\n\
		end\n\
		return table.unpack(results)\n\
  end\n\
  try = wtk.try\n\
  package.loaded['wtk'] = wtk\n\
  package.loaded['wtk.c.loop'] = wtk.loop\n\
  package.loaded['wtk.c.system'] = wtk.system\n\
  wtk.system.mtime = function(path) local s, err = wtk.system.stat(path) if not s then return nil, err end return s.mtime end\n\
	function wtk.pargs(arguments, options, short_options)\n\
		local args = {}\n\
		local i = 1\n\
		for k,v in pairs(arguments) do if math.type(k) ~= 'integer' then args[k] = v end end\n\
		while i <= #arguments do\n\
			local s,e, option, value = arguments[i]:find('^%-%-([^=]+)=?(.*)')\n\
			local option_name = s and (options[option] and option or option:gsub('^no%-', ''))\n\
			if not s and short_options then\n\
				s,e, option = arguments[i]:find('^%-(%w)')\n\
				if s and short_options[option] and options[short_options[option]] then\n\
					option_name = short_options[option]\n\
					option = option_name\n\
				end\n\
			end\n\
			if options[option_name] then\n\
				local flag_type = options[option_name]\n\
				if flag_type == 'flag' then\n\
					args[option_name] = (option_name == option or not option:find('^no-')) and true or false\n\
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
				s,e,flags = arguments[i]:find('^%-(%w+)')\n\
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
	end"))
    return lua_error(L);
  lua_pushvalue(L, -2);
  lua_call(L, 1, 0);
  return 1;
}

#ifdef WTK_MAKE_PACKER
	// used to pack files into a single C file
	// usage: [ ! -f packer ] && $CC ../../src/wtk.c -DMAKE_PACKER -o packer -lm && ./packer *.lua > packed.c
	int main(int argc, char* argv[]) {
		lua_State* L = luaL_newstate();
		luaL_openlibs(L);
		if (luaW_loadblock(L, __FILE__, __LINE__, "\n\
			print('#define WTK_PACKED\\nconst char* luaW_packed[] = {') \n\
			for i,file in ipairs({ ... }) do \n\
				local package, cont = file:gsub('/', '.'):gsub('.*wtk', 'wtk'):gsub('%.lua$', '')\n\
				local type = file:find('%.lua$') and 'lua' or 'file'\n\
				io.stderr:write('Packing ' .. file .. ' (' .. package .. ')...\\n')\n\
				cont = io.open(file, 'rb'):read('*all')\n\
				if type == 'lua' then cont = string.dump(assert(load(cont, '='..package))) end\n\
				cont = cont:gsub('.',function(c) return string.format('\\\\x%02X',string.byte(c)) end) \n\
				print('\t\\\"'..file:gsub('/', '.'):gsub('.*wtk', 'wtk'):gsub('%.lua$', '') ..'\\\",\\\"'..type..'\\\",\\\"'..cont..'\\\",(void*)'..math.floor(#cont/3)..',')\n\
			end\n\
			print(\"(void*)0, (void*)0, (void*)0\\n};\")")
		) {
			fprintf(stderr, "Error loading packer: %s\n", lua_tostring(L, -1));
			return -1;
		}
		for (int i = 1; i < argc; ++i)
			lua_pushstring(L, argv[i]);
		if (lua_pcall(L, argc - 1, 0, 0)) {
			fprintf(stderr, "Error running packer: %s\n", lua_tostring(L, -1));
			return -1;
		}
		return 0;
	}
	int luaW_packlua(lua_State* L, const char* directory) { return 0; }
	#define main main_
#else
	#include <packed.lua.c>
	int luaW_packlua(lua_State* L, const char* directory) {
		#ifndef WTK_UNPACKED
			lua_newtable(L);
			lua_pushvalue(L, -1);
			lua_setglobal(L, "packed");
			lua_getfield(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
			for (int i = 0; luaW_packed[i]; i += 4) {
				lua_pushstring(L, (strncmp(luaW_packed[i], directory, strlen(directory)) == 0) ? &luaW_packed[i][strlen(directory)+1] : luaW_packed[i]);
				if (strcmp(luaW_packed[i+1], "lua") == 0)  {
					if (luaL_loadbuffer(L, luaW_packed[i+2], (size_t)luaW_packed[i+3], luaW_packed[i])) {
						lua_pushfstring(L, "error loading %s: %s", luaW_packed[i], lua_tostring(L, -1));
						return -1;
					}
					lua_rawset(L, -3);
				} else {
					lua_pushlstring(L, luaW_packed[i+2], (size_t)luaW_packed[i+3]);
					lua_rawset(L, -4);
				}
			}
			lua_pop(L, 2);
		#else
			#pragma message "Using unpacked lua modules."
			lua_getglobal(L, "package");
			lua_pushstring(L, "./?.lua;./?/init.lua;");
			if (directory && strcmp("directory", ".") != 0)
				lua_pushfstring(L, "%s/?.lua;%s/?/init.lua;", directory, directory);
			lua_getfield(L, directory && strcmp("directory", ".") != 0 ? -3 : -2, "path");
			lua_concat(L, directory && strcmp("directory", ".") != 0 ? 3 : 2);
			lua_setfield(L, -2, "path");
			lua_pop(L, 1);
		#endif
		return 0;
	}
#endif


#define luaW_loadentry(L, init) luaW_loadblock(L, "luaW_loadentry", 1, "(package.preload." init " or assert(loadfile(assert(package.searchpath(\"" init "\", package.path)))))(...)")

int luaW_run(lua_State* L, int argc, char* argv[]) {
  for (int i = 1; i < argc; ++i) 
    lua_pushstring(L, argv[i]);
  return lua_pcall(L, argc - 1, LUA_MULTRET, 0);
}

#define MAX_LUAWLS 1024
static lua_State* luaWLs[MAX_LUAWLS] = {0};

static void luaW_exitsignal(int sig) {
	for (int i = 0; i < MAX_LUAWLS; ++i) {
		if (luaWLs[i]) {
			lua_State* L = luaWLs[i];
			luaWLs[i] = NULL;
			lua_close(L);
		}
  }
  exit(0);
}

static int luaW_signalgc(lua_State* L){
	for (int i = 0; i < MAX_LUAWLS; ++i) {
		if (luaWLs[i] == L)
			luaWLs[i] = NULL;
  }
  return 0;
}

int luaW_signal(lua_State* L) {
	int i = 0;
  for (i = 0; i < MAX_LUAWLS && luaWLs[i]; ++i);
  if (i == MAX_LUAWLS) {
		lua_pushstring(L, "error signaling lua: too many luas");
		return -1;
	}
	luaWLs[i] = L;
  signal(SIGINT, luaW_exitsignal);
  signal(SIGTERM, luaW_exitsignal);
  signal(SIGPIPE, SIG_IGN);
  lua_newtable(L);
  lua_newtable(L);
  lua_pushcfunction(L, luaW_signalgc);
  lua_setfield(L, -2, "__gc");
  lua_setmetatable(L, -2);
  luaL_ref(L, LUA_REGISTRYINDEX);
  return 0;
}

#define luaW_requiref(L, module, func) int func(lua_State* L); luaL_requiref(L, module, func, 0), lua_pop(L, 1);
