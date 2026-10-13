#include <netinet/in.h>
#if _WIN32
  #include <direct.h>
  #include <winsock2.h>
  #include <windows.h>
  #define usleep(x) Sleep((x)/1000)
#else
  #include <pthread.h>
  #include <netdb.h>
  #include <sys/socket.h>
  #include <arpa/inet.h>
  #include <unistd.h>
  #include <fcntl.h>
#endif
#include <errno.h>
#include <stdlib.h>
#include <ctype.h>
#include <time.h>
#include <string.h>
#include <math.h>
#include <sys/stat.h>
#include <mbedtls/sha256.h>
#include <mbedtls/x509.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/ssl.h>
#include <mbedtls/error.h>
#include <mbedtls/net_sockets.h>
#ifdef MBEDTLS_DEBUG_C
  #include <mbedtls/debug.h>
#endif

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

static mbedtls_ssl_config ssl_config;
static int no_verify_ssl;

#define MAX_ERROR_SIZE 512

typedef enum socket_state_e {
  STATE_INIT,
  STATE_CONNECTING,
  STATE_HANDSHAKE,
  STATE_READY,
  STATE_CLOSED
} socket_state_e;

typedef struct client_socket_t {
  int fd;
  int is_ssl;
  int blocking;
  socket_state_e state;
  struct sockaddr_in addr;
  mbedtls_net_context net_context;
  mbedtls_ssl_context ssl_context;
} client_socket_t;

static int imin(int a, int b) { return a < b ? a : b; }

static int mbedtls_snprintf(int mbedtls, char* buffer, int len, int status, const char* str, ...) {
  char mbed_buffer[256];
  mbedtls_strerror(status, mbed_buffer, sizeof(mbed_buffer));
  int error_len = mbedtls ? strlen(mbed_buffer) : strlen(strerror(status));
  va_list va;
  int offset = 0;
  va_start(va, str);
    offset = vsnprintf(buffer, len, str, va);
  va_end(va);
  if (offset < len - 2) {
    strcat(buffer, ": ");
    if (offset < len - error_len - 2)
      strcat(buffer, mbedtls ? mbed_buffer : strerror(status));
  }
  return strlen(buffer);
}

static int socket_yield(lua_State* L, int fd, const char* type, lua_KFunction k) {
  lua_newtable(L);
  lua_pushinteger(L, fd);
  lua_setfield(L, -2, "socket");
  lua_pushstring(L, type);
  lua_setfield(L, -2, "type");
  return lua_yieldk(L, 1, 0, k);
}

static int socket_set_blocking(client_socket_t* c, int blocking) {
  if (blocking != c->blocking) {
    c->blocking = blocking;
    if (blocking) {    
      if (c->is_ssl) {
        return mbedtls_net_set_block(&c->net_context);
      } else {
        int flags = fcntl(c->fd, F_GETFL, 0);
        return fcntl(c->fd, F_SETFL, flags & ~O_NONBLOCK);
      }
    } else {
      if (c->is_ssl) {
        return mbedtls_net_set_nonblock(&c->net_context);
      } else {
        int flags = fcntl(c->fd, F_GETFL, 0);
        return fcntl(c->fd, F_SETFL, flags | O_NONBLOCK);
      }
    }
  }
  return 0;
}

static int f_client_socket_recvk(lua_State* L, int status, lua_KContext ctx) {
  lua_getfield(L, 1, "__c");
  client_socket_t* socket = lua_touserdata(L, -1);
  lua_pop(L, 1);
  if (socket->state != STATE_READY)
    return 0;
  int bytes = luaL_checkinteger(L, 2);
  int blocking = lua_toboolean(L, 3);
  char buf[16*1024];
  socket_set_blocking(socket, blocking);
  int recvd;
  if (socket->is_ssl) {
    recvd = mbedtls_ssl_read(&socket->ssl_context, (unsigned char*)buf, imin(bytes, sizeof(buf)));
    if (recvd == MBEDTLS_ERR_SSL_WANT_READ || recvd == MBEDTLS_ERR_SSL_WANT_WRITE)
      return socket_yield(L, socket->fd, recvd == MBEDTLS_ERR_SSL_WANT_WRITE ? "write" : "read", f_client_socket_recvk);
    if (recvd <= 0) {
      socket->state = STATE_CLOSED;
      lua_pushnil(L);
			if (recvd == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY || recvd == 0) 
				lua_pushliteral(L, "closed");
			else {
				mbedtls_strerror(recvd, buf, sizeof(buf));
				lua_pushstring(L, buf);
			}
      return 2;
    }
  } else {
    recvd = read(socket->fd, buf, imin(sizeof(buf), bytes));
    if (recvd == -1 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      return socket_yield(L, socket->fd, "read", f_client_socket_recvk);
    }
    if (recvd <= 0) {
      socket->state = STATE_CLOSED;
      lua_pushnil(L);
      if ((recvd == -1 && errno == ECONNRESET) || recvd == 0)
				lua_pushliteral(L, "closed");
			else
				lua_pushstring(L, strerror(errno));
      return 2;
    }
  }
  lua_pushlstring(L, buf, recvd);
  return 1;
}
static int f_client_socket_recv(lua_State* L) { return f_client_socket_recvk(L, 0, 0); }

static int f_client_socket_sendk(lua_State* L, int status, lua_KContext ctx) {
  lua_getfield(L, 1, "__c");
  client_socket_t* socket = lua_touserdata(L, -1);
  size_t len;
  if (socket->state != STATE_READY)
    return 0;
  const char* bytes = luaL_checklstring(L, 2, &len);
  int blocking = lua_toboolean(L, 3);
  socket_set_blocking(socket, blocking);
  int written;
  char buf[16*1024];
  if (socket->is_ssl) {
    written = mbedtls_ssl_write(&socket->ssl_context, bytes, len);
    if (written == MBEDTLS_ERR_SSL_WANT_WRITE || written == MBEDTLS_ERR_SSL_WANT_READ)
      return socket_yield(L, socket->fd, written == MBEDTLS_ERR_SSL_WANT_WRITE ? "write" : "read", f_client_socket_sendk);  
    if (written < 0) {
      socket->state = STATE_CLOSED;
      lua_pushnil(L);
			if (written == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY)
				lua_pushliteral(L, "closed");
			else {
				mbedtls_strerror(written, buf, sizeof(buf));
				lua_pushstring(L, buf);
			}
      return 2;
    }
  } else {
    written = write(socket->fd, bytes, len);
    if (written == -1 && (errno == EAGAIN || errno == EWOULDBLOCK))
      return socket_yield(L, socket->fd, "write", f_client_socket_sendk);
    else if (written == -1) {
			lua_pushnil(L);
			lua_pushstring(L, strerror(errno));
			return 2;
		}
  }
  lua_pushinteger(L, written);
  return 1;
}
static int f_client_socket_send(lua_State* L) { return f_client_socket_sendk(L, 0, 0); }

static int f_client_socket_openk(lua_State* L, int status, lua_KContext ctx) {
  lua_getfield(L, 1, "__c");
  client_socket_t* c = lua_touserdata(L, -1);
  const char* protocol = luaL_checkstring(L, 2);
  const char* hostname = luaL_checkstring(L, 3);
  const char* ip = luaL_checkstring(L, 4);
  int port = strcmp(protocol, "unix") != 0 ? luaL_checkinteger(L, 5) : -1;
  int blocking = lua_toboolean(L, 6);
  char err[MAX_ERROR_SIZE]={0};
  switch (c->state) {
    case STATE_INIT: {
			if (inet_aton(ip, &c->addr.sin_addr) == 0) {
				snprintf(err, sizeof(err), "improperly formatted ip %s: %s", ip, strerror(errno));
				break;
			}
      if (strcmp(protocol, "unix") == 0) 
				c->fd = socket(AF_UNIX, SOCK_STREAM, 0);
      else {
        c->addr.sin_family = AF_INET;
				c->addr.sin_port = htons(port);
				c->fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
			}
			
      if (strcmp(protocol, "https") == 0) {
        c->is_ssl = 1;
        int status;
        mbedtls_ssl_init(&c->ssl_context);
        mbedtls_net_init(&c->net_context);
        if ((status = mbedtls_ssl_setup(&c->ssl_context, &ssl_config)) != 0) {
          mbedtls_snprintf(1, err, sizeof(err), status, "can't set up ssl for %s: %d", hostname, status);
          break;
        }
        c->net_context.fd = c->fd;
        mbedtls_ssl_set_bio(&c->ssl_context, &c->net_context, mbedtls_net_send, mbedtls_net_recv, NULL);
      }
      socket_set_blocking(c, blocking);
      c->state = STATE_CONNECTING;
    }
    case STATE_CONNECTING: {
      signal(SIGPIPE, SIG_IGN);
      int ret = 0;
      if (strcmp(protocol, "unix") == 0) {
				struct sockaddr_un path = {0};
				path.sun_family = AF_UNIX;
				strncpy(path.sun_path, hostname, sizeof(path.sun_path) - 1);
				ret = connect(c->fd, (struct sockaddr *) &path, sizeof(path));
				if (ret == -1 && (errno != EAGAIN && errno != EWOULDBLOCK && errno != EALREADY && errno != EINPROGRESS)) {
					snprintf(err, sizeof(err), "can't connect to unix socket %s: %s", hostname, strerror(errno));
					break;
				}
			} else {
				ret = connect(c->fd, (struct sockaddr *) &c->addr, sizeof(c->addr));
				if (ret == -1 && (errno != EAGAIN && errno != EWOULDBLOCK && errno != EALREADY && errno != EINPROGRESS)) {
					snprintf(err, sizeof(err), "can't connect to host %s [%s] on port %d: %s", hostname, ip, port, strerror(errno));
					break;
				}
			}
			if (ret == -1)
				return socket_yield(L, c->fd, "write", f_client_socket_openk);
      if (c->is_ssl) {
				if ((status = mbedtls_ssl_set_hostname(&c->ssl_context, hostname)) != 0) {
          mbedtls_snprintf(1, err, sizeof(err), status, "can't set hostname %s", hostname);
          break;
        }
      }
      c->state = STATE_HANDSHAKE;
    } 
    case STATE_HANDSHAKE:
      if (c->is_ssl) {
        int status = mbedtls_ssl_handshake(&c->ssl_context);    
        if (status == MBEDTLS_ERR_SSL_WANT_READ)
          return socket_yield(L, c->fd, "read", f_client_socket_openk);
        if (status == MBEDTLS_ERR_SSL_WANT_WRITE)
          return socket_yield(L, c->fd, "write", f_client_socket_openk);
        if (status != 0) {
          mbedtls_snprintf(1, err, sizeof(err), status, "can't handshake with %s", hostname);
          break;
        } else if (((status = mbedtls_ssl_get_verify_result(&c->ssl_context)) != 0) && !no_verify_ssl) {
          mbedtls_snprintf(1, err, sizeof(err), status, "can't verify result for %s", hostname);
          break;
        }
      }
      c->state = STATE_READY;
    break;
  }
  if (err[0]) {
    c->state = STATE_CLOSED;
    lua_pushnil(L);
    lua_pushstring(L, err);
    return 2;
  }
  lua_pushvalue(L, 1);
  return 1;
}

static int f_client_socket_open(lua_State* L) {
  lua_newtable(L);
  client_socket_t* c = calloc(sizeof(client_socket_t), 1);
  lua_pushlightuserdata(L, c);
  lua_setfield(L, -2, "__c");
  lua_pushvalue(L, 1);
  lua_setmetatable(L, -2);
  lua_replace(L, 1);
  return f_client_socket_openk(L, 0, 0);
}

static int f_client_socket_close(lua_State* L) {
  lua_getfield(L, 1, "__c");
  if (!lua_isnil(L, -1)) {
    client_socket_t* c = lua_touserdata(L, -1);
    if (c->is_ssl) {
      mbedtls_ssl_free(&c->ssl_context);
      mbedtls_net_free(&c->net_context);
    } else {
      if (c->fd)
        close(c->fd);
      c->fd = 0;
    }
    free(c);
    lua_pop(L, 1);
  }
  lua_pushnil(L);
  lua_setfield(L, 1, "__c");
}


static void client_tls_debug(void *ctx, int level, const char *file, int line, const char *str) {
  fprintf(stderr, "%s:%04d: |%d| %s", file, line, level, str);
  fflush(stderr);
}


#if _WIN32
static LPCWSTR lua_toutf16(lua_State* L, const char* str) {
  if (str && str[0] == 0)
    return L"";
  int len = MultiByteToWideChar(CP_UTF8, 0, str, -1, NULL, 0);
  if (len > 0) {
    LPWSTR output = (LPWSTR) malloc(sizeof(WCHAR) * len);
    if (output) {
      len = MultiByteToWideChar(CP_UTF8, 0, str, -1, output, len);
      if (len > 0) {
        lua_pushlstring(L, (char*)output, len * 2);
        free(output);
        return (LPCWSTR)lua_tostring(L, -1);
      }
      free(output);
    }
  }
  luaL_error(L, "can't convert utf8 string");
  return NULL;
}

static FILE* lua_fopen(lua_State* L, const char* path, const char* mode) {
  FILE* file = _wfopen(lua_toutf16(L, path), lua_toutf16(L, mode));
  lua_pop(L, 2);
  return file;
}
#endif


static int f_client_socket_ssl(lua_State* L) {
  char err[MAX_ERROR_SIZE] = {0};
  const char* type = luaL_checkstring(L, 1);
  int status;
  static int ssl_initialized;
  static mbedtls_x509_crt x509_certificate;
  static mbedtls_entropy_context entropy_context;
  static mbedtls_ctr_drbg_context drbg_context;
  if (ssl_initialized) {
    mbedtls_ssl_config_free(&ssl_config);
    mbedtls_ctr_drbg_free(&drbg_context);
    mbedtls_entropy_free(&entropy_context);
    mbedtls_x509_crt_free(&x509_certificate);
    ssl_initialized = 0;
  }
  if (strcmp(type, "none") == 0)
    return 0;
  mbedtls_x509_crt_init(&x509_certificate);
  mbedtls_entropy_init(&entropy_context);
  mbedtls_ctr_drbg_init(&drbg_context);
  if ((status = mbedtls_ctr_drbg_seed(&drbg_context, mbedtls_entropy_func, &entropy_context, NULL, 0)) != 0) {
    mbedtls_snprintf(1, err, sizeof(err), status, "failed to setup mbedtls_x509");
    return luaL_error(L, "%s", err);
  }
  mbedtls_ssl_config_init(&ssl_config);
  status = mbedtls_ssl_config_defaults(&ssl_config, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
  mbedtls_ssl_conf_max_version(&ssl_config, MBEDTLS_SSL_MAJOR_VERSION_3, MBEDTLS_SSL_MINOR_VERSION_3);
  mbedtls_ssl_conf_min_version(&ssl_config, MBEDTLS_SSL_MAJOR_VERSION_3, MBEDTLS_SSL_MINOR_VERSION_3);
  mbedtls_ssl_conf_authmode(&ssl_config, MBEDTLS_SSL_VERIFY_REQUIRED);
  mbedtls_ssl_conf_rng(&ssl_config, mbedtls_ctr_drbg_random, &drbg_context);
  mbedtls_ssl_conf_read_timeout(&ssl_config, 5000);
  int debug_level = luaL_checkinteger(L, 3);
  #if defined(MBEDTLS_DEBUG_C)
  if (debug_level) {
    mbedtls_debug_set_threshold(debug_level);
    mbedtls_ssl_conf_dbg(&ssl_config, client_tls_debug, NULL);
  }
  #endif
  ssl_initialized = 1;
  if (strcmp(type, "noverify") == 0) {
    no_verify_ssl = 1;
    mbedtls_ssl_conf_authmode(&ssl_config, MBEDTLS_SSL_VERIFY_OPTIONAL);
  } else {
    const char* path = luaL_checkstring(L, 2);
    if (strcmp(type, "system") == 0) {
      #if _WIN32
        FILE* file = lua_fopen(L, path, "wb");
        if (!file)
          return luaL_error(L, "can't open cert store %s for writing: %s", path, strerror(errno));
        HCERTSTORE hSystemStore = CertOpenSystemStore(0, TEXT("ROOT"));
        if (!hSystemStore) {
          fclose(file);
          return luaL_error(L, "error getting system certificate store");
        }
        PCCERT_CONTEXT pCertContext = NULL;
        while (1) {
          pCertContext = CertEnumCertificatesInStore(hSystemStore, pCertContext);
          if (!pCertContext)
            break;
          BYTE keyUsage[2];
          if (pCertContext->dwCertEncodingType & X509_ASN_ENCODING && (CertGetIntendedKeyUsage(pCertContext->dwCertEncodingType, pCertContext->pCertInfo, keyUsage, sizeof(keyUsage)) && (keyUsage[0] & CERT_KEY_CERT_SIGN_KEY_USAGE))) {
            DWORD size = 0;
            CryptBinaryToString(pCertContext->pbCertEncoded, pCertContext->cbCertEncoded, CRYPT_STRING_BASE64HEADER, NULL, &size);
            char* buffer = malloc(size);
            CryptBinaryToString(pCertContext->pbCertEncoded, pCertContext->cbCertEncoded, CRYPT_STRING_BASE64HEADER, buffer, &size);
            fwrite(buffer, sizeof(char), size, file);
            free(buffer);
          }
        }
        fclose(file);
        CertCloseStore(hSystemStore, 0);
      #else
        const char* paths[] = {
          "/etc/ssl/certs/ca-certificates.crt",                // Debian/Ubuntu/Gentoo etc.
          "/etc/pki/tls/certs/ca-bundle.crt",                  // Fedora/RHEL 6
          "/etc/ssl/ca-bundle.pem",                            // OpenSUSE
          "/etc/pki/tls/cacert.pem",                           // OpenELEC
          "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", // CentOS/RHEL 7
          "/etc/ssl/cert.pem",                                 // Alpine Linux (and Mac OSX)
          "/etc/ssl/certs",                                    // SLES10/SLES11, https://golang.org/issue/12139
          "/system/etc/security/cacerts",                      // Android
          "/usr/local/share/certs",                            // FreeBSD
          "/etc/pki/tls/certs",                                // Fedora/RHEL
          "/etc/openssl/certs",                                // NetBSD
          "/var/ssl/certs",                                    // AIX
          NULL
        };
        for (int i = 0; paths[i]; ++i) {
          struct stat s;
          if (stat(paths[i], &s) == 0 && S_ISREG(s.st_mode)) {
            path = paths[i];
            break;
          }
        }
      #endif
    }
    if ((status = mbedtls_x509_crt_parse_file(&x509_certificate, path)) != 0) {
      mbedtls_snprintf(1, err, sizeof(err), status, "mbedtls_x509_crt_parse_file failed to parse CA certificate %s", path);
      return luaL_error(L, "%s", err);
    }
    mbedtls_ssl_conf_ca_chain(&ssl_config, &x509_certificate, NULL);
  }
  return 0;
}

static const luaL_Reg socket_lib[] = {
  { "open",      f_client_socket_open   },
  { "close",     f_client_socket_close  },
  { "send",      f_client_socket_send   },
  { "recv",      f_client_socket_recv   },
  { "__gc",      f_client_socket_close  },
  { "ssl",       f_client_socket_ssl    },
  { NULL,        NULL }
};


static int f_client_gc(lua_State* L) {
  lua_pushcfunction(L, f_client_socket_ssl);
  lua_pushliteral(L, "none");
  lua_call(L, 1, 0);
  return 0;
}

int luaW_loadstring(lua_State* L, const char* name, int offset, const char* str);
int luaopen_wtk_client_c(lua_State* L) {
  luaL_newlib(L, socket_lib);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_newtable(L);
  lua_pushcfunction(L, f_client_gc);
  lua_setfield(L, -2, "__gc");
  lua_setmetatable(L, -2);
  
  if (luaW_loadblock(L, __FILE__, __LINE__, "\n\
    local socket = ...\n\
    local wtk = require 'wtk'\n\
    local PATHSEP = '/'\n\
    socket.ssl('system', '/tmp' .. PATHSEP .. 'ssl.certs', 0)\n\
    function socket.componentsURI(url)\n\
			if url:find('unix://') then return 'unix', url:sub(8) end\n\
      local protocol, hostname, port, url = url:match('^(%w+)://([^/:]+):?(%d*)(.*)$')\n\
      return protocol, hostname, (not port or port == '') and (protocol == 'https' and 443 or 80) or tonumber(port), (port and port ~= '') and port or nil, (not url or url == '' and '/' or url)\n\
    end\n\
    function socket.escapeURI(param) return param:gsub(\"[^A-Za-z0-9%-_%.%!~%*'%(%)%/]\", function(e) return string.format('%%%02x', e:byte(1)) end) end\n\
    \n\
    function socket:read(bytes, blocking, exact)\n\
      if not self.retained then self.retained = '' end\n\
      if bytes == '*l' then\n\
        local s, e\n\
        while true do\n\
          s, e = self.retained:find('\\r\\n')\n\
          if s then break end\n\
          local chunk = self:recv(4096, blocking)\n\
          if not chunk then break end\n\
          self.retained = self.retained .. chunk\n\
        end\n\
        local chunk = self.retained:sub(1, s - 1)\n\
        self.retained = self.retained:sub(e + 1)\n\
        return chunk\n\
      elseif bytes == '*a' then\n\
        local t = { self.retained }\n\
        local chunk, err\n\
        while true do\n\
          chunk, err = self:recv(4096, blocking)\n\
          if not chunk then break end\n\
          table.insert(t, chunk)\n\
        end\n\
        return table.concat(t), err\n\
      else\n\
        while true do\n\
          local chunk\n\
          if exact then\n\
            local total = ''\n\
            while #total < bytes do\n\
              local chunk, err = self:read(bytes - #total, blocking)\n\
              if not chunk then return total, err end\n\
              if #chunk > 0 then total = total .. chunk end\n\
            end\n\
            return total\n\
          else\n\
            if #self.retained > 0 then\n\
              local chunk = self.retained:sub(1, bytes)\n\
              self.retained = self.retained:sub(bytes + 1)\n\
              return chunk\n\
            end\n\
            return self:recv(bytes, blocking)\n\
          end\n\
        end\n\
      end\n\
    end\n\
    \n\
    socket.write = socket.send\n\
    local response = {}\n\
    response.__index = response\n\
    response.__tostring = function(self) return self.code .. ': ' .. (self.body or '') end\n\
    function response.new(socket)\n\
      return setmetatable({ body = {}, code = nil, headers = {}, bytes_read = 0, current_chunk_size = nil, socket = socket }, response)\n\
    end\n\
    function response:read(bytes, blocking)\n\
      local chunk\n\
      if self.headers['transfer-encoding'] == 'chunked' then\n\
        if not self.current_chunk_size then\n\
          local l = self.socket:read('*l', blocking)\n\
          self.current_chunk_size = tonumber(l, 16) or 0\n\
        end\n\
        if self.current_chunk_size == 0 then \n\
          self.socket:read(2, blocking, 'exact')\n\
          return nil \n\
        end\n\
        chunk = self.socket:read(math.min(self.current_chunk_size - self.bytes_read, bytes), blocking)\n\
        self.bytes_read = self.bytes_read + #chunk\n\
        if self.current_chunk_size == self.bytes_read then\n\
          self.socket:read(2, blocking, 'exact')\n\
          self.current_chunk_size = nil\n\
          self.bytes_read = 0\n\
        end\n\
      else\n\
        local remaining = (self.headers['content-length'] or math.huge) - self.bytes_read\n\
        if remaining <= 0 then return nil end\n\
        chunk = self.socket:read(math.min(remaining, bytes), blocking)\n\
        self.bytes_read = self.bytes_read + #chunk\n\
      end\n\
      return chunk\n\
    end\n\
    \n\
    \n\
    function socket:request(options)\n\
      local protocol, hostname, implied_port, explicit_port, remainder = socket.componentsURI(options.url)\n\
      local lines = {}\n\
      local bytes_written, err\n\
      table.insert(lines, string.format(\"%s %s HTTP/1.1\", options.method, ((options.path and socket.escapeURI(options.path)) or remainder or '/')))\n\
      for k, v in pairs(options.headers) do table.insert(lines, k .. ':' .. v) end\n\
      table.insert(lines, '')\n\
      table.insert(lines, '')\n\
      lines = table.concat(lines, '\\r\\n')\n\
      if options.log then options.log(lines, 'write') end\n\
      bytes_written, err = self:write(lines)\n\
      if not bytes_written then return nil, err end\n\
      if type(options.body) == 'function' then \n\
        for chunk in options.body do \n\
					if options.log then options.log(lines, 'write') end\n\
					bytes_written, err = self:write(chunk) \n\
					if not bytes_written then return nil, err end\n\
				end \n\
      elseif options.body then\n\
				if options.log then options.log(options.body, 'write') end\n\
        bytes_written, err = self:write(options.body)\n\
        if not bytes_written then return nil, err end\n\
      end\n\
      local res = response.new(self)\n\
      self.retained = ''\n\
      while true do\n\
        local header_end, e = self.retained:find('\\r\\n\\r\\n')\n\
        if header_end then \n\
          _, e, res.version, res.code, res.status = self.retained:find('^HTTP/(%S+)%s+(%d+)%s+(.-)\\r\\n')\n\
          assert(res.version, \"invalid header: \" .. self.retained)\n\
          res.code = tonumber(res.code)\n\
          assert(res.code, \"invalid code\")\n\
          e = e + 1\n\
          while e < header_end do\n\
            local ns, ne, key, value = self.retained:find('^(%S+):%s*(.-)\\r\\n', e)\n\
            res.headers[key:lower()] = assert(value, 'error parsing headers')\n\
            e = ne + 1\n\
          end\n\
          self.retained = self.retained:sub(header_end + 4)\n\
          break\n\
        end\n\
        local chunk, err = self:recv(4096, not coroutine.isyieldable())\n\
        if not chunk then return nil, err end\n\
				if options.log then options.log(chunk, 'read') end\n\
        self.retained = self.retained .. chunk\n\
      end\n\
      return res\n\
    end\n\
    -- we add in a resolver, because gethostbyname prevents static linking, and also isn't non-blocking\n\
    socket.resolver = { __index = function(s, k) return socket.resolver[k] or socket[k] end }\n\
    function socket.resolver.new(target, blocking)\n\
			if not target then\n\
				local f = wtk.io.file('/etc/resolv.conf', 'rb')\n\
				target = f and f:read('*all'):match('^%s*nameserver%s+(%S+)') or '127.0.0.53'\n\
				if f then f:close() end\n\
			end\n\
			return setmetatable(assert(socket:open('raw', target, target, 53, blocking)), socket.resolver)\n\
    end\n\
    local function convert_to_network_order(short)\n\
      return (short >> 8) | (short & 0xFF) << 8\n\
    end\n\
    function socket.resolver:resolve(hostname, blocking)\n\
			if hostname:match('^%d+%.%d+%.%d+%.%d+$') then return hostname end\n\
			if not self.cache then self.cache = {} end\n\
			local now = os.time()\n\
			local remove = {}\n\
			for k,v in pairs(self.cache) do if v.ttl < now then table.insert(remove, k) end end\n\
			for i,v in ipairs(remove) do self.cache[v] = nil end\n\
			if self.cache[hostname] then return table.unpack(self.cache[hostname]) end\n\
			local transaction_id = 0\n\
			local qr, opcode, aa, tc, rd, ra, z, rcode = 0, 0, 0, 0, 1, 0, 0, 0\n\
			local nq, na, naurr, ndarr = 1, 0, 0, 0\n\
			local header = string.pack('HHHHHH', \n\
				convert_to_network_order(transaction_id),\n\
				convert_to_network_order(((qr << 15) | (opcode << 11) | (aa << 10) | (tc << 9) | (rd << 8) | (ra << 7) | (z << 6) | rcode)),\n\
				convert_to_network_order(nq), convert_to_network_order(na), convert_to_network_order(naurr), convert_to_network_order(ndarr)\n\
			)\n\
			local question = ''\n\
			for part in hostname:gmatch('([^%.]+)') do\n\
        question = question .. string.pack('B', #part) .. part \n\
			end\n\
			question = question .. string.pack('B', 0) .. string.pack('HH', convert_to_network_order(1), convert_to_network_order(1))\n\
			local packet = header .. question\n\
			assert(self:send(string.pack('H', convert_to_network_order(#packet)) .. packet))\n\
			local bytes = assert(self:read(2, blocking))\n\
			local message_length = convert_to_network_order(string.unpack('H', bytes))\n\
			local response = self:read(message_length, blocking, true)\n\
			local flags\n\
			transaction_id, flags, nq, na, naurr, ndarr = string.unpack('HHHHHH', response)\n\
			flags = convert_to_network_order(flags)\n\
			qr, opcode, aa, tc, rd, ra, z, rcode = ((flags >> 15) & 0x1), ((flags >> 11) & 0xF), ((flags >> 10) & 0x1), ((flags >> 9) & 0x1), ((flags >> 8) & 0x1), ((flags >> 7) & 0x1), ((flags >> 6) & 0x7), (flags & 0x4)\n\
			if rcode ~= 0 then return nil, string.format('error resolving %s: %d', hostname, rcode) end\n\
			-- question section\n\
			local offset = 13\n\
			local domain\n\
			local function read_label(message, offset)\n\
				local label = {}\n\
				while true do\n\
					local length = message:byte(offset)\n\
					if length == 0 then offset = offset + 1 break end\n\
					if length >= 96 then -- offset compressiong\n\
            local offset_from_start = convert_to_network_order(string.unpack('H', message, offset)) & 0x3FFF\n\
						local offset_label = read_label(message, offset_from_start + 1)\n\
						table.insert(label, offset_label)\n\
						offset = offset + 2\n\
						break\n\
					else\n\
						table.insert(label, message:sub(offset + 1, offset + 1 + length - 1))\n\
						offset = offset + 1 + length\n\
					end\n\
				end\n\
				return table.concat(label, '.'), offset\n\
			end\n\
			for qid = 1, convert_to_network_order(nq) do\n\
        domain, offset = read_label(response, offset)\n\
        offset = offset + 4\n\
      end\n\
			-- rarr\n\
			local ips = {}\n\
			now = os.time()\n\
			for rid = 1, convert_to_network_order(na) do\n\
				domain, offset = read_label(response, offset)\n\
				local type, class, ttl, rdlength = string.unpack('HHI4H', response, offset)\n\
				ttl = (ttl >> 24) | (((ttl >> 16) & 0xFF) << 8) | (((ttl >> 8) & 0xFF) << 16) | (((ttl >> 0) & 0xFF) << 24)\n\
				ips.ttl = now + ttl\n\
				offset = offset + 10\n\
				if convert_to_network_order(type) == 1 then\n\
					table.insert(ips, string.format('%d.%d.%d.%d', string.unpack('BBBB', response, offset)))\n\
				end\n\
				offset = offset + convert_to_network_order(rdlength)\n\
			end\n\
			self.cache[hostname] = ips\n\
			return table.unpack(ips)\n\
    end\n\
    \n\
    function socket.new(default_options)\n\
      local options = { max_redirects = 10, redirect = true, max_timeout = 5, headers = { ['user-agent'] = 'wtk-client/1.0' }, resolver = socket.resolver.new(), cookies = {} }\n\
      for k,v in pairs(default_options or {}) do options[k] = v end\n\
      return {\n\
        connections = {},\n\
        encode = function(value) return value end,\n\
        decode = function(value) return value end,\n\
        request = function(self, method, url, body, options, headers)\n\
          local t = { }\n\
          headers = headers or {}\n\
          options = options or {}\n\
          t.body = body\n\
          if t.body ~= nil and type(t.body) == 'string' and not headers['content-length'] then headers['content-length'] = #body end\n\
          for k,v in pairs(self.options) do t[k] = v end\n\
          for k,v in pairs(options) do t[k] = v end\n\
          for k,v in pairs(headers) do t.headers[k] = v end\n\
          t.method = method\n\
          t.url = url\n\
          local res\n\
          while true do\n\
            local protocol, hostname, implied_port, explicit_port, path = socket.componentsURI(t.url)\n\
            if self.cookies and self.cookies[hostname] then\n\
              local values = {}\n\
              for k,v in pairs(self.cookies[hostname]) do table.insert(values, k .. '=' .. self.encode(v.value)) end\n\
              if not t.headers['cookie'] then t.headers['cookie'] = table.concat(values, '; ') end\n\
            end\n\
            if not headers.host then t.headers.host = hostname .. (explicit_port and (':' .. port) or '') end\n\
            local key = protocol .. hostname .. implied_port\n\
            if self.connections[key] then\n\
							res, err = self.connections[key]:request(t)\n\
							if not res then\n\
								assert(err == 'closed', err)\n\
								self.connections[key] = nil\n\
							end\n\
						end\n\
						if not self.connections[key] then\n\
							local ip = assert(self.options.resolver:resolve(hostname, not coroutine.isyieldable()))\n\
							self.connections[key] = assert(socket:open(protocol, hostname, ip, implied_port, not coroutine.isyieldable()))\n\
							res = assert(self.connections[key]:request(t))\n\
						end\n\
            if res.headers['set-cookie'] then\n\
              for i,v in ipairs(type(res.headers['set-cookie']) == 'table' and res.headers['set-cookie'] or { res.headers['set-cookie'] }) do\n\
                local _, e, name, value = v:find('^([^=]+)=([^;]+)')\n\
                if self.cookies then\n\
									if not self.cookies[hostname] then self.cookies[hostname] = {} end\n\
									self.cookies[hostname][name] = { value = self.decode(value) }\n\
								end\n\
              end\n\
            end\n\
            if method ~= 'HEAD' and (not options or options.body ~= 'nonblocking') then\n\
              res.body = {}\n\
              while true do\n\
                local chunk = res:read(4096, not coroutine.isyieldable())\n\
                if not chunk then break end\n\
                table.insert(res.body, chunk)\n\
              end\n\
              res.body = table.concat(res.body)\n\
            end\n\
            if res.code < 300 or res.code >= 400 then\n\
              break \n\
            end\n\
            if options.redirect == false then return res.body, res end\n\
            t.redirected = (t.redirected or 0) + 1\n\
            if t.redirected > t.max_redirects then error('redirected ' .. t.redirected .. ', which is over the max redirect threshold') end\n\
            local location = res.headers.location\n\
            if not location then error('tried to redirect ' .. t.redirected .. ' times, but server responded with ' .. res.code .. ', and no location header.') end\n\
            t.method = 'GET'\n\
            t.body = nil\n\
            if t.headers then t.headers['content-length'] = nil end\n\
            if location:find('^/') then\n\
              protocol, hostname, implied_port, explicit_port, path = socket.componentsURI(t.url)\n\
              t.url = protocol .. '://' .. hostname .. (explicit_port and (':' .. explicit_port) or '') .. location\n\
            else\n\
              t.url = location\n\
            end\n\
          end\n\
          return res\n\
        end,\n\
        get = function(self, url, options, headers) local res = self:request('GET', url, nil, options, headers) assert(res.code < 400, res) return res.body, res end,\n\
        head = function(self, url, options, headers) local res = self:request('HEAD', url, nil, options, headers) assert(res.code < 400, res) return res end,\n\
        post = function(self, url, body, options, headers) local res = self:request('POST', url, body, options, headers) assert(res.code < 400, res) return res.body, res end,\n\
        put = function(self, url, body, options, headers) local res = self:request('PUT', url, body, options, headers) assert(res.code < 400, res) return res.body, res end,\n\
        delete = function(self, url, body, options, headers) local res = self:request('DELETE', url, body, options, headers) assert(res.code < 400, res) return res.body, res end,\n\
        options = options\n\
      }\n\
    end\n\
  "))
    return lua_error(L);
  lua_pushvalue(L, -2);
  lua_call(L, 1, 0);
  return 1;
}
