#define WTK_SERVER_SSL

#include <wtk.c>
#include <server.c>
#include <client.c>
#include <json.c>
#include <proc.c>
#include <stdio.h>
#include <mbedtls/x509_csr.h>
#include <mbedtls/sha256.h>

#ifndef WTKPROXY_VERSION
  #define WTKPROXY_VERSION "unknown"
#endif

// https://github.com/Mbed-TLS/mbedtls/blob/mbedtls-3.6/programs/pkey/gen_key.c
// https://github.com/Mbed-TLS/mbedtls/blob/mbedtls-3.6/programs/pkey/rsa_genkey.c
static int lua_setmpi(lua_State* L, int index, mbedtls_mpi* mpi, const char* key) {
  unsigned char component_buf[MBEDTLS_MPI_MAX_SIZE] = {0};
  size_t length = mbedtls_mpi_size(mpi);
  mbedtls_mpi_write_binary(mpi, component_buf, length);
  lua_pushlstring(L, component_buf, length);
  lua_setfield(L, -2, key);
  return 0;
}
static int f_components(lua_State* L) {
  mbedtls_mpi N, P, Q, D, E, DP, DQ, QP;
  mbedtls_mpi_init(&N); mbedtls_mpi_init(&P); mbedtls_mpi_init(&Q);
  mbedtls_mpi_init(&D); mbedtls_mpi_init(&E); mbedtls_mpi_init(&DP);
  mbedtls_mpi_init(&DQ); mbedtls_mpi_init(&QP);
  mbedtls_entropy_context entropy;
  mbedtls_entropy_init(&entropy);
  mbedtls_ctr_drbg_context ctr_drbg;
  mbedtls_ctr_drbg_init(&ctr_drbg);
  mbedtls_pk_context key;
  mbedtls_pk_init(&key);
  size_t private_key_length;
  const char* private_key = luaL_checklstring(L, 1, &private_key_length);
  lua_newtable(L);
  int ret = 0;
  const unsigned char* pers = "components";
  int failure = 
    (ret = mbedtls_ctr_drbg_seed(&ctr_drbg, mbedtls_entropy_func, &entropy, pers, strlen(pers))) != 0 ||
    (ret = mbedtls_pk_parse_key(&key, private_key, private_key_length + 1, NULL, 0, mbedtls_ctr_drbg_random, &ctr_drbg)) != 0 ||
    (ret = mbedtls_rsa_export(mbedtls_pk_rsa(key), &N, &P, &Q, &D, &E)) != 0 ||
    (ret = mbedtls_rsa_export_crt(mbedtls_pk_rsa(key), &DP, &DQ, &QP)) != 0;
  lua_setmpi(L, -2, &N, "n"); lua_setmpi(L, -2, &P, "p"); lua_setmpi(L, -2, &Q, "q"); 
  lua_setmpi(L, -2, &D, "d"); lua_setmpi(L, -2, &E, "e"); lua_setmpi(L, -2, &DP, "dp"); 
  lua_setmpi(L, -2, &DQ, "dq"); lua_setmpi(L, -2, &QP, "qp") != 0;
  if (failure) {
    char error_buf[1024];
    mbedtls_strerror(ret, error_buf, sizeof(error_buf));
    lua_pushnil(L);
    lua_pushstring(L, error_buf);
  }
  mbedtls_mpi_free(&N); mbedtls_mpi_free(&P); mbedtls_mpi_free(&Q);
  mbedtls_mpi_free(&D); mbedtls_mpi_free(&E); mbedtls_mpi_free(&DP);
  mbedtls_mpi_free(&DQ); mbedtls_mpi_free(&QP);
  mbedtls_pk_free(&key);
  mbedtls_entropy_free(&entropy);
  mbedtls_ctr_drbg_free(&ctr_drbg);
  return failure ? 2 : 1;
}

static int f_create_keypair(lua_State* L) {
  int ret = 0;
  mbedtls_pk_context key;
  mbedtls_entropy_context entropy;
  mbedtls_ctr_drbg_context ctr_drbg;
  const unsigned char *pers = "gen_key";
  mbedtls_entropy_init(&entropy);
  mbedtls_pk_init(&key);
  mbedtls_ctr_drbg_init(&ctr_drbg);
  static int KEY_SIZE = 4096;
  static int EXPONENT = 65537;
  unsigned char privkey_buf[16000] = {0};
  unsigned char pubkey_buf[16000] = {0};
  int success = 
    ((ret = mbedtls_ctr_drbg_seed(&ctr_drbg, mbedtls_entropy_func, &entropy, pers, strlen(pers))) != 0) ||
    ((ret = mbedtls_pk_setup(&key, mbedtls_pk_info_from_type(MBEDTLS_PK_RSA))) != 0) ||
    ((ret = mbedtls_rsa_gen_key(mbedtls_pk_rsa(key), mbedtls_ctr_drbg_random, &ctr_drbg, KEY_SIZE, EXPONENT)) != 0) || 
    ((ret = mbedtls_pk_write_key_pem(&key, privkey_buf, sizeof(privkey_buf))) != 0) ||
    ((ret = mbedtls_pk_write_pubkey_pem(&key, pubkey_buf, sizeof(pubkey_buf))) != 0);
  mbedtls_pk_free(&key);
  mbedtls_ctr_drbg_free(&ctr_drbg);
  mbedtls_entropy_free(&entropy);
  if (ret) {
    mbedtls_strerror(ret, privkey_buf, sizeof(privkey_buf));
    lua_pushnil(L);
    lua_pushstring(L, privkey_buf);
  } else {
    lua_pushstring(L, privkey_buf);
    lua_pushstring(L, pubkey_buf);
  }
  return 2;
}

static int f_sign_message(lua_State* L) {
  size_t private_key_length;
  const char* private_key = luaL_checklstring(L, 1, &private_key_length);
  size_t message_length;
  const char* message = luaL_checklstring(L, 2, &message_length);
  mbedtls_entropy_context entropy;
  mbedtls_entropy_init(&entropy);
  mbedtls_ctr_drbg_context ctr_drbg;
  mbedtls_ctr_drbg_init(&ctr_drbg);
  mbedtls_pk_context key;
  mbedtls_pk_init(&key);
  unsigned char signature[1024] = {0};
  unsigned char hash[32] = {0};
  int ret = 0;
  size_t signature_length;
  const char* pers = "rsa_sign_pss";
  if (
    (ret = mbedtls_ctr_drbg_seed(&ctr_drbg, mbedtls_entropy_func, &entropy, pers, strlen(pers))) != 0 ||
    (ret = mbedtls_sha256(message, message_length, hash, 0)) != 0 ||
    (ret = mbedtls_pk_parse_key(&key, private_key, private_key_length + 1, NULL, 0, mbedtls_ctr_drbg_random, &ctr_drbg)) != 0 ||
    (ret = mbedtls_rsa_set_padding(mbedtls_pk_rsa(key), MBEDTLS_RSA_PKCS_V15, MBEDTLS_MD_SHA256)) != 0 ||
    (ret = mbedtls_pk_sign(&key, MBEDTLS_MD_SHA256, hash, sizeof(hash), signature, sizeof(signature), &signature_length, mbedtls_ctr_drbg_random, &ctr_drbg)) != 0
   ) {
    char error_buf[1024];
    mbedtls_strerror(ret, error_buf, sizeof(error_buf));
    lua_pushnil(L);
    lua_pushstring(L, error_buf);
   } else {
    lua_pushlstring(L, signature, signature_length);
  }
  mbedtls_pk_free(&key);
  mbedtls_ctr_drbg_free(&ctr_drbg);
  mbedtls_entropy_free(&entropy);
  return ret != 0 ? 2 : 1;
}

static int f_parse_cert(lua_State* L) {
  size_t certificate_length;
  const char* certificate = luaL_checklstring(L, 1, &certificate_length);
  mbedtls_x509_crt crt;
  mbedtls_x509_crt_init(&crt);
  int ret = mbedtls_x509_crt_parse(&crt, certificate, certificate_length);
  if (ret) {
    mbedtls_x509_crt_free(&crt);
    lua_pushnil(L);
    lua_pushliteral(L, "error parsing certificate");
    return 2;
  }
  lua_newtable(L);
  struct tm time={0};
  time.tm_sec = crt.valid_to.sec;
  time.tm_min = crt.valid_to.min;
  time.tm_hour = crt.valid_to.hour;
  time.tm_mday = crt.valid_to.day;
  time.tm_mon = crt.valid_to.mon;
  time.tm_year = crt.valid_to.year - 1900;
  lua_pushinteger(L, mktime(&time));
  lua_setfield(L, -2, "valid_to");
  mbedtls_x509_crt_free(&crt);
  return 1;
}

// https://github.com/Mbed-TLS/mbedtls/blob/mbedtls-3.6/programs/x509/cert_req.c
static int f_create_csr(lua_State* L) {
  int ret = 0;
  const char* pers = "csr_create";
  size_t private_key_length;
  const char* private_key = luaL_checklstring(L, 1, &private_key_length);
  luaL_checktype(L, 2, LUA_TTABLE);
  const char* domain = NULL;
  if (lua_rawlen(L, 2) >= 1) {
    lua_rawgeti(L, 2, 1);
    domain = luaL_checkstring(L, -1);
    lua_pop(L, 1);
  }
  mbedtls_ctr_drbg_context ctr_drbg;
  mbedtls_ctr_drbg_init(&ctr_drbg);
  mbedtls_entropy_context entropy;
  mbedtls_entropy_init(&entropy);
  mbedtls_pk_context key;
  mbedtls_pk_init(&key);
  mbedtls_ctr_drbg_seed(&ctr_drbg, mbedtls_entropy_func, &entropy, pers, strlen(pers));
  mbedtls_pk_parse_key(&key, private_key, private_key_length + 1, NULL, 0, mbedtls_ctr_drbg_random, &ctr_drbg);
  mbedtls_x509write_csr req;
  mbedtls_x509write_csr_init(&req);
  mbedtls_x509write_csr_set_md_alg(&req, MBEDTLS_MD_SHA256);
  mbedtls_x509write_csr_set_key(&req, &key);
  mbedtls_x509write_csr_set_subject_name(&req, domain);
  mbedtls_x509_san_list* subject_list = NULL;
  for (int i = 1; i <= lua_rawlen(L, 2); ++i) {
    mbedtls_x509_san_list* list = calloc(1, sizeof(mbedtls_x509_san_list));
    list->node.type = MBEDTLS_X509_SAN_DNS_NAME;
    lua_rawgeti(L, 2, i);
    list->node.san.unstructured_name.p = (char*)luaL_checklstring(L, -1, &list->node.san.unstructured_name.len);
    lua_pop(L, 1);
    list->next = subject_list;
    subject_list = list;
  }
  mbedtls_x509write_csr_set_subject_alternative_name(&req, subject_list);
  unsigned char buf[4096];  
  ret = mbedtls_x509write_csr_pem(&req, buf, sizeof(buf), mbedtls_ctr_drbg_random, &ctr_drbg);
  mbedtls_pk_free(&key);
  mbedtls_ctr_drbg_free(&ctr_drbg);
  mbedtls_entropy_free(&entropy);
  mbedtls_x509write_csr_free(&req);
  while (subject_list) {
    mbedtls_x509_san_list* list = subject_list->next;
    free(subject_list);
    subject_list = list->next;
  }
  if (ret) {
    mbedtls_strerror(ret, buf, sizeof(buf));
    return luaL_error(L, "error generating private key: %s", buf);
  }
  lua_pushstring(L, buf);
  return 1;
}

static int f_sha256(lua_State* L) {
  size_t len;
  const char* str = luaL_checklstring(L, 1, &len);
  char hash[32];
  mbedtls_sha256(str, len, hash, 0);
  lua_pushlstring(L, hash, sizeof(hash));
  return 1;
}


static const luaL_Reg acme_lib[] = {
  { "keypair",    f_create_keypair   },
  { "sign",       f_sign_message     },
  { "csr",        f_create_csr       },
  { "cert",       f_parse_cert       },
  { "components", f_components       },
  { "sha256",     f_sha256           },
  { NULL,        NULL }
};

int main(int argc, char* argv[]) {
  lua_State* L = luaL_newstate();
  luaL_openlibs(L);
  void** extra = lua_getextraspace(L);
  luaL_requiref(L, "wtk.c", luaopen_wtk_c, 0);
  luaW_requiref(L, "wtk.server.c", luaopen_wtk_server_c);
  luaW_requiref(L, "wtk.client.c", luaopen_wtk_client_c);
  luaW_requiref(L, "wtk.json.c", luaopen_wtk_json_c);
  luaW_requiref(L, "wtk.proc.c", luaopen_wtk_proc_c);
  lua_pushliteral(L, WTKPROXY_VERSION), lua_setglobal(L, "VERSION");
  lua_newtable(L);
  luaL_setfuncs(L, acme_lib, 0);
  lua_setglobal(L, "ACME");
  if (luaW_signal(L) || luaW_packlua(L, ".") || luaW_loadentry(L, "init") || luaW_run(L, argc, argv)) {
    fprintf(stderr, "%s\n", lua_tostring(L, -1));
    return -1;
  }
  lua_close(L);
  return 0;
}

