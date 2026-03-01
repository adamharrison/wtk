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

int f_stream_new(lua_State* L, int readfd, int writefd);


// Argument 1 is a table, or a string.
// Argumetn 2 is a table with options.
static int f_proc_new(lua_State* L) {
    int stdout_pipe[2];
    int stderr_pipe[2];
    int stdin_pipe[2];
    if (pipe(stdout_pipe) || pipe(stderr_pipe) || pipe(stdin_pipe))
        return luaL_error(L, "error creating pipes");
    luaL_checktype(L, 1, LUA_TTABLE);
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
        const char* argv[256] = {0};
        size_t len = lua_rawlen(L, 1);
        for (int i = 1; i <= len && i < 256; ++i) {
            lua_rawgeti(L, 1, i);
            argv[i - 1] = lua_tostring(L, -1);
            lua_pop(L, 1);
        }
        dup2(stdin_pipe[0], 0);
        dup2(stdout_pipe[1], 1);
        dup2(stderr_pipe[1], 2);
        execvp(argv[0], (char* const*)argv);
        fprintf(stderr, "error opening process at %s: %s", argv[0], strerror(errno));
        fflush(stderr);
        exit(-1);
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


static int f_proc_gc(lua_State* L) {
    lua_getfield(L, 1, "pid");
    int pid = luaL_checkinteger(L, -1);
    kill(pid, SIGKILL);
    int status;
    waitpid(pid, &status, 0);
    return 0;
}

static int f_proc_kill(lua_State* L) {
    int sig = luaL_optinteger(L, 2, SIGTERM);
    lua_getfield(L, 1, "pid");
    int pid = luaL_checkinteger(L, -1);
    kill(pid, sig);
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
    { "status",    f_proc_status   },
    { "kill",      f_proc_kill     },
    { NULL,        NULL            }
};

#define luaW_defsignal(SIGNAL) lua_pushinteger(L, SIG##SIGNAL), lua_setfield(L, -2, #SIGNAL)
int luaopen_wtk_proc_c(lua_State* L) {
    luaL_newmetatable(L, "wtk.proc.c");
    luaL_setfuncs(L, f_proc_api, 0);
    lua_newtable(L);
    luaW_defsignal(KILL), luaW_defsignal(TERM), luaW_defsignal(INT), luaW_defsignal(ABRT), luaW_defsignal(ALRM),
        luaW_defsignal(BUS), luaW_defsignal(CHLD), luaW_defsignal(CONT), luaW_defsignal(FPE), luaW_defsignal(HUP),
        luaW_defsignal(ILL), luaW_defsignal(PIPE), luaW_defsignal(QUIT), luaW_defsignal(SEGV), luaW_defsignal(STOP),
        luaW_defsignal(TSTP), luaW_defsignal(TTIN), luaW_defsignal(TTOU), luaW_defsignal(SYS), luaW_defsignal(TRAP);
    lua_setfield(L, -2, "signals");
    if (luaW_loadblock(L, __FILE__, __LINE__, "\n\
    local proc, stream = ...\n\
    proc.__index = proc\n\
    proc.__stream = stream\n\
    local _kill = proc.kill\n\
    function proc:kill(sig) return _kill(self, type(sig) == 'string' and self.signals[sig] or sig) end\n\
    function proc:join()\n\
        while true do\n\
            local status = self:status(not coroutine.isyieldable())\n\
            if status then return status end\n\
            self.stderr:yield()\n\
        end\n\
    end\n\
    function proc.new(prog, options)\n\
        return proc.__new(type(prog) == 'string' and { os.getenv('SHELL') or 'sh', '-c', prog } or prog, options)\n\
    end\n\
    setmetatable(proc, { __call = proc.new })\n\
    return proc"))
        return lua_error(L);
    lua_pushvalue(L, -2);
    lua_call(L, 1, 1);
    return 1;
}
