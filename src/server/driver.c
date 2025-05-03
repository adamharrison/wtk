#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <math.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <arpa/inet.h>
#include <sys/epoll.h>
#include <sys/timerfd.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>


typedef struct { int fd; } generic_fd_t;
typedef struct { int fd; } socket_t;
typedef struct { int fd; double recurring; } countdown_t;

int imin(int a, int b) { return a < b ? a : b; }

#define lua_newobject(L, name) lua_newuserdata(L, sizeof(name##_t)); luaL_setmetatable(L, "wtk.server." #name);

static char base64_encode[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static int f_base64_decode(lua_State* L) {
	static int base64_decode[256] = {0};
  if (!base64_decode['B']) {
    for (int i = 0; i < 64; ++i)
      base64_decode[base64_encode[i]] = i;
  }
  size_t source_length, target_length;
  unsigned char* data = (unsigned char*)luaL_checklstring(L, 1, &source_length);
  target_length = ceil(source_length * 6.0 / 8);
  luaL_Buffer buffer;
  luaL_buffinitsize(L, &buffer, target_length);
  int accumulator;
  for (int i = 0; i < target_length && data[i] != '='; ++i) {
    switch (i % 3) {
      case 0: luaL_addchar(&buffer, (base64_decode[data[(i * 8) / 6]] << 2) | (base64_decode[data[(i * 8) / 6 + 1]] >> 4)); break;
      case 1: luaL_addchar(&buffer, ((base64_decode[data[(i * 8) / 6]] & 0xF) << 4) | (base64_decode[data[(i * 8) / 6 + 1]] >> 2)); break;
      case 2: luaL_addchar(&buffer, ((base64_decode[data[(i * 8) / 6]] & 0x3) << 6) | (base64_decode[data[(i * 8) / 6 + 1]])); break;
    }
  }
  luaL_pushresult(&buffer);
  return 1;
}

static int f_base64_encode(lua_State* L) {
  size_t source_length, target_length;
  unsigned const char* data = luaL_checklstring(L, 1, &source_length);
  target_length = ceil(source_length * 8.0 / 6);
  luaL_Buffer buffer;
  luaL_buffinitsize(L, &buffer, target_length);
  for (int i = 0; i < target_length; ++i) {
    switch (i % 4) {
      case 0: luaL_addchar(&buffer, base64_encode[data[(i * 6) / 8] >> 2]); break;
      case 1: luaL_addchar(&buffer, base64_encode[((data[(i * 6) / 8] & 0x3) << 4) | ((data[(i * 6) / 8 + 1] >> 4) & 0xF)]); break;
      case 2: luaL_addchar(&buffer, base64_encode[((data[(i * 6) / 8] & 0xF) << 2) | (data[(i * 6) / 8 + 1] >> 6)]); break;
      case 3: luaL_addchar(&buffer, base64_encode[(data[(i * 6) / 8] & 0x3F)]); break;
    }
  }
  for (int i = 0; (target_length + i) % 4 != 0; ++i)
    luaL_addchar(&buffer, '=');
  luaL_pushresult(&buffer);
  return 1;
}

static const luaL_Reg base64_lib[] = {
  { "encode",      f_base64_encode   },
  { "decode",      f_base64_decode   },
  { NULL,          NULL }
};


/****************************** MACROS ******************************/
#define SHA1_BLOCK_SIZE 20              // SHA1 outputs a 20 byte digest

/**************************** DATA TYPES ****************************/
typedef unsigned char BYTE;             // 8-bit byte
typedef unsigned int  WORD;             // 32-bit word, change to "long" for 16-bit machines

typedef struct {
	BYTE data[64];
	WORD datalen;
	unsigned long long bitlen;
	WORD state[5];
	WORD k[4];
} SHA1_CTX;

/*********************** FUNCTION DECLARATIONS **********************/
static void sha1_init(SHA1_CTX *ctx);
static void sha1_update(SHA1_CTX *ctx, const BYTE data[], size_t len);
static void sha1_final(SHA1_CTX *ctx, BYTE hash[]);
/****************************** MACROS ******************************/
#define ROTLEFT(a, b) ((a << b) | (a >> (32 - b)))

/*********************** FUNCTION DEFINITIONS ***********************/
static void sha1_transform(SHA1_CTX *ctx, const BYTE data[]) {
	WORD a, b, c, d, e, i, j, t, m[80];

	for (i = 0, j = 0; i < 16; ++i, j += 4)
		m[i] = (data[j] << 24) + (data[j + 1] << 16) + (data[j + 2] << 8) + (data[j + 3]);
	for ( ; i < 80; ++i) {
		m[i] = (m[i - 3] ^ m[i - 8] ^ m[i - 14] ^ m[i - 16]);
		m[i] = (m[i] << 1) | (m[i] >> 31);
	}

	a = ctx->state[0];
	b = ctx->state[1];
	c = ctx->state[2];
	d = ctx->state[3];
	e = ctx->state[4];

	for (i = 0; i < 20; ++i) {
		t = ROTLEFT(a, 5) + ((b & c) ^ (~b & d)) + e + ctx->k[0] + m[i];
		e = d;
		d = c;
		c = ROTLEFT(b, 30);
		b = a;
		a = t;
	}
	for ( ; i < 40; ++i) {
		t = ROTLEFT(a, 5) + (b ^ c ^ d) + e + ctx->k[1] + m[i];
		e = d;
		d = c;
		c = ROTLEFT(b, 30);
		b = a;
		a = t;
	}
	for ( ; i < 60; ++i) {
		t = ROTLEFT(a, 5) + ((b & c) ^ (b & d) ^ (c & d))  + e + ctx->k[2] + m[i];
		e = d;
		d = c;
		c = ROTLEFT(b, 30);
		b = a;
		a = t;
	}
	for ( ; i < 80; ++i) {
		t = ROTLEFT(a, 5) + (b ^ c ^ d) + e + ctx->k[3] + m[i];
		e = d;
		d = c;
		c = ROTLEFT(b, 30);
		b = a;
		a = t;
	}

	ctx->state[0] += a;
	ctx->state[1] += b;
	ctx->state[2] += c;
	ctx->state[3] += d;
	ctx->state[4] += e;
}

static void sha1_init(SHA1_CTX *ctx) {
	ctx->datalen = 0;
	ctx->bitlen = 0;
	ctx->state[0] = 0x67452301;
	ctx->state[1] = 0xEFCDAB89;
	ctx->state[2] = 0x98BADCFE;
	ctx->state[3] = 0x10325476;
	ctx->state[4] = 0xc3d2e1f0;
	ctx->k[0] = 0x5a827999;
	ctx->k[1] = 0x6ed9eba1;
	ctx->k[2] = 0x8f1bbcdc;
	ctx->k[3] = 0xca62c1d6;
}

static void sha1_update(SHA1_CTX *ctx, const BYTE data[], size_t len) {
	size_t i;

	for (i = 0; i < len; ++i) {
		ctx->data[ctx->datalen] = data[i];
		ctx->datalen++;
		if (ctx->datalen == 64) {
			sha1_transform(ctx, ctx->data);
			ctx->bitlen += 512;
			ctx->datalen = 0;
		}
	}
}

static void sha1_final(SHA1_CTX *ctx, BYTE hash[]) {
	WORD i;

	i = ctx->datalen;

	// Pad whatever data is left in the buffer.
	if (ctx->datalen < 56) {
		ctx->data[i++] = 0x80;
		while (i < 56)
			ctx->data[i++] = 0x00;
	}
	else {
		ctx->data[i++] = 0x80;
		while (i < 64)
			ctx->data[i++] = 0x00;
		sha1_transform(ctx, ctx->data);
		memset(ctx->data, 0, 56);
	}

	// Append to the padding the total message's length in bits and transform.
	ctx->bitlen += ctx->datalen * 8;
	ctx->data[63] = ctx->bitlen;
	ctx->data[62] = ctx->bitlen >> 8;
	ctx->data[61] = ctx->bitlen >> 16;
	ctx->data[60] = ctx->bitlen >> 24;
	ctx->data[59] = ctx->bitlen >> 32;
	ctx->data[58] = ctx->bitlen >> 40;
	ctx->data[57] = ctx->bitlen >> 48;
	ctx->data[56] = ctx->bitlen >> 56;
	sha1_transform(ctx, ctx->data);

	// Since this implementation uses little endian byte ordering and MD uses big endian,
	// reverse all the bytes when copying the final state to the output hash.
	for (i = 0; i < 4; ++i) {
		hash[i]      = (ctx->state[0] >> (24 - i * 8)) & 0x000000ff;
		hash[i + 4]  = (ctx->state[1] >> (24 - i * 8)) & 0x000000ff;
		hash[i + 8]  = (ctx->state[2] >> (24 - i * 8)) & 0x000000ff;
		hash[i + 12] = (ctx->state[3] >> (24 - i * 8)) & 0x000000ff;
		hash[i + 16] = (ctx->state[4] >> (24 - i * 8)) & 0x000000ff;
	}
}

static int f_sha1(lua_State* L) {
  size_t length;
  const char* data = luaL_checklstring(L, 1, &length);
  SHA1_CTX ctx;
  char buffer[SHA1_BLOCK_SIZE];
  sha1_init(&ctx);
  sha1_update(&ctx, data, length);
  sha1_final(&ctx, buffer); 
  lua_pushlstring(L, buffer, SHA1_BLOCK_SIZE);
  return 1;
}

static const luaL_Reg sha1_lib[] = {
  { "binary",   f_sha1   },
  { NULL,       NULL }
};

static int f_loop_new(lua_State* L) {
	lua_newtable(L);
	int epollfd = epoll_create1(0);
	lua_pushinteger(L, epollfd); lua_setfield(L, -2, "epollfd");
	lua_newtable(L); lua_setfield(L, -2, "fds");
	luaL_setmetatable(L, "wtk.server.loop");
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
	lua_getfield(L, 1, "epollfd");
	int fd = lua_tofd(L, 2);
	int mask = EPOLLIN | EPOLLRDHUP | EPOLLERR | EPOLLHUP;
	if (lua_isboolean(L, 4))
		mask |= EPOLLET;
	struct epoll_event event = { .events = EPOLLIN | EPOLLRDHUP | EPOLLERR | EPOLLHUP, .data = { .fd = fd } };
	epoll_ctl(luaL_checkinteger(L, -1), EPOLL_CTL_ADD, fd, &event);
	luaL_getsubtable(L, 1, "fds");
	lua_pushinteger(L, fd); 
	lua_newtable(L);
	luaL_checktype(L, 3, LUA_TFUNCTION);
	lua_pushvalue(L, 3);
	lua_rawseti(L, -2, 1);
	lua_pushvalue(L, 2);
	lua_rawseti(L, -2, 2);
	lua_rawset(L, -3);
	lua_pushvalue(L, 2);
  return 1;
}

static int f_loop_rm(lua_State* L) {
	lua_getfield(L, 1, "epollfd");
	int fd = lua_tofd(L, -1);
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
  { "rm",       f_loop_rm   },
  { "run",      f_loop_run   },
  { "__gc",     f_loop_gc   },
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

static const luaL_Reg system_lib[] = {
  { "mtime",    f_system_mtime  },
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

static int f_socket_bind(lua_State *L) {
  struct sockaddr_in bind_addr = {0};
  size_t addr_len = sizeof(bind_addr);
  socket_t* sock = lua_newobject(L, socket);
  sock->fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
  bind_addr.sin_family = AF_INET;
  bind_addr.sin_addr.s_addr = INADDR_ANY;
  bind_addr.sin_port = htons(luaL_checkinteger(L, 2));
  int optval = 1;
  setsockopt(sock->fd, SOL_SOCKET, SO_REUSEPORT, &optval, sizeof(optval));
  if (bind(sock->fd, (struct sockaddr *) &bind_addr, sizeof(bind_addr)) == -1)
    return luaL_error(L, "Unable to bind: %s", strerror(errno));
  if (listen(sock->fd, 16) == -1)
    return luaL_error(L, "Unable to listen: %s", strerror(errno));
  return 1;
}

static int f_socket_accept(lua_State* L) {
  struct sockaddr_in peer_addr = {0};
  socklen_t peer_addr_len = sizeof(peer_addr);
  socket_t* sock = luaL_checkudata(L, 1, "wtk.server.socket");
  int fd = accept(sock->fd, (struct sockaddr*)&peer_addr, &peer_addr_len);
  int flags = fcntl(fd, F_GETFL, 0);
	if (flags == -1 || fcntl(fd, F_SETFL, (flags | O_NONBLOCK)) == -1) 
		return luaL_error(L, "error setting non-blocking: %s", strerror(errno));
  socket_t* peer = lua_newuserdata(L, sizeof(socket_t));
  peer->fd = fd;
  luaL_setmetatable(L, "wtk.server.socket");
  return 1;
}

static int f_socket_peer(lua_State* L) {
  struct sockaddr_in peer_addr = {0};
  socklen_t peer_addr_len = sizeof(peer_addr);
  socket_t* sock = luaL_checkudata(L, 1, "wtk.server.socket");
  getsockname(sock->fd, (struct sockaddr*)&peer_addr, &peer_addr_len);
  char str[INET_ADDRSTRLEN+1] = {0};
  lua_pushstring(L, inet_ntoa(peer_addr.sin_addr));
  lua_pushinteger(L, ntohs(peer_addr.sin_port));
  return 2;
}

static int f_socket_close(lua_State* L) {
  socket_t* sock = luaL_checkudata(L, 1, "wtk.server.socket");
  if (sock->fd) {
    close(sock->fd);
    sock->fd = 0;
  }
  return 1;
}

static int f_socket_recv(lua_State* L) {
  socket_t* sock = luaL_checkudata(L, 1, "wtk.server.socket");
  int bytes = luaL_checkinteger(L, 2), length = 0, total_received = 0;
  luaL_Buffer buffer;
  char chunk[4096];
  luaL_buffinitsize(L, &buffer, bytes);
  while (bytes > 0) {
    length = recv(sock->fd, chunk, imin(sizeof(chunk), bytes), 0);
    if (length > 0) {
      bytes -= length;
      luaL_addlstring(&buffer, chunk, length);
      total_received += length;
    } else
				break;
  }
  luaL_pushresult(&buffer);
  if (errno == EAGAIN || errno == EWOULDBLOCK || total_received == 0)
		lua_pushliteral(L, "timeout");
	else
		lua_pushstring(L, length == -1 ? strerror(errno) : NULL);
  return 2;
}

static int f_socket_send(lua_State* L) {
  socket_t* sock = luaL_checkudata(L, 1, "wtk.server.socket");
  size_t packet_length;
  const char* packet = luaL_checklstring(L, 2, &packet_length);
  int res = send(sock->fd, packet, packet_length, 0);
  if (res == -1) {
		lua_pushnil(L);
		if (errno == EAGAIN || errno == EWOULDBLOCK)
			lua_pushliteral(L, "timeout");
		else
			lua_pushstring(L, strerror(errno));
	} else {
		lua_pushinteger(L, res);
	}
  return 2;
}

static const luaL_Reg socket_lib[] = {
  { "bind",      f_socket_bind   },
  { "accept",    f_socket_accept },
  { "peer",      f_socket_peer   },
  { "close",     f_socket_close  },
  { "send",      f_socket_send   },
  { "recv",      f_socket_recv   },
  { "__gc",      f_socket_close  },
  { NULL,        NULL }
};

#define luaL_newclass(L, name) lua_pushliteral(L, #name); luaL_newmetatable(L, "wtk.server." #name); luaL_setfuncs(L, name##_lib, 0); lua_pushvalue(L, -1); lua_setfield(L, -2, "__index"); lua_rawset(L, -3);

int luaopen_wtk_server_driver(lua_State* L) {
	lua_newtable(L);
  luaL_newclass(L, system);
  luaL_newclass(L, socket);
  luaL_newclass(L, countdown);
  luaL_newclass(L, loop);
  luaL_newclass(L, sha1);
  luaL_newclass(L, base64);
  return 1;
}

