/* TLS and cryptographic primitives only: no sockets, HTTP, protobuf, or XRPL parsing. */
#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#include <lean/lean.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/ec.h>
#include <openssl/ecdsa.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <openssl/ripemd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <limits.h>
#include <stdatomic.h>

typedef struct { SSL_CTX *ctx; SSL *ssl; } tls_state;
static lean_external_class *tls_class, *key_class;
static atomic_flag registration_lock = ATOMIC_FLAG_INIT;
static void tls_finalize(void *p) {
  tls_state *s = p;
  if (s) { SSL_free(s->ssl); SSL_CTX_free(s->ctx); free(s); }
}
static void key_finalize(void *p) { EC_KEY_free(p); }
static void no_children(void *p, b_lean_obj_arg f) { (void)p; (void)f; }
static void init_classes(void) {
  while (atomic_flag_test_and_set_explicit(&registration_lock, memory_order_acquire)) {}
  if (!tls_class) tls_class = lean_register_external_class(tls_finalize, no_children);
  if (!key_class) key_class = lean_register_external_class(key_finalize, no_children);
  atomic_flag_clear_explicit(&registration_lock, memory_order_release);
}
static lean_obj_res failure(const char *msg) {
  char buf[512], detail[256] = "";
  unsigned long e = ERR_get_error();
  if (e) ERR_error_string_n(e, detail, sizeof detail);
  snprintf(buf, sizeof buf, "%s%s%s", msg, e ? ": " : "", detail);
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(buf)));
}
static lean_object *bytes(const unsigned char *p, size_t n) {
  lean_object *a = lean_alloc_sarray(1, n, n);
  if (n) memcpy(lean_sarray_cptr(a), p, n);
  return a;
}
static tls_state *state(b_lean_obj_arg t) { return lean_get_external_data(t); }
LEAN_EXPORT lean_obj_res lx_ripemd160(b_lean_obj_arg a, lean_obj_arg w) {
  (void)w; unsigned char out[RIPEMD160_DIGEST_LENGTH];
  if (!RIPEMD160(lean_sarray_cptr(a), lean_sarray_size(a), out)) return failure("RIPEMD160 failed");
  return lean_io_result_mk_ok(bytes(out, sizeof out));
}
LEAN_EXPORT lean_obj_res lx_secp_public_valid(b_lean_obj_arg a, lean_obj_arg w) {
  (void)w; ERR_clear_error();
  EC_GROUP *group = EC_GROUP_new_by_curve_name(NID_secp256k1);
  EC_POINT *point = group ? EC_POINT_new(group) : NULL;
  const unsigned char *p = lean_sarray_cptr(a);
  int ok = point && lean_sarray_size(a) == 33 && (p[0] == 2 || p[0] == 3) &&
    EC_POINT_oct2point(group, point, p, 33, NULL) == 1 &&
    EC_POINT_is_at_infinity(group, point) == 0 && EC_POINT_is_on_curve(group, point, NULL) == 1;
  EC_POINT_free(point); EC_GROUP_free(group); ERR_clear_error();
  return lean_io_result_mk_ok(lean_box(ok));
}
LEAN_EXPORT lean_obj_res lx_tls_new(b_lean_obj_arg host, lean_obj_arg w) {
  (void)w; ERR_clear_error(); init_classes();
  tls_state *s = calloc(1, sizeof *s);
  if (!s) return failure("TLS allocation failed");
  s->ctx = SSL_CTX_new(TLS_client_method());
  if (!s->ctx) { tls_finalize(s); return failure("TLS context failed"); }
  SSL_CTX_set_min_proto_version(s->ctx, TLS1_2_VERSION);
  SSL_CTX_set_verify(s->ctx, SSL_VERIFY_NONE, NULL); /* XRPL authenticates via session signature. */
  SSL_CTX_set_options(s->ctx, SSL_OP_NO_RENEGOTIATION | SSL_OP_NO_COMPRESSION);
  s->ssl = SSL_new(s->ctx);
  BIO *in = BIO_new(BIO_s_mem()), *out = BIO_new(BIO_s_mem());
  if (!s->ssl || !in || !out) {
    BIO_free(in); BIO_free(out); tls_finalize(s); return failure("TLS BIO failed");
  }
  BIO_set_mem_eof_return(in, -1); BIO_set_mem_eof_return(out, -1);
  SSL_set_bio(s->ssl, in, out); SSL_set_connect_state(s->ssl);
  if (!SSL_set_tlsext_host_name(s->ssl, lean_string_cstr(host))) {
    tls_finalize(s); return failure("TLS SNI failed");
  }
  return lean_io_result_mk_ok(lean_alloc_external(tls_class, s));
}
LEAN_EXPORT lean_obj_res lx_tls_feed(b_lean_obj_arg t, b_lean_obj_arg a, lean_obj_arg w) {
  (void)w; ERR_clear_error(); tls_state *s = state(t); size_t n = lean_sarray_size(a);
  if (!s->ssl || n > INT_MAX) return failure("invalid TLS input");
  if (n && BIO_write(SSL_get_rbio(s->ssl), lean_sarray_cptr(a), (int)n) != (int)n)
    return failure("TLS input failed");
  return lean_io_result_mk_ok(lean_box(0));
}
LEAN_EXPORT lean_obj_res lx_tls_drain(b_lean_obj_arg t, lean_obj_arg w) {
  (void)w; tls_state *s = state(t);
  if (!s->ssl) return failure("TLS released");
  BIO *b = SSL_get_wbio(s->ssl); size_t n = BIO_ctrl_pending(b);
  if (n > INT_MAX) return failure("TLS output too large");
  lean_object *a = lean_alloc_sarray(1, n, n);
  if (n && BIO_read(b, lean_sarray_cptr(a), (int)n) != (int)n) {
    lean_dec(a); return failure("TLS output failed");
  }
  return lean_io_result_mk_ok(a);
}
LEAN_EXPORT lean_obj_res lx_tls_handshake(b_lean_obj_arg t, lean_obj_arg w) {
  (void)w; ERR_clear_error(); tls_state *s = state(t);
  if (!s->ssl) return failure("TLS released");
  int r = SSL_do_handshake(s->ssl);
  if (r == 1) return lean_io_result_mk_ok(lean_box(1));
  int e = SSL_get_error(s->ssl, r);
  if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE)
    return lean_io_result_mk_ok(lean_box(0));
  return failure("TLS handshake failed");
}
LEAN_EXPORT lean_obj_res lx_tls_read(b_lean_obj_arg t, lean_obj_arg w) {
  (void)w; ERR_clear_error(); tls_state *s = state(t); unsigned char buf[16384]; size_t n;
  if (!s->ssl) return failure("TLS released");
  int r = SSL_read_ex(s->ssl, buf, sizeof buf, &n);
  if (r == 1) {
    lean_object *some = lean_alloc_ctor(1, 1, 0); lean_ctor_set(some, 0, bytes(buf, n));
    return lean_io_result_mk_ok(some);
  }
  int e = SSL_get_error(s->ssl, r);
  if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE)
    return lean_io_result_mk_ok(lean_box(0));
  return failure(e == SSL_ERROR_ZERO_RETURN ? "TLS peer closed" : "TLS read failed");
}
LEAN_EXPORT lean_obj_res lx_tls_write(b_lean_obj_arg t, b_lean_obj_arg a, lean_obj_arg w) {
  (void)w; ERR_clear_error(); tls_state *s = state(t); size_t n = lean_sarray_size(a), wrote;
  if (!s->ssl || !SSL_is_init_finished(s->ssl)) return failure("TLS not ready");
  if (n && (!SSL_write_ex(s->ssl, lean_sarray_cptr(a), n, &wrote) || wrote != n))
    return failure("TLS write failed");
  return lean_io_result_mk_ok(lean_box(0));
}
LEAN_EXPORT lean_obj_res lx_tls_finished(b_lean_obj_arg t, uint8_t peer, lean_obj_arg w) {
  (void)w; tls_state *s = state(t); unsigned char buf[1024];
  if (!s->ssl) return failure("TLS released");
  size_t n = peer ? SSL_get_peer_finished(s->ssl, buf, sizeof buf) : SSL_get_finished(s->ssl, buf, sizeof buf);
  if (n < 12 || n > sizeof buf) return failure("TLS Finished unavailable");
  return lean_io_result_mk_ok(bytes(buf, n));
}
LEAN_EXPORT lean_obj_res lx_tls_release(b_lean_obj_arg t, lean_obj_arg w) {
  (void)w; tls_state *s = state(t); SSL_free(s->ssl); s->ssl = NULL;
  SSL_CTX_free(s->ctx); s->ctx = NULL;
  return lean_io_result_mk_ok(lean_box(0));
}
LEAN_EXPORT lean_obj_res lx_key_load(b_lean_obj_arg path, lean_obj_arg w) {
  (void)w; ERR_clear_error(); init_classes(); const char *p = lean_string_cstr(path);
  int fd = open(p, O_RDONLY | O_NOFOLLOW); EC_KEY *key = NULL;
  if (fd < 0 && errno == ENOENT) {
    key = EC_KEY_new_by_curve_name(NID_secp256k1);
    if (!key || !EC_KEY_generate_key(key)) { EC_KEY_free(key); return failure("key generation failed"); }
    fd = open(p, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) { EC_KEY_free(key); return failure("identity create failed"); }
    FILE *f = fdopen(fd, "w");
    if (!f) { close(fd); unlink(p); EC_KEY_free(key); return failure("identity stream failed"); }
    int ok = PEM_write_ECPrivateKey(f, key, NULL, NULL, 0, NULL, NULL);
    if (fflush(f) != 0 || fsync(fd) != 0) ok = 0;
    if (fclose(f) != 0) ok = 0;
    if (!ok) { unlink(p); EC_KEY_free(key); return failure("identity save failed"); }
  } else {
    if (fd < 0) return failure("identity open failed");
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 077)) {
      close(fd); return failure("identity must be an owned regular file with mode 0600");
    }
    FILE *f = fdopen(fd, "r");
    if (!f) { close(fd); return failure("identity stream failed"); }
    key = PEM_read_ECPrivateKey(f, NULL, NULL, NULL); fclose(f);
  }
  if (!key || EC_GROUP_get_curve_name(EC_KEY_get0_group(key)) != NID_secp256k1 || !EC_KEY_check_key(key)) {
    EC_KEY_free(key); return failure("invalid secp256k1 identity");
  }
  return lean_io_result_mk_ok(lean_alloc_external(key_class, key));
}
LEAN_EXPORT lean_obj_res lx_key_public(b_lean_obj_arg k, lean_obj_arg w) {
  (void)w; EC_KEY *key = lean_get_external_data(k); unsigned char buf[33];
  if (EC_POINT_point2oct(EC_KEY_get0_group(key), EC_KEY_get0_public_key(key),
      POINT_CONVERSION_COMPRESSED, buf, sizeof buf, NULL) != 33) return failure("public key failed");
  return lean_io_result_mk_ok(bytes(buf, 33));
}
LEAN_EXPORT lean_obj_res lx_key_sign(b_lean_obj_arg k, b_lean_obj_arg d, lean_obj_arg w) {
  (void)w; ERR_clear_error(); if (lean_sarray_size(d) != 32) return failure("digest must be 32 bytes");
  EC_KEY *key = lean_get_external_data(k);
  ECDSA_SIG *sig = ECDSA_do_sign(lean_sarray_cptr(d), 32, key);
  if (!sig) return failure("signature failed");
  const BIGNUM *r, *s; ECDSA_SIG_get0(sig, &r, &s);
  BIGNUM *order = BN_new(), *half = BN_new();
  if (!order || !half || !EC_GROUP_get_order(EC_KEY_get0_group(key), order, NULL) || !BN_rshift1(half, order)) {
    BN_free(order); BN_free(half); ECDSA_SIG_free(sig); return failure("signature normalization failed");
  }
  if (BN_cmp(s, half) > 0) {
    BIGNUM *low = BN_new(), *rr = BN_dup(r);
    if (!low || !rr || !BN_sub(low, order, s) || !ECDSA_SIG_set0(sig, rr, low)) {
      BN_free(low); BN_free(rr); BN_free(order); BN_free(half); ECDSA_SIG_free(sig);
      return failure("signature normalization failed");
    }
  }
  BN_free(order); BN_free(half);
  unsigned char buf[80], *cursor = buf; int n = i2d_ECDSA_SIG(sig, &cursor); ECDSA_SIG_free(sig);
  if (n <= 0 || n > 80) return failure("signature encoding failed");
  return lean_io_result_mk_ok(bytes(buf, (size_t)n));
}
LEAN_EXPORT lean_obj_res lx_verify_canonical(b_lean_obj_arg pub, b_lean_obj_arg d, b_lean_obj_arg signature, uint8_t low_s, lean_obj_arg w) {
  (void)w; ERR_clear_error(); size_t n = lean_sarray_size(signature);
  if (lean_sarray_size(pub) != 33 || lean_sarray_size(d) != 32 || n < 8 || n > 72)
    return lean_io_result_mk_ok(lean_box(0));
  EC_KEY *key = EC_KEY_new_by_curve_name(NID_secp256k1);
  const unsigned char *p = lean_sarray_cptr(pub), *q = lean_sarray_cptr(signature), *end = q + n;
  ECDSA_SIG *sig = d2i_ECDSA_SIG(NULL, &q, (long)n);
  unsigned char canonical[80], *c = canonical;
  int valid = key && sig && q == end && i2d_ECDSA_SIG(sig, &c) == (int)n
    && !memcmp(canonical, lean_sarray_cptr(signature), n)
    && o2i_ECPublicKey(&key, &p, 33) && EC_KEY_check_key(key)
    && ECDSA_do_verify(lean_sarray_cptr(d), 32, sig, key) == 1;
  if (valid && low_s) {
    const BIGNUM *r, *s; ECDSA_SIG_get0(sig, &r, &s);
    BIGNUM *order = BN_new(), *half = BN_new();
    valid = order && half && EC_GROUP_get_order(EC_KEY_get0_group(key), order, NULL)
      && BN_rshift1(half, order) && BN_cmp(s, half) <= 0;
    BN_free(order); BN_free(half);
  }
  ECDSA_SIG_free(sig); EC_KEY_free(key); ERR_clear_error();
  return lean_io_result_mk_ok(lean_box(valid));
}
LEAN_EXPORT lean_obj_res lx_verify(b_lean_obj_arg pub, b_lean_obj_arg d, b_lean_obj_arg signature, lean_obj_arg w) {
  return lx_verify_canonical(pub, d, signature, 0, w);
}
LEAN_EXPORT lean_obj_res lx_ed_verify(b_lean_obj_arg pub, b_lean_obj_arg message, b_lean_obj_arg signature, lean_obj_arg w) {
  (void)w; ERR_clear_error();
  if (lean_sarray_size(pub) != 32 || lean_sarray_size(signature) != 64)
    return lean_io_result_mk_ok(lean_box(0));
  EVP_PKEY *key = EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, NULL, lean_sarray_cptr(pub), 32);
  EVP_MD_CTX *ctx = EVP_MD_CTX_new();
  int valid = key && ctx && EVP_DigestVerifyInit(ctx, NULL, NULL, NULL, key) == 1
    && EVP_DigestVerify(ctx, lean_sarray_cptr(signature), 64,
      lean_sarray_cptr(message), lean_sarray_size(message)) == 1;
  EVP_MD_CTX_free(ctx); EVP_PKEY_free(key); ERR_clear_error();
  return lean_io_result_mk_ok(lean_box(valid));
}
LEAN_EXPORT lean_obj_res lx_sha256(b_lean_obj_arg a, lean_obj_arg w) {
  (void)w; unsigned char out[32];
  if (!SHA256(lean_sarray_cptr(a), lean_sarray_size(a), out)) return failure("SHA256 failed");
  return lean_io_result_mk_ok(bytes(out, sizeof out));
}
LEAN_EXPORT lean_obj_res lx_sha512(b_lean_obj_arg a, lean_obj_arg w) {
  (void)w; unsigned char out[64];
  if (!SHA512(lean_sarray_cptr(a), lean_sarray_size(a), out)) return failure("SHA512 failed");
  return lean_io_result_mk_ok(bytes(out, sizeof out));
}
LEAN_EXPORT lean_obj_res lx_random(uint32_t n, lean_obj_arg w) {
  (void)w; if (n > 4096) return failure("random request too large");
  unsigned char buf[4096]; if (RAND_bytes(buf, (int)n) != 1) return failure("random generation failed");
  return lean_io_result_mk_ok(bytes(buf, n));
}
