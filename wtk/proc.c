#include <stdio.h>
#include <unistd.h>
#include <signal.h>
#include <math.h>
#include <fcntl.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <pwd.h>

int f_stream_new(lua_State* L, int readfd, int writefd);
int execvpe(const char *file, char *const argv[], char *const envp[]);


// Argument 1 is a table, or a string.
// Argumetn 2 is a table with options.
static int f_proc_new(lua_State* L) {
    int stdout_pipe[2];
    int stderr_pipe[2];
    int stdin_pipe[2];
    if (pipe(stdout_pipe) || pipe(stderr_pipe) || pipe(stdin_pipe))
        return luaL_error(L, "error creating pipes");
    luaL_checktype(L, 1, LUA_TFUNCTION);        
    int pid = fork();
    if (pid < 0) {   
        for (int i = 0; i < 2; ++i) {
            close(stdout_pipe[i]);
            close(stderr_pipe[i]);
            close(stdin_pipe[i]);
        }
        return luaL_error(L, "error forking process: %s", strerror(errno));
    } else if (!pid) {
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);
        close(stdin_pipe[1]);
        dup2(stdin_pipe[0], 0);
        dup2(stdout_pipe[1], 1);
        dup2(stderr_pipe[1], 2);
        if (lua_pcall(L, 0, 0, 0)) {
            fprintf(stderr, "%s", lua_tostring(L, -1));
            fflush(stderr);
            exit(-1);
        }
        exit(0);
    }
    close(stdout_pipe[1]);
    close(stderr_pipe[1]);
    close(stdin_pipe[0]);
    fcntl(stdout_pipe[0], F_SETFL, fcntl(stdout_pipe[0], F_GETFL, 0) | O_NONBLOCK);
    fcntl(stderr_pipe[0], F_SETFL, fcntl(stderr_pipe[0], F_GETFL, 0) | O_NONBLOCK);
    fcntl(stdin_pipe[1], F_SETFL, fcntl(stdin_pipe[1], F_GETFL, 0) | O_NONBLOCK);
    lua_newtable(L);
    lua_pushinteger(L, pid);
    lua_setfield(L, -2, "pid");
    f_stream_new(L, stdout_pipe[0], -1);
    lua_pushvalue(L, -2);
    lua_setfield(L, -2, "proc");
    lua_setfield(L, -2, "stdout");
    f_stream_new(L, stderr_pipe[0], -1);
    lua_pushvalue(L, -2);
    lua_setfield(L, -2, "proc");
    lua_setfield(L, -2, "stderr");
    f_stream_new(L, -1, stdin_pipe[1]);
    lua_pushvalue(L, -2);
    lua_setfield(L, -2, "proc");
    lua_setfield(L, -2, "stdin");
    luaL_setmetatable(L, "wtk.proc.c");
    return 1;
}

static int f_proc_chdir(lua_State* L) {
	if (chdir(luaL_checkstring(L, 1))) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	lua_pushboolean(L, 1);
	return 1;
}

static int f_proc_setuid(lua_State* L) {
    int uid = -1;
    if (lua_type(L, 1) == LUA_TSTRING)  {
        struct passwd* pass = getpwnam(lua_tostring(L, -1));
        if (pass)
            uid = pass->pw_uid;
    } else 
        uid = lua_tointeger(L, -1);
    if (uid == -1 || setuid(lua_tointeger(L, -1))) {
        lua_pushnil(L);
        lua_pushfstring(L, "error setuid process: %s", strerror(errno));
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int f_proc_exec(lua_State* L) {
    const char* argv[256] = {0};
    const char* envp[256] = {0};
    if (lua_type(L, 1) == LUA_TTABLE) {
        size_t len = lua_rawlen(L, 1);
        for (int i = 1; i <= len && i < 256; ++i) {
            lua_rawgeti(L, 1, i);
            argv[i - 1] = lua_tostring(L, -1);
            lua_pop(L, 1);
        }
    }
    if (!lua_isnil(L, 2)) {
        size_t len = lua_rawlen(L, 2);
        for (int i = 1; i <= len && i < 256; ++i) {
            lua_rawgeti(L, 2, i);
            envp[i - 1] = lua_tostring(L, -1);
            lua_pop(L, 1);
        }
    }
    execvpe(argv[0], (char* const*)argv, (char* const*)envp);
    lua_pushnil(L);
    lua_pushfstring(L, "error opening process at %s: %s", argv[0], strerror(errno));
    return 2;
}

static int f_proc_gc(lua_State* L) {
    lua_getfield(L, 1, "pid");
    int pid = luaL_checkinteger(L, -1);
    int status;
    if (waitpid(pid, &status, WNOHANG) <= 0 || !WIFEXITED(status))
        kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
    return 0;
}

static int f_proc_kill(lua_State* L) {
    int sig = luaL_optinteger(L, 2, SIGTERM);
    lua_getfield(L, 1, "pid");
    int pid = luaL_checkinteger(L, -1);
    if (kill(pid, sig)) {
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }
    lua_pop(L, 1);
    return 1;
}

static int f_proc_status(lua_State* L) {
    int wait = lua_toboolean(L, 2);
    lua_getfield(L, 1, "pid");
    int pid = luaL_checkinteger(L, -1);
    int status;
    if (waitpid(pid, &status, wait ? 0 : WNOHANG) == 0)
        return 0;
    lua_pushinteger(L, WEXITSTATUS(status));
    return 1;
}


static const luaL_Reg f_proc_api[] = {
    { "__gc",      f_proc_gc       },
    { "__new",     f_proc_new      },
    { "setuid",    f_proc_setuid   },
    { "chdir",     f_proc_chdir    },
    { "exec",      f_proc_exec     },
    { "status",    f_proc_status   },
    { "kill",      f_proc_kill     },
    { NULL,        NULL            }
};

int luaopen_wtk_proc_c(lua_State* L) {
    luaL_newmetatable(L, "wtk.proc.c");
    luaL_setfuncs(L, f_proc_api, 0);
    if (luaW_loadblock(L, __FILE__, __LINE__, "\n\
    local proc, stream = ...\n\
    local wtk = require 'wtk'\n\
    proc.__index = proc\n\
    proc.__stream = stream\n\
    local _kill = proc.kill\n\
    function proc:kill(sig) return _kill(self, sig) end\n\
    function proc:term(timeout)\n\
        if not self:status() then self:kill(SIGTERM) end\n\
        if not self:status() then coroutine.yield(timeout) end\n\
        if not self:status() then self:kill(SIGKILL) end\n\
        return self:join()\n\
    end\n\
    function proc:join(timeout)\n\
        local start = wtk.system.time()\n\
        while not timeout or (wtk.system.time() - start < timeout) do\n\
            local status = self:status(not coroutine.isyieldable())\n\
            if status then return status end\n\
            self.stderr:yield(timeout and (timeout - (wtk.system.time() - start)))\n\
        end\n\
        return self:status(not coroutine.isyieldable())\n\
    end\n\
    function proc.new(prog, options)\n\
        if options and options.env then local t = {} for k,v in pairs(options.env) do table.insert(t, k .. '=' .. v) end options.env = t end\n\
        local p = proc.__new(function()\n\
            if options and options.wd ~= nil then assert(proc.chdir(options.wd)) end\n\
            if options and options.uid ~= nil then assert(proc.setuid(options.uid)) end\n\
            if type(prog) == 'function' then\n\
                prog()\n\
            else\n\
                assert(proc.exec(type(prog) == 'string' and { os.getenv('SHELL') or 'sh', '-c', prog } or prog, options and options.env or {}))\n\
            end\n\
        end)\n\
        if options and options.stdin == false then p.stdin:close() end\n\
        if options and options.stdin ~= nil then p.stdin:print(options.stdin) p.stdin:close() end\n\
        if options and options.stderr == false then p.stderr:close() end\n\
        if options and options.stdout == false then p.stdout:close() end\n\
        return p\n\
    end\n\
    function proc.run(prog, options)\n\
        local p = proc.new(prog, options)\n\
        if p:join() ~= 0 then return nil, p.stderr:read('*all') end\n\
        return p.stdout:read('*all')\n\
    end\n\
    setmetatable(proc, { __call = proc.new })\n\
    return proc"))
        return lua_error(L);
    lua_pushvalue(L, -2);
    lua_call(L, 1, 1);
    return 1;
}
