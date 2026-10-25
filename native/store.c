/* SQLite metadata and selectable node persistence. XRPL verification stays in Lean. */
#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#include <lean/lean.h>
#include <sqlite3.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <pthread.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif
#include "nudb_store.h"

static _Thread_local int on_storage_worker;

/* The Lean definition remains the specification. Borrowed byte arrays are
   compared directly, without allocating/boxing individual key bytes. */
LEAN_EXPORT uint8_t lx_compare_bytes(b_lean_obj_arg a,b_lean_obj_arg b) {
  size_t na=lean_sarray_size(a),nb=lean_sarray_size(b),n=na<nb?na:nb;
  int order=n?memcmp(lean_sarray_cptr(a),lean_sarray_cptr(b),n):0;
  if(order<0)return 0;if(order>0)return 2;
  return na<nb?0:na>nb?2:1;
}

typedef struct store {
  sqlite3 *db;
  int lock, transaction, readonly, metadata_only;
  int worker_owned;
  pthread_t owner;
  int owned_registered;
  void *nudb;
  char *path;
  uint64_t max_bytes, sqlite_bytes;
  char node_error[512];
  atomic_uint owned_refs;
  struct store *owned_next;
  int64_t counts[4], saved[4]; /* unique nodes, leaves, wire bytes, pending paths */
  int scoped;
  int64_t global_counts[4], global_saved[4];
  sqlite3_stmt *scope_stats;
  sqlite3_stmt *get, *put, *pending_get, *pending_add, *pending_del, *reserve, *lease;
  sqlite3_stmt *meta_get, *meta_put, *stats;
  sqlite3_stmt *pending_ready, *pending_release;
  sqlite3_stmt *closed_has, *closed_add, *waiting_get, *waiting_put, *waiting_del;
  sqlite3_stmt *previous_get, *previous_put;
  sqlite3_stmt *history[16];
  sqlite3_stmt *view_lookup;
  char *view_base;
  lean_object *view_sources[8];
  unsigned view_next;
} store;
static _Thread_local store *owned_stores;
static lean_external_class *store_class;
static atomic_flag class_lock = ATOMIC_FLAG_INIT;
static lean_obj_res fail(store *s, const char *what) {
  char message[512];
  snprintf(message, sizeof message, "node store: %s%s%s", what,
    s && s->db ? ": " : "", s && s->db ? sqlite3_errmsg(s->db) : "");
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(message)));
}
static lean_obj_res ok(void) { return lean_io_result_mk_ok(lean_box(0)); }
static lean_obj_res nudb_fail(store *s, const char *what) {
  char message[768];
  snprintf(message,sizeof message,"%s: %s",what,lx_nudb_error());
  return fail(NULL,message);
}
static lean_object *blob(const void *p, size_t n) {
  lean_object *a = lean_alloc_sarray(1, n, n);
  if (n) memcpy(lean_sarray_cptr(a), p, n);
  return a;
}
static void reset(sqlite3_stmt *st) { sqlite3_reset(st); sqlite3_clear_bindings(st); }
static void bind_blob(sqlite3_stmt *st, int i, b_lean_obj_arg a) {
  sqlite3_bind_blob(st, i, lean_sarray_cptr(a), (int)lean_sarray_size(a), SQLITE_TRANSIENT);
}
static int sql(store *s, const char *q) { return sqlite3_exec(s->db, q, NULL, NULL, NULL) == SQLITE_OK; }
static void release_handles(store *s) {
  for(unsigned i=0;i<8;i++)if(s->view_sources[i]){lean_dec(s->view_sources[i]);s->view_sources[i]=NULL;}
  if(s->view_lookup){sqlite3_finalize(s->view_lookup);s->view_lookup=NULL;}
  free(s->view_base);s->view_base=NULL;
  if(s->scope_stats){sqlite3_finalize(s->scope_stats);s->scope_stats=NULL;}
  sqlite3_stmt **fields[]={&s->get,&s->put,&s->pending_get,&s->pending_add,&s->pending_del,
    &s->reserve,&s->lease,&s->meta_get,&s->meta_put,&s->stats,&s->pending_ready,&s->pending_release,
    &s->closed_has,&s->closed_add,&s->waiting_get,&s->waiting_put,&s->waiting_del,&s->previous_get,&s->previous_put};
  for(size_t i=0;i<sizeof fields/sizeof fields[0];i++){if(*fields[i])sqlite3_finalize(*fields[i]);*fields[i]=NULL;}
  for(int i=0;i<16;i++){if(s->history[i])sqlite3_finalize(s->history[i]);s->history[i]=NULL;}
  if(s->nudb){lx_nudb_release(s->nudb);s->nudb=NULL;}
  if(s->db){sqlite3_close_v2(s->db);s->db=NULL;}
  if(s->lock>=0){close(s->lock);s->lock=-1;}
  free(s->path);s->path=NULL;
}
static void close_store(void *p) {
  store *s=p;if(!s)return;
  /* The worker retains a native reference. GC on any other thread can only
     release its reference; connection finalization stays on the owner. */
  if(s->owned_registered){if(atomic_fetch_sub(&s->owned_refs,1)==1)free(s);}
  else {release_handles(s);free(s);}
}
static void no_children(void *p, b_lean_obj_arg f) { (void)p; (void)f; }
#define STORE(a) store *s = lean_get_external_data(a); if (!s->db) return fail(s, "closed"); if(s->worker_owned && !pthread_equal(s->owner,pthread_self())) return fail(NULL,"database accessed outside storage worker")
#define WRITE_STORE(a) STORE(a); if (s->readonly) return fail(s, "read-only store")
static int transaction_active(store *s) { return s->transaction && !sqlite3_get_autocommit(s->db); }
/* The catalog is authoritative for visibility, including rollback and old read snapshots.
   NuDB may contain unreachable physical orphans after a failed metadata commit. */
static int read_node_depth(store *,const void *,unsigned char **,size_t *,int *,unsigned);
static int read_node(store *s,const void *hash,unsigned char **data,size_t *size,int *leaf) {
  return read_node_depth(s,hash,data,size,leaf,0);
}
static int read_local_node(store *s,const void *hash,unsigned char **data,size_t *size,int *leaf) {
  *data=NULL;*size=0;
  sqlite3_bind_blob(s->get,1,hash,32,SQLITE_TRANSIENT);
  int rc=sqlite3_step(s->get);
  if(rc==SQLITE_DONE){reset(s->get);return 0;}
  if(rc!=SQLITE_ROW){reset(s->get);snprintf(s->node_error,sizeof s->node_error,"node catalog read: %s",sqlite3_errmsg(s->db));return -1;}
  if(s->nudb){
    sqlite3_int64 expected=sqlite3_column_int64(s->get,0);
    if(leaf)*leaf=sqlite3_column_int(s->get,1);
    reset(s->get);
    if(!lx_nudb_get(s->nudb,hash,data,size)){
      snprintf(s->node_error,sizeof s->node_error,"NuDB node read: %s",lx_nudb_error());return -1;
    }
    if(!*data || expected<0 || (uint64_t)expected!=*size){
      free(*data);*data=NULL;snprintf(s->node_error,sizeof s->node_error,"cataloged NuDB node missing or wrong length");return -1;
    }
  }else{
    *size=(size_t)sqlite3_column_bytes(s->get,0);
    *data=malloc(*size?*size:1);
    if(!*data){reset(s->get);snprintf(s->node_error,sizeof s->node_error,"node allocation failed");return -1;}
    if(*size)memcpy(*data,sqlite3_column_blob(s->get,0),*size);
    if(leaf)*leaf=*size&&(*data)[*size-1]==1;
    reset(s->get);
  }
  return 1;
}
static int node_budget(store *s,uint64_t *budget) {
  sqlite3_stmt *q=NULL;uint64_t count=0,size=0;
  if(sqlite3_prepare_v2(s->db,"PRAGMA page_count",-1,&q,NULL)!=SQLITE_OK)return 0;
  if(sqlite3_step(q)==SQLITE_ROW)count=(uint64_t)sqlite3_column_int64(q,0);
  sqlite3_finalize(q);q=NULL;
  if(sqlite3_prepare_v2(s->db,"PRAGMA page_size",-1,&q,NULL)!=SQLITE_OK)return 0;
  if(sqlite3_step(q)==SQLITE_ROW)size=(uint64_t)sqlite3_column_int64(q,0);
  sqlite3_finalize(q);
  if(!size || count>s->max_bytes/size)return 0;
  s->sqlite_bytes=count*size;*budget=s->max_bytes-s->sqlite_bytes;return 1;
}
static int storage_config(store *s,int requested) {
  sqlite3_stmt *q=NULL;int exists=0;
  if(sqlite3_prepare_v2(s->db,"SELECT 1 FROM sqlite_master WHERE type='table' AND name='node_storage'",-1,&q,NULL)!=SQLITE_OK)return 0;
  exists=sqlite3_step(q)==SQLITE_ROW;sqlite3_finalize(q);q=NULL;
  char backend[32]="",generation[35]="";
  if(exists){
    if(sqlite3_prepare_v2(s->db,"SELECT backend,generation FROM node_storage WHERE id=1",-1,&q,NULL)!=SQLITE_OK)return 0;
    int rc=sqlite3_step(q);
    if(rc==SQLITE_ROW){
      const unsigned char *b=sqlite3_column_text(q,0),*g=sqlite3_column_text(q,1);
      if(!b||!g||sqlite3_column_bytes(q,0)>=32||sqlite3_column_bytes(q,1)>=35){sqlite3_finalize(q);return 0;}
      strcpy(backend,(const char*)b);strcpy(generation,(const char*)g);
    }else if(rc!=SQLITE_DONE){sqlite3_finalize(q);return 0;}
    sqlite3_finalize(q);q=NULL;
  }
  int fresh=!backend[0];
  if(!fresh && strcmp(backend,"sqlite") && strcmp(backend,"nudb-v1"))return 0;
  int use_nudb=fresh ? requested==2 : !strcmp(backend,"nudb-v1");
  if(!fresh && requested && (requested==2)!=use_nudb)return 0;
  if(fresh && s->readonly){if(requested==2)return 0;return 1;}
  if(use_nudb){
    if(!lx_nudb_available())return 0;
    if(fresh){
      /* Never implicitly convert an existing payload table. */
      if(sqlite3_prepare_v2(s->db,"SELECT 1 FROM nodes LIMIT 1",-1,&q,NULL)!=SQLITE_OK)return 0;
      int any=sqlite3_step(q)==SQLITE_ROW;sqlite3_finalize(q);q=NULL;if(any)return 0;
      if(!lx_nudb_new_generation(generation))return 0;
    }
    s->nudb=lx_nudb_open(s->path,generation,fresh);
    if(!s->nudb)return 0;
  }
  if(fresh){
    if(!sql(s,"BEGIN IMMEDIATE; CREATE TABLE IF NOT EXISTS node_storage(id INTEGER PRIMARY KEY CHECK(id=1),backend TEXT NOT NULL,generation TEXT NOT NULL);"
        "CREATE TABLE IF NOT EXISTS node_catalog(hash BLOB PRIMARY KEY CHECK(length(hash)=32),bytes INTEGER NOT NULL CHECK(bytes>=0),leaf INTEGER NOT NULL CHECK(leaf IN (0,1))) WITHOUT ROWID;"))return 0;
    if(sqlite3_prepare_v2(s->db,"INSERT INTO node_storage VALUES(1,?1,?2)",-1,&q,NULL)!=SQLITE_OK)return 0;
    sqlite3_bind_text(q,1,use_nudb?"nudb-v1":"sqlite",-1,SQLITE_STATIC);
    sqlite3_bind_text(q,2,generation,-1,SQLITE_TRANSIENT);
    int done=sqlite3_step(q)==SQLITE_DONE;sqlite3_finalize(q);
    if(!done || !sql(s,"COMMIT"))return 0;
  }
  if(use_nudb){
    uint64_t bytes,budget;
    if(!node_budget(s,&budget)||!lx_nudb_bytes(s->nudb,&bytes)||bytes>budget)return 0;
    if(!s->readonly && !lx_nudb_cleanup(s->path,generation))return 0;
  }
  return 1;
}
static int prepare_view(store *s) {
  sqlite3_stmt *q=NULL;
  if(sqlite3_prepare_v2(s->db,"SELECT 1 FROM sqlite_master WHERE type='table' AND name='xl_view_config'",-1,&q,NULL)!=SQLITE_OK)return 0;
  int rc=sqlite3_step(q);sqlite3_finalize(q);
  if(rc==SQLITE_DONE)return 1;
  if(rc!=SQLITE_ROW)return 0;
  if(sqlite3_prepare_v2(s->db,"SELECT base_path FROM xl_view_config WHERE id=1",-1,&q,NULL)!=SQLITE_OK)return 0;
  rc=sqlite3_step(q);
  if(rc==SQLITE_ROW){
    const char *p=(const char*)sqlite3_column_text(q,0);
    if(p && sqlite3_column_bytes(q,0)>0)s->view_base=strdup(p);
  }
  sqlite3_finalize(q);
  if(!s->view_base)return 0;
  return sqlite3_prepare_v2(s->db,"SELECT path FROM xl_node_sources WHERE hash=?1",-1,&s->view_lookup,NULL)==SQLITE_OK;
}
static lean_obj_res open_store(b_lean_obj_arg path, uint64_t max_bytes, int readonly, int requested, lean_obj_arg w) {
  (void)w;
  store *s = calloc(1, sizeof *s);
  if (!s) return fail(NULL, "allocation failed");
  s->lock = -1;
  s->max_bytes=max_bytes;
  s->readonly = readonly;
  s->metadata_only = readonly == 2;
  s->worker_owned = on_storage_worker;
  s->owner = pthread_self();
  const char *name = lean_string_cstr(path);
  s->path=strdup(name);
  if(!s->path || requested<0 || requested>2){close_store(s);return fail(NULL,"invalid storage configuration");}
  if (!readonly) {
  char *lock_path = malloc(strlen(name)+6);
  if (!lock_path) { close_store(s); return fail(NULL, "allocation failed"); }
  sprintf(lock_path, "%s.lock", name);
  s->lock = open(lock_path, O_CREAT|O_RDWR|O_NOFOLLOW, 0600);
  free(lock_path);
  struct stat st;
  if (s->lock < 0 || fstat(s->lock, &st) || !S_ISREG(st.st_mode) ||
      st.st_uid != getuid() || flock(s->lock, LOCK_EX|LOCK_NB)) {
    close_store(s); return fail(NULL, "already in use or invalid lock file");
  }
  }
  struct stat st;
  if (!lstat(name, &st) && !S_ISREG(st.st_mode)) {
    close_store(s); return fail(NULL, "database must be a regular file");
  }
  if (sqlite3_open_v2(name, &s->db, readonly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE, NULL) != SQLITE_OK) {
    lean_object *e = fail(s, "open failed"); close_store(s); return e;
  }
  char *absolute=realpath(name,NULL);
  if(!absolute){close_store(s);return fail(NULL,"database path cannot be resolved");}
  free(s->path);s->path=absolute;
  sqlite3_busy_timeout(s->db, 5000);
  if (readonly && !sql(s, "PRAGMA query_only=ON; PRAGMA cache_size=-65536; BEGIN")) {
    lean_object *e = fail(s, "read-only snapshot failed"); close_store(s); return e;
  }
  if (!readonly && !sql(s, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA cache_size=-131072; PRAGMA wal_autocheckpoint=16384; PRAGMA temp_store=MEMORY;"
      "CREATE TABLE IF NOT EXISTS nodes(hash BLOB PRIMARY KEY CHECK(length(hash)=32), wire BLOB NOT NULL) WITHOUT ROWID;"
      "CREATE TABLE IF NOT EXISTS pending(id BLOB PRIMARY KEY CHECK(length(id)=33), hash BLOB NOT NULL CHECK(length(hash)=32), due INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;"
      /* Request leases are scheduling hints, reset on every open. Keep them in
         memory instead of rewriting a second durable frontier index per node. */
      "DROP INDEX IF EXISTS pending_due;"
      "CREATE TEMP TABLE request_leases(id BLOB PRIMARY KEY,due INTEGER NOT NULL) WITHOUT ROWID;"
      "CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;"
      "CREATE TABLE IF NOT EXISTS counters(id INTEGER PRIMARY KEY CHECK(id=1), nodes INTEGER, leaves INTEGER, bytes INTEGER, pending INTEGER);"
      "INSERT OR IGNORE INTO counters VALUES(1,0,0,0,0);")) {
    lean_object *e = fail(s, "initialize failed"); close_store(s); return e;
  }
  sqlite3_stmt *page_info = NULL;
  int page_size = 0;
  if (sqlite3_prepare_v2(s->db, "PRAGMA page_size", -1, &page_info, NULL) == SQLITE_OK &&
      sqlite3_step(page_info) == SQLITE_ROW) page_size = sqlite3_column_int(page_info, 0);
  sqlite3_finalize(page_info); page_info = NULL;
  char limit[128];
  snprintf(limit, sizeof limit, "PRAGMA max_page_count=%llu",
    (unsigned long long)(page_size > 0 ? max_bytes/(unsigned)page_size : 0));
  if (max_bytes < 1048576 || page_size <= 0 || (!readonly && !sql(s, limit))) {
    close_store(s); return fail(NULL, "invalid database size limit");
  }
  if (sqlite3_prepare_v2(s->db, "PRAGMA page_count", -1, &page_info, NULL) != SQLITE_OK ||
      sqlite3_step(page_info) != SQLITE_ROW ||
      (uint64_t)sqlite3_column_int64(page_info, 0) > max_bytes/(unsigned)page_size) {
    sqlite3_finalize(page_info); close_store(s); return fail(NULL, "database exceeds configured size limit");
  }
  sqlite3_finalize(page_info);
  sqlite3_stmt *initial = NULL;
  if (sqlite3_prepare_v2(s->db, "SELECT nodes,leaves,bytes,pending FROM counters WHERE id=1", -1, &initial, NULL) != SQLITE_OK || sqlite3_step(initial) != SQLITE_ROW) {
    sqlite3_finalize(initial); lean_object *e = fail(s, "counters unavailable"); close_store(s); return e;
  }
  for (int i=0;i<4;i++) s->counts[i] = sqlite3_column_int64(initial,i);
  sqlite3_finalize(initial);
  if(!s->metadata_only && !storage_config(s,requested)){
    char message[768];snprintf(message,sizeof message,"invalid/unavailable node backend, backend mismatch, or allocation limit: %s",lx_nudb_error());
    close_store(s);return fail(NULL,message);
  }
#define PREP(field,q) if (sqlite3_prepare_v2(s->db,q,-1,&s->field,NULL) != SQLITE_OK) { lean_object *e=fail(s,"prepare failed"); close_store(s); return e; }
  PREP(get, s->nudb?"SELECT bytes,leaf FROM node_catalog WHERE hash=?1":"SELECT wire FROM nodes WHERE hash=?1");
  PREP(put, s->nudb?"INSERT OR IGNORE INTO node_catalog VALUES(?1,?2,?3)":"INSERT OR IGNORE INTO nodes VALUES(?1,?2)");
  PREP(pending_get, "SELECT hash FROM pending WHERE id=?1");
  PREP(pending_add, "INSERT OR IGNORE INTO pending(id,hash) VALUES(?1,?2)");
  PREP(pending_del, "DELETE FROM pending WHERE id=?1");
  PREP(reserve, readonly ? "SELECT id FROM pending WHERE due<=?1 ORDER BY due,id LIMIT ?2" :
    "SELECT id FROM pending WHERE NOT EXISTS(SELECT 1 FROM temp.request_leases l WHERE l.id=pending.id AND l.due>?1) ORDER BY id LIMIT ?2");
  PREP(lease, readonly ? "UPDATE pending SET due=?2 WHERE id=?1" :
    "INSERT INTO temp.request_leases VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET due=excluded.due");
  PREP(pending_ready, readonly ? "SELECT 1 FROM pending WHERE due<=?1 LIMIT 1" :
    "SELECT 1 FROM pending WHERE NOT EXISTS(SELECT 1 FROM temp.request_leases l WHERE l.id=pending.id AND l.due>?1) LIMIT 1");
  PREP(pending_release, readonly ? "UPDATE pending SET due=0 WHERE id=?1" : "DELETE FROM temp.request_leases WHERE id=?1");
  PREP(meta_get, "SELECT value FROM metadata WHERE key=?1");
  PREP(meta_put, "INSERT INTO metadata VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value");
  PREP(stats, "UPDATE counters SET nodes=?1,leaves=?2,bytes=?3,pending=?4 WHERE id=1");
#undef PREP
  if(!s->metadata_only && !prepare_view(s)){close_store(s);return fail(NULL,"invalid state view index");}
  while (atomic_flag_test_and_set_explicit(&class_lock, memory_order_acquire)) {}
  if (!store_class) store_class = lean_register_external_class(close_store, no_children);
  atomic_flag_clear_explicit(&class_lock, memory_order_release);
  if(s->worker_owned){
    atomic_init(&s->owned_refs,2);s->owned_registered=1;
    s->owned_next=owned_stores;owned_stores=s;
  }
  return lean_io_result_mk_ok(lean_alloc_external(store_class, s));
}
#include "node_view.inc"
#include "node_scope.inc"
LEAN_EXPORT lean_obj_res lx_store_open(b_lean_obj_arg path, uint64_t max_bytes, lean_obj_arg w) {
  return open_store(path, max_bytes, 0, 0, w);
}
LEAN_EXPORT lean_obj_res lx_store_open_backend(b_lean_obj_arg path,uint64_t max_bytes,uint8_t backend,lean_obj_arg w) {
  return open_store(path,max_bytes,0,backend,w);
}
LEAN_EXPORT lean_obj_res lx_store_backend(b_lean_obj_arg a,lean_obj_arg w) {
  (void)w;STORE(a);
  if(s->metadata_only){
    sqlite3_stmt *q=NULL;int nudb=0;
    if(sqlite3_prepare_v2(s->db,"SELECT backend FROM node_storage WHERE id=1",-1,&q,NULL)==SQLITE_OK && sqlite3_step(q)==SQLITE_ROW){
      const unsigned char *backend=sqlite3_column_text(q,0);nudb=backend && !strcmp((const char*)backend,"nudb-v1");
    }
    sqlite3_finalize(q);return lean_io_result_mk_ok(lean_mk_string(nudb?"nudb":"sqlite"));
  }
  return lean_io_result_mk_ok(lean_mk_string(s->nudb?"nudb":"sqlite"));
}
LEAN_EXPORT lean_obj_res lx_store_nudb_available(lean_obj_arg w) {
  (void)w;return lean_io_result_mk_ok(lean_box(lx_nudb_available()));
}
LEAN_EXPORT lean_obj_res lx_store_disk_bytes(b_lean_obj_arg a,lean_obj_arg w) {
  (void)w;STORE(a);uint64_t bytes=0,nodes=0;struct stat info;
  if(stat(s->path,&info))return fail(s,"database size unavailable");
  bytes=(uint64_t)info.st_size;
  for(int i=0;i<2;i++){
    size_t size=strlen(s->path)+5;char *sidecar=malloc(size);
    if(!sidecar)return fail(s,"size allocation failed");
    snprintf(sidecar,size,"%s%s",s->path,i?"-shm":"-wal");
    if(!stat(sidecar,&info))bytes+=(uint64_t)info.st_size;
    free(sidecar);
  }
  if(s->nudb && !lx_nudb_bytes(s->nudb,&nodes))return nudb_fail(s,"node generation size");
  return lean_io_result_mk_ok(lean_box_uint64(bytes+nodes));
}
LEAN_EXPORT lean_obj_res lx_store_worker_enter(lean_obj_arg w) {
  (void)w;on_storage_worker=1;return ok();
}
LEAN_EXPORT lean_obj_res lx_store_worker_leave(lean_obj_arg w) {
  (void)w;
  while(owned_stores){
    store *s=owned_stores;owned_stores=s->owned_next;
    release_handles(s);
    if(atomic_fetch_sub(&s->owned_refs,1)==1)free(s);
  }
  on_storage_worker=0;return ok();
}
LEAN_EXPORT lean_obj_res lx_store_open_readonly(b_lean_obj_arg path, uint64_t max_bytes, lean_obj_arg w) {
  return open_store(path, max_bytes, 1, 0, w);
}
LEAN_EXPORT lean_obj_res lx_store_open_metadata(b_lean_obj_arg path, uint64_t max_bytes, lean_obj_arg w) {
  return open_store(path, max_bytes, 2, 0, w);
}
LEAN_EXPORT lean_obj_res lx_store_publish_clone(b_lean_obj_arg source,b_lean_obj_arg target,lean_obj_arg w) {
  (void)w;const char *from=lean_string_cstr(source),*to=lean_string_cstr(target);
  /* Payload and SQLite handles are closed/checkpointed by the caller. Persist
     their directory entries before publishing the containing bundle. */
  int source_fd=open(from,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
  int source_synced=source_fd>=0 && fsync(source_fd)==0;if(source_fd>=0)close(source_fd);
  if(!source_synced)return fail(NULL,"bundle staging directory sync failed");
  const char *fault=getenv("LEANXRPL_STORAGE_TEST_FAULT");
  if(fault && !strcmp(fault,"bundle-before-publish"))_exit(89);

#ifdef __APPLE__
  if(renamex_np(from,to,RENAME_EXCL))return fail(NULL,"clone destination exists or publication failed");
#elif defined(__linux__) && defined(SYS_renameat2)
  if(syscall(SYS_renameat2,AT_FDCWD,from,AT_FDCWD,to,1))return fail(NULL,"clone destination exists or publication failed");
#else
  struct stat exists;if(lstat(to,&exists)==0 || rename(from,to))return fail(NULL,"clone destination exists or publication failed");
#endif
  char *parent=strdup(to);if(!parent)return fail(NULL,"clone parent allocation failed");
  char *slash=strrchr(parent,'/');if(slash){if(slash==parent)slash[1]=0;else *slash=0;}else{free(parent);parent=strdup(".");}
  if(!parent)return fail(NULL,"clone parent allocation failed");
  int fd=open(parent,O_RDONLY|O_DIRECTORY);free(parent);
  int synced=fd>=0 && fsync(fd)==0;if(fd>=0)close(fd);
  if(synced && fault && !strcmp(fault,"bundle-after-publish"))_exit(90);
  return synced?ok():fail(NULL,"clone parent directory sync failed");
}
LEAN_EXPORT lean_obj_res lx_store_begin(b_lean_obj_arg a, lean_obj_arg w) {
  (void)w; WRITE_STORE(a);
  if (s->transaction || !sql(s,"BEGIN IMMEDIATE")) return fail(s,"begin failed");
  memcpy(s->saved,s->counts,sizeof s->counts);
  memcpy(s->global_saved,s->global_counts,sizeof s->global_counts);
  s->transaction=1; return ok();
}
LEAN_EXPORT lean_obj_res lx_store_commit(b_lean_obj_arg a, lean_obj_arg w) {
  (void)w; WRITE_STORE(a);
  if (!transaction_active(s)) return fail(s,"no transaction");
  for(int i=0;i<4;i++) sqlite3_bind_int64(s->stats,i+1,s->scoped?s->global_counts[i]:s->counts[i]);
  int rc=sqlite3_step(s->stats); reset(s->stats);
  if(rc!=SQLITE_DONE)return fail(s,"counter commit failed");
  if(s->scoped){
    for(int i=0;i<4;i++)sqlite3_bind_int64(s->scope_stats,i+1,s->counts[i]);
    rc=sqlite3_step(s->scope_stats);reset(s->scope_stats);
    if(rc!=SQLITE_DONE)return fail(s,"scoped counter commit failed");
  }
  if(s->nudb){
    uint64_t budget;
    if(!node_budget(s,&budget))return fail(s,"metadata allocation limit");
    if(!lx_nudb_flush(s->nudb,budget))return nudb_fail(s,"flush before metadata commit");
    const char *fault=getenv("LEANXRPL_STORAGE_TEST_FAULT");
    if(fault && !strcmp(fault,"after-node-flush"))_exit(86);
  }
  if (!sql(s,"COMMIT")) return fail(s,"commit failed");
  s->transaction=0; return ok();
}
LEAN_EXPORT lean_obj_res lx_store_rollback(b_lean_obj_arg a, lean_obj_arg w) {
  (void)w; WRITE_STORE(a);
  if (s->transaction) {
    /* SQLITE_FULL/IOERR can automatically roll back the transaction. */
    if (!sqlite3_get_autocommit(s->db) && !sql(s,"ROLLBACK")) return fail(s,"rollback failed");
    memcpy(s->counts,s->saved,sizeof s->counts); s->transaction=0;
    memcpy(s->global_counts,s->global_saved,sizeof s->global_counts);
  }
  return ok();
}
LEAN_EXPORT lean_obj_res lx_store_close(b_lean_obj_arg a, lean_obj_arg w) {
  (void)w; STORE(a);
  if (s->readonly) return ok();
  if (s->transaction) return fail(s,"close during transaction");
  /* Retained roots may be read concurrently from this same shared catalog.
     Its WAL is already durable; never wait for those readers to release it. */
  if (sqlite3_wal_checkpoint_v2(s->db,NULL,s->scoped?SQLITE_CHECKPOINT_PASSIVE:SQLITE_CHECKPOINT_TRUNCATE,NULL,NULL)!=SQLITE_OK) return fail(s,"checkpoint failed");
  /* Finalization is handled by Lean's external-object finalizer. */
  return ok();
}
LEAN_EXPORT lean_obj_res lx_store_get(b_lean_obj_arg a, b_lean_obj_arg hash, lean_obj_arg w) {
  (void)w; STORE(a);
  if(s->metadata_only)return fail(s,"metadata-only handle cannot read nodes");
  if(s->nudb){
    if(lean_sarray_size(hash)!=32)return fail(s,"invalid node hash");
    unsigned char *data=NULL;size_t size=0;
    int found=read_node(s,lean_sarray_cptr(hash),&data,&size,NULL);
    if(found<0)return fail(NULL,s->node_error);
    lean_object *b=blob(data,size);free(data);return lean_io_result_mk_ok(b);
  }
  bind_blob(s->get,1,hash);
  int rc=sqlite3_step(s->get);
  if (rc!=SQLITE_ROW && rc!=SQLITE_DONE) { reset(s->get); return fail(s,"read failed"); }
  lean_object *b=rc==SQLITE_ROW ? blob(sqlite3_column_blob(s->get,0),sqlite3_column_bytes(s->get,0)) : blob(NULL,0);
  reset(s->get); return lean_io_result_mk_ok(b);
}
LEAN_EXPORT lean_obj_res lx_store_put(b_lean_obj_arg a, b_lean_obj_arg hash, b_lean_obj_arg wire, uint8_t leaf, lean_obj_arg w) {
  (void)w; WRITE_STORE(a);
  if (!transaction_active(s) || lean_sarray_size(hash)!=32 || lean_sarray_size(wire)>2097152) return fail(s,"invalid put");
  if(s->nudb){
    /* NuDB already detects duplicates. Only those need a catalog lookup;
       new nodes avoid a redundant random SQLite index traversal. Payloads
       still precede catalog insertion, including caught native failures. */
    uint64_t budget=s->max_bytes>s->sqlite_bytes?s->max_bytes-s->sqlite_bytes:0;
    int inserted=lx_nudb_put_new(s->nudb,lean_sarray_cptr(hash),lean_sarray_cptr(wire),lean_sarray_size(wire),budget);
    if(!inserted)return nudb_fail(s,"node insert");
    if(inserted==2) {
      bind_blob(s->get,1,hash);int existing=sqlite3_step(s->get);reset(s->get);
      if(existing==SQLITE_ROW)return ok();
      if(existing!=SQLITE_DONE)return fail(s,"node catalog lookup failed");
      /* An orphan from an uncommitted attempt is adopted only after comparing
         its stored bytes, just as on the original insertion path. */
      if(!lx_nudb_put(s->nudb,lean_sarray_cptr(hash),lean_sarray_cptr(wire),lean_sarray_size(wire),budget))
        return nudb_fail(s,"orphan node insert");
    }
  }
  bind_blob(s->put,1,hash);
  if(s->nudb){sqlite3_bind_int64(s->put,2,(sqlite3_int64)lean_sarray_size(wire));sqlite3_bind_int(s->put,3,!!leaf);}
  else bind_blob(s->put,2,wire);
  int rc=sqlite3_step(s->put), added=sqlite3_changes(s->db); reset(s->put);
  if(rc!=SQLITE_DONE) return fail(s,"write failed");
  if(added) { s->counts[0]++; s->counts[1]+=!!leaf; s->counts[2]+=(int64_t)lean_sarray_size(wire); }
  if(added && s->scoped){s->global_counts[0]++;s->global_counts[1]+=!!leaf;s->global_counts[2]+=(int64_t)lean_sarray_size(wire);}
  return ok();
}
LEAN_EXPORT lean_obj_res lx_store_pending_get(b_lean_obj_arg a, b_lean_obj_arg id, lean_obj_arg w) {
  (void)w; STORE(a); bind_blob(s->pending_get,1,id);
  int rc=sqlite3_step(s->pending_get);
  if(rc!=SQLITE_ROW && rc!=SQLITE_DONE) { reset(s->pending_get); return fail(s,"frontier read failed"); }
  lean_object *b=rc==SQLITE_ROW ? blob(sqlite3_column_blob(s->pending_get,0),sqlite3_column_bytes(s->pending_get,0)) : blob(NULL,0);
  reset(s->pending_get); return lean_io_result_mk_ok(b);
}
LEAN_EXPORT lean_obj_res lx_store_pending_add(b_lean_obj_arg a, b_lean_obj_arg id, b_lean_obj_arg hash, lean_obj_arg w) {
  (void)w; WRITE_STORE(a);
  if(!transaction_active(s) || lean_sarray_size(id)!=33 || lean_sarray_size(hash)!=32) return fail(s,"invalid frontier insert");
  bind_blob(s->pending_add,1,id); bind_blob(s->pending_add,2,hash);
  int rc=sqlite3_step(s->pending_add),added=sqlite3_changes(s->db); reset(s->pending_add);
  if(rc!=SQLITE_DONE) return fail(s,"frontier insert failed");
  if(!added) {
    bind_blob(s->pending_get,1,id); rc=sqlite3_step(s->pending_get);
    int same=rc==SQLITE_ROW && sqlite3_column_bytes(s->pending_get,0)==32 && !memcmp(sqlite3_column_blob(s->pending_get,0),lean_sarray_cptr(hash),32);
    reset(s->pending_get); if(!same) return fail(s,"conflicting frontier commitment");
  }
  s->counts[3]+=added; return ok();
}
LEAN_EXPORT lean_obj_res lx_store_pending_del(b_lean_obj_arg a, b_lean_obj_arg id, lean_obj_arg w) {
  (void)w; WRITE_STORE(a); if(!transaction_active(s)) return fail(s,"delete outside transaction");
  bind_blob(s->pending_del,1,id); int rc=sqlite3_step(s->pending_del),removed=sqlite3_changes(s->db); reset(s->pending_del);
  if(rc!=SQLITE_DONE) return fail(s,"frontier delete failed");
  bind_blob(s->pending_release,1,id);rc=sqlite3_step(s->pending_release);reset(s->pending_release);
  if(rc!=SQLITE_DONE)return fail(s,"frontier lease delete failed");
  s->counts[3]-=removed; return ok();
}
LEAN_EXPORT lean_obj_res lx_store_reserve(b_lean_obj_arg a, uint64_t now, uint32_t limit, lean_obj_arg w) {
  (void)w; WRITE_STORE(a); if(!transaction_active(s) || limit>256) return fail(s,"invalid reservation");
  unsigned char ids[256*33]; size_t n=0;
  sqlite3_bind_int64(s->reserve,1,(sqlite3_int64)now); sqlite3_bind_int(s->reserve,2,(int)limit);
  int rc;
  while((rc=sqlite3_step(s->reserve))==SQLITE_ROW) {
    if(sqlite3_column_bytes(s->reserve,0)!=33 || n>=limit) { reset(s->reserve); return fail(s,"invalid frontier record"); }
    memcpy(ids+n*33,sqlite3_column_blob(s->reserve,0),33); n++;
  }
  reset(s->reserve); if(rc!=SQLITE_DONE) return fail(s,"reservation failed");
  for(size_t i=0;i<n;i++) {
    sqlite3_bind_blob(s->lease,1,ids+i*33,33,SQLITE_TRANSIENT);
    sqlite3_bind_int64(s->lease,2,(sqlite3_int64)(now+10000));
    rc=sqlite3_step(s->lease); reset(s->lease);
    if(rc!=SQLITE_DONE) return fail(s,"lease failed");
  }
  return lean_io_result_mk_ok(blob(ids,n*33));
}
LEAN_EXPORT lean_obj_res lx_store_pending_ready(b_lean_obj_arg a, uint64_t now, lean_obj_arg w) {
  (void)w; STORE(a);
  sqlite3_bind_int64(s->pending_ready,1,(sqlite3_int64)now);
  int rc=sqlite3_step(s->pending_ready); reset(s->pending_ready);
  if(rc!=SQLITE_ROW && rc!=SQLITE_DONE) return fail(s,"frontier readiness failed");
  return lean_io_result_mk_ok(lean_box(rc==SQLITE_ROW));
}
LEAN_EXPORT lean_obj_res lx_store_pending_release(b_lean_obj_arg a, b_lean_obj_arg ids, lean_obj_arg w) {
  (void)w; WRITE_STORE(a);
  size_t n=lean_sarray_size(ids);
  if(!transaction_active(s) || n%33 || n>256*33) return fail(s,"invalid lease release");
  for(size_t i=0;i<n;i+=33) {
    sqlite3_bind_blob(s->pending_release,1,lean_sarray_cptr(ids)+i,33,SQLITE_TRANSIENT);
    int rc=sqlite3_step(s->pending_release); reset(s->pending_release);
    if(rc!=SQLITE_DONE) return fail(s,"lease release failed");
  }
  return ok();
}
LEAN_EXPORT lean_obj_res lx_store_meta_get(b_lean_obj_arg a, b_lean_obj_arg key, lean_obj_arg w) {
  (void)w; STORE(a); sqlite3_bind_text(s->meta_get,1,lean_string_cstr(key),-1,SQLITE_TRANSIENT);
  int rc=sqlite3_step(s->meta_get);
  if(rc!=SQLITE_ROW && rc!=SQLITE_DONE) { reset(s->meta_get); return fail(s,"metadata read failed"); }
  lean_object *text=lean_mk_string(rc==SQLITE_ROW ? (const char *)sqlite3_column_text(s->meta_get,0) : "");
  reset(s->meta_get); return lean_io_result_mk_ok(text);
}
/* Indexed prefix range over the small ledger archive, never the node catalog. */
LEAN_EXPORT lean_obj_res lx_store_ledger_indices(b_lean_obj_arg a, lean_obj_arg w) {
  (void)w; STORE(a); sqlite3_stmt *q=NULL;
  if(sqlite3_prepare_v2(s->db,"SELECT substr(key,13) FROM metadata WHERE key>='sync_ledger:' AND key<'sync_ledger;'",-1,&q,NULL)!=SQLITE_OK)
    return fail(s,"ledger archive enumeration failed");
  size_t used=0,capacity=4096; char *buf=malloc(capacity); int rc;
  if(!buf){sqlite3_finalize(q);return fail(s,"ledger archive allocation failed");}
  while((rc=sqlite3_step(q))==SQLITE_ROW){
    const char *part=(const char *)sqlite3_column_text(q,0);size_t n=strlen(part);
    if(used+n+2>capacity){
      size_t next=capacity*2+used+n+2;char *grown=realloc(buf,next);
      if(!grown){free(buf);sqlite3_finalize(q);return fail(s,"ledger archive allocation failed");}
      buf=grown;capacity=next;
    }
    memcpy(buf+used,part,n);used+=n;buf[used++]='\n';
  }
  sqlite3_finalize(q);
  if(rc!=SQLITE_DONE){free(buf);return fail(s,"ledger archive enumeration failed");}
  buf[used]=0;lean_object *out=lean_mk_string(buf);free(buf);
  return lean_io_result_mk_ok(out);
}
LEAN_EXPORT lean_obj_res lx_store_meta_put(b_lean_obj_arg a, b_lean_obj_arg key, b_lean_obj_arg value, lean_obj_arg w) {
  (void)w; WRITE_STORE(a); if(!transaction_active(s)) return fail(s,"metadata outside transaction");
  sqlite3_bind_text(s->meta_put,1,lean_string_cstr(key),-1,SQLITE_TRANSIENT);
  sqlite3_bind_text(s->meta_put,2,lean_string_cstr(value),-1,SQLITE_TRANSIENT);
  int rc=sqlite3_step(s->meta_put); reset(s->meta_put);
  return rc==SQLITE_DONE ? ok() : fail(s,"metadata write failed");
}
LEAN_EXPORT lean_obj_res lx_store_stats(b_lean_obj_arg a, lean_obj_arg w) {
  (void)w; STORE(a); unsigned char out[32];
  for(int i=0;i<4;i++) for(int j=0;j<8;j++) out[i*8+j]=(unsigned char)((uint64_t)s->counts[i]>>(56-j*8));
  return lean_io_result_mk_ok(blob(out,sizeof out));
}

/* Sync-only schema: opening an immutable snapshot does not add these tables. */
LEAN_EXPORT lean_obj_res lx_store_sync_init(b_lean_obj_arg a, lean_obj_arg w) {
  (void)w; WRITE_STORE(a);
  if(s->transaction || s->closed_has) return fail(s,"sync already initialized or in transaction");
  if(!sql(s,"CREATE TABLE IF NOT EXISTS sync_closed(hash BLOB NOT NULL CHECK(length(hash)=32), id BLOB NOT NULL CHECK(length(id)=33), PRIMARY KEY(hash,id)) WITHOUT ROWID;"
      "CREATE TABLE IF NOT EXISTS sync_waiting(id BLOB PRIMARY KEY CHECK(length(id)=33), hash BLOB NOT NULL CHECK(length(hash)=32)) WITHOUT ROWID;"
      "CREATE TABLE IF NOT EXISTS sync_previous(id BLOB PRIMARY KEY CHECK(length(id)=33), hash BLOB NOT NULL CHECK(length(hash)=32)) WITHOUT ROWID;")) return fail(s,"sync initialize failed");
#define SYNC_PREP(field,q) if(sqlite3_prepare_v2(s->db,q,-1,&s->field,NULL)!=SQLITE_OK) return fail(s,"sync prepare failed")
  SYNC_PREP(closed_has,"SELECT 1 FROM sync_closed WHERE hash=?1 AND id=?2");
  SYNC_PREP(closed_add,"INSERT OR IGNORE INTO sync_closed VALUES(?1,?2)");
  SYNC_PREP(waiting_get,"SELECT hash FROM sync_waiting WHERE id=?1");
  SYNC_PREP(waiting_put,"INSERT INTO sync_waiting VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET hash=excluded.hash");
  SYNC_PREP(waiting_del,"DELETE FROM sync_waiting WHERE id=?1");
  SYNC_PREP(previous_get,"SELECT hash FROM sync_previous WHERE id=?1");
  SYNC_PREP(previous_put,"INSERT OR IGNORE INTO sync_previous VALUES(?1,?2)");
#undef SYNC_PREP
  return ok();
}
LEAN_EXPORT lean_obj_res lx_store_sync_closed(b_lean_obj_arg a, b_lean_obj_arg hash, b_lean_obj_arg id, lean_obj_arg w) {
  (void)w; WRITE_STORE(a); if(!s->closed_has) return fail(s,"sync not initialized");
  bind_blob(s->closed_has,1,hash); bind_blob(s->closed_has,2,id);
  int rc=sqlite3_step(s->closed_has); reset(s->closed_has);
  if(rc!=SQLITE_ROW && rc!=SQLITE_DONE) return fail(s,"closed read failed");
  return lean_io_result_mk_ok(lean_box(rc==SQLITE_ROW));
}
LEAN_EXPORT lean_obj_res lx_store_sync_mark(b_lean_obj_arg a, b_lean_obj_arg hash, b_lean_obj_arg id, lean_obj_arg w) {
  (void)w; WRITE_STORE(a); if(!transaction_active(s) || !s->closed_add) return fail(s,"sync mark outside transaction");
  bind_blob(s->closed_add,1,hash); bind_blob(s->closed_add,2,id);
  int rc=sqlite3_step(s->closed_add); reset(s->closed_add);
  return rc==SQLITE_DONE ? ok() : fail(s,"closed write failed");
}
LEAN_EXPORT lean_obj_res lx_store_sync_wait_get(b_lean_obj_arg a, b_lean_obj_arg id, lean_obj_arg w) {
  (void)w; WRITE_STORE(a); if(!s->waiting_get) return fail(s,"sync not initialized");
  bind_blob(s->waiting_get,1,id); int rc=sqlite3_step(s->waiting_get);
  if(rc!=SQLITE_ROW && rc!=SQLITE_DONE){reset(s->waiting_get);return fail(s,"waiting read failed");}
  lean_object *out=rc==SQLITE_ROW?blob(sqlite3_column_blob(s->waiting_get,0),sqlite3_column_bytes(s->waiting_get,0)):blob(NULL,0);
  reset(s->waiting_get); return lean_io_result_mk_ok(out);
}
LEAN_EXPORT lean_obj_res lx_store_sync_wait_put(b_lean_obj_arg a, b_lean_obj_arg id, b_lean_obj_arg hash, lean_obj_arg w) {
  (void)w; WRITE_STORE(a); if(!transaction_active(s) || !s->waiting_put) return fail(s,"waiting write outside transaction");
  bind_blob(s->waiting_put,1,id); bind_blob(s->waiting_put,2,hash);
  int rc=sqlite3_step(s->waiting_put);reset(s->waiting_put);
  return rc==SQLITE_DONE?ok():fail(s,"waiting write failed");
}
LEAN_EXPORT lean_obj_res lx_store_sync_wait_del(b_lean_obj_arg a, b_lean_obj_arg id, lean_obj_arg w) {
  (void)w; WRITE_STORE(a); if(!transaction_active(s) || !s->waiting_del) return fail(s,"waiting delete outside transaction");
  bind_blob(s->waiting_del,1,id);int rc=sqlite3_step(s->waiting_del);reset(s->waiting_del);
  return rc==SQLITE_DONE?ok():fail(s,"waiting delete failed");
}
LEAN_EXPORT lean_obj_res lx_store_sync_reset(b_lean_obj_arg a, lean_obj_arg w) {
  (void)w; WRITE_STORE(a); if(!transaction_active(s) || !s->closed_has) return fail(s,"sync reset outside transaction");
  if(!sql(s,"DELETE FROM pending; DELETE FROM sync_waiting;")) return fail(s,"sync reset failed");
  s->counts[3]=0; return ok();
}
LEAN_EXPORT lean_obj_res lx_store_sync_closed_reset(b_lean_obj_arg a, lean_obj_arg w) {
  (void)w;WRITE_STORE(a);
  if(!transaction_active(s)) return fail(s,"closure reset outside transaction");
  return sql(s,"DELETE FROM sync_closed")?ok():fail(s,"closure reset failed");
}
LEAN_EXPORT lean_obj_res lx_store_sync_previous(b_lean_obj_arg a, b_lean_obj_arg id, lean_obj_arg w) {
  (void)w; WRITE_STORE(a); if(!s->previous_get) return fail(s,"sync not initialized");
  bind_blob(s->previous_get,1,id); int rc=sqlite3_step(s->previous_get);
  if(rc!=SQLITE_ROW && rc!=SQLITE_DONE){reset(s->previous_get);return fail(s,"previous read failed");}
  lean_object *out=rc==SQLITE_ROW?blob(sqlite3_column_blob(s->previous_get,0),sqlite3_column_bytes(s->previous_get,0)):blob(NULL,0);
  reset(s->previous_get);return lean_io_result_mk_ok(out);
}
LEAN_EXPORT lean_obj_res lx_store_sync_previous_put(b_lean_obj_arg a, b_lean_obj_arg id, b_lean_obj_arg hash, lean_obj_arg w) {
  (void)w; WRITE_STORE(a);if(!transaction_active(s) || !s->previous_put) return fail(s,"previous write outside transaction");
  bind_blob(s->previous_put,1,id);bind_blob(s->previous_put,2,hash);
  int rc=sqlite3_step(s->previous_put),added=sqlite3_changes(s->db);reset(s->previous_put);
  if(rc!=SQLITE_DONE)return fail(s,"previous write failed");
  if(!added){
    bind_blob(s->previous_get,1,id);rc=sqlite3_step(s->previous_get);
    int same=rc==SQLITE_ROW && sqlite3_column_bytes(s->previous_get,0)==32 &&
      lean_sarray_size(hash)==32 && !memcmp(sqlite3_column_blob(s->previous_get,0),lean_sarray_cptr(hash),32);
    reset(s->previous_get);if(!same)return fail(s,"conflicting previous-tree reference");
  }
  return ok();
}
LEAN_EXPORT lean_obj_res lx_store_sync_previous_reset(b_lean_obj_arg a, lean_obj_arg w) {
  (void)w; WRITE_STORE(a);if(!transaction_active(s) || !s->previous_get) return fail(s,"previous reset outside transaction");
  return sql(s,"DELETE FROM sync_previous")?ok():fail(s,"previous reset failed");
}

#include "history.inc"
#include "node_compact.inc"
#include "node_export.inc"

LEAN_EXPORT lean_obj_res lx_store_dispose(b_lean_obj_arg a,lean_obj_arg w) {
  (void)w;store *s=lean_get_external_data(a);
  if(s->db && s->worker_owned && !pthread_equal(s->owner,pthread_self()))return fail(NULL,"database disposed outside storage worker");
  if(s->transaction)return fail(s,"dispose during transaction");
  release_handles(s);return ok();
}
