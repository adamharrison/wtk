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

static int imin(int a, int b) { return a < b ? a : b; }

static int f_stream_new(lua_State* L, int fd) {
    lua_newtable(L);
    lua_pushinteger(L, fd);
    lua_setfield(L, -2, "fd");
    luaL_setmetatable(L, "wtk.proc.c.stream");
    return 1;
}

static int f_stream_write(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    size_t len;
    lua_getfield(L, 1, "fd");
    int fd = luaL_checkinteger(L, -1);
    const char* chunk = luaL_checklstring(L, 2, &len);
    int blocking = lua_toboolean(L, 3);
    if (blocking)
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) & ~O_NONBLOCK);
    int written = write(fd, chunk, len);
    if (written == 0)
        return 0;
    if (written == -1 && (errno == EAGAIN || errno == EWOULDBLOCK))
        written = 0;
    if (blocking)
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    if (written < 0) 
        return luaL_error(L, "error writing to stream: %s", strerror(errno));
    lua_pushinteger(L, written);
    return 1;
}

static int f_stream_read(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    int bytes = luaL_checkinteger(L, 2);
    int blocking = lua_toboolean(L, 3);
    lua_getfield(L, 1, "fd");
    int fd = luaL_checkinteger(L, -1);
    lua_pop(L, 1);
    char buffer[16*1024]={0};
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    int total_read = 0;
    if (blocking)
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) & ~O_NONBLOCK);
    while (total_read < bytes) {
        int to_read = imin(bytes - total_read, sizeof(buffer));
        int result = to_read > 0 ? read(fd, buffer, to_read) : 0;
        if (result == 0 && total_read == 0)
            return 0;
        if (result == -1 && (errno == EWOULDBLOCK || errno == EAGAIN))
            result = 0;
        if (result < 0) {
            if (blocking)
                fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
            return luaL_error(L, "error reading from stream: %s", strerror(errno));
        } else if (result > 0) {
            luaL_addlstring(&b, buffer, result);
            total_read += result;
        } else
            break;
    }
    if (blocking)
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    luaL_pushresult(&b);
    return 1;
}

static int f_stream_close(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_getfield(L, 1, "fd");
    close(luaL_checkinteger(L, -1));
    lua_pushnil(L);
    lua_setfield(L, 1, "fd");
    return 0;
}

static int f_stream_gc(lua_State* L) {
    return f_stream_close(L);
}


// Argument 1 is a table, or a string.
// Argumetn 2 is a table with options.
static int f_proc_new(lua_State* L) {
    int stdout_pipe[2];
    int stderr_pipe[2];
    int stdin_pipe[2];
    pipe(stdout_pipe);
    pipe(stderr_pipe);
    pipe(stdin_pipe);
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
        execvp(argv[0], argv);
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
    f_stream_new(L, stdout_pipe[0]);
    lua_pushvalue(L, -2);
    lua_setfield(L, -2, "proc");
    lua_setfield(L, -2, "stdout");
    f_stream_new(L, stderr_pipe[0]);
    lua_pushvalue(L, -2);
    lua_setfield(L, -2, "proc");
    lua_setfield(L, -2, "stderr");
    f_stream_new(L, stdin_pipe[1]);
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
    return 0;
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

static const luaL_Reg f_stream_api[] = {
    { "__gc",      f_stream_gc    },
    { "__read",    f_stream_read  },
    { "__write",   f_stream_write },
    { "close",     f_stream_close },
    { NULL,        NULL            }
};

static const luaL_Reg f_proc_api[] = {
    { "__gc",      f_proc_gc       },
    { "__new",     f_proc_new      },
    { "status",    f_proc_status   },
    { "kill",      f_proc_kill     },
    { NULL,        NULL            }
};

int luaopen_wtk_proc(lua_State* L) {
    luaL_newmetatable(L, "wtk.proc.c");
    luaL_setfuncs(L, f_proc_api, 0);
    luaL_newmetatable(L, "wtk.proc.c.stream");
    luaL_setfuncs(L, f_stream_api, 0);
    const char* lua_stream_code = "\n\
    local proc, stream = ...\n\
    proc.__index = proc\n\
    proc.__stream = stream\n\
    stream.__index = stream\n\
    function proc:join()\n\
        while true do\n\
            local status = self:status(not coroutine.isyieldable())\n\
            if status then return status end\n\
            coroutine.yield({ fd = self.stderr.fd })\n\
        end\n\
    end\n\
    function proc.new(prog, options)\n\
        return proc.__new(type(prog) == 'string' and { os.getenv('SHELL') or 'sh', '-c', prog } or prog, options)\n\
    end\n\
    setmetatable(proc, { __call = proc.new })\n\
    function stream:write(chunk)\n\
        local yieldable = coroutine.isyieldable()\n\
        while #chunk > 0 do\n\
            local total_written = self:__write(chunk, not yieldable)\n\
            if total_written > 0 then\n\
                chunk = chunk:sub(total_written + 1)\n\
            elseif yieldable then\n\
                coroutine.yield({ fd = stream.fd, type = 'write' })\n\
            end\n\
        end\n\
    end\n\
    function stream:read(target)\n\
        if not self.buffer then self.buffer = '' end\n\
        local yieldable = coroutine.isyieldable()\n\
        if type(target) == 'number' then \n\
            local bytes = self.buffer\n\
            if target > #self.buffer then self.buffer = self.buffer .. (self:__read(target - #self.buffer) or '') end\n\
            self.buffer = bytes:sub(target)\n\
            return bytes:sub(1, target)\n\
        else\n\
            assert(type(target) == 'string', 'unknown read target')\n\
            if target:find('^%*?[aA]') then \n\
                target = 'a'\n\
            elseif target:find('^%*?[lL]') then\n\
                target = 'l'\n\
            else\n\
                error('unknown read target', 1)\n\
            end\n\
            local chunks = { self.buffer }\n\
            self.buffer = ''\n\
            while true do\n\
                local chunk = self:__read(16*1024, not yieldable)\n\
                if not chunk then break end\n\
                if #chunk > 0 then\n\
                    local s,e = target == 'l' and chunk:find('\\n')\n\
                    if s then\n\
                        table.insert(chunks, chunk:sub(1, s - 1))\n\
                        self.buffer = chunk:sub(e + 1)\n\
                    else\n\
                        table.insert(chunks, chunk)\n\
                    end\n\
                elseif coroutine.isyieldable() then\n\
                    coroutine.yield({ fd = self.fd })\n\
                end\n\
            end\n\
            return table.concat(chunks)\n\
        end\n\
    end\n\
    return proc";
    if (luaL_loadstring(L, lua_stream_code))
        return lua_error(L);
    lua_pushvalue(L, -3);
    lua_pushvalue(L, -3);
    lua_call(L, 2, 1);
    return 1;
}
