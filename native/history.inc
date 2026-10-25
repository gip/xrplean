/* Managed state persistence. Hashing, decoding, authentication and replay stay in Lean. */
static int hprepare(store *s, int i, const char *q) {
  return s->history[i] || sqlite3_prepare_v2(s->db,q,-1,&s->history[i],NULL)==SQLITE_OK;
}
static int hstep(sqlite3_stmt *q) { int rc=sqlite3_step(q);reset(q);return rc==SQLITE_DONE; }
static int hbindstep(store *s,int i,const void *hash) {
  sqlite3_bind_blob(s->history[i],1,hash,32,SQLITE_TRANSIENT);return hstep(s->history[i]);
}
LEAN_EXPORT lean_obj_res lx_history_init(b_lean_obj_arg a, lean_obj_arg w) {
  (void)w;WRITE_STORE(a);
  if(!sql(s,"CREATE TABLE IF NOT EXISTS history_nodes(hash BLOB PRIMARY KEY CHECK(length(hash)=32),refs INTEGER NOT NULL CHECK(refs>=0),registered INTEGER NOT NULL) WITHOUT ROWID;"
      "CREATE TABLE IF NOT EXISTS history_edges(parent BLOB,ordinal INTEGER,child BLOB NOT NULL,PRIMARY KEY(parent,ordinal)) WITHOUT ROWID;"
      "CREATE TABLE IF NOT EXISTS history_gc(hash BLOB PRIMARY KEY) WITHOUT ROWID;"
      "CREATE TABLE IF NOT EXISTS history_roots(sequence INTEGER PRIMARY KEY,root BLOB NOT NULL,record TEXT NOT NULL);")) return fail(s,"history schema failed");
  const char *qs[16]={
    "INSERT OR IGNORE INTO history_nodes VALUES(?1,0,0)",
    "SELECT registered,refs FROM history_nodes WHERE hash=?1",
    "UPDATE history_nodes SET registered=1 WHERE hash=?1",
    "INSERT INTO history_nodes VALUES(?1,1,0) ON CONFLICT(hash) DO UPDATE SET refs=refs+1",
    "INSERT INTO history_edges VALUES(?1,?2,?3)",
    "INSERT OR IGNORE INTO history_gc VALUES(?1)",
    "UPDATE history_nodes SET refs=refs-1 WHERE hash=?1 AND refs>0",
    "SELECT hash FROM history_gc LIMIT 1",
    "DELETE FROM history_gc WHERE hash=?1",
    "SELECT child FROM history_edges WHERE parent=?1 ORDER BY ordinal",
    s->nudb?"DELETE FROM node_catalog WHERE hash=?1":"DELETE FROM nodes WHERE hash=?1",
    "DELETE FROM history_nodes WHERE hash=?1",
    "DELETE FROM history_edges WHERE parent=?1",
    "INSERT INTO history_roots VALUES(?1,?2,?3)",
    "SELECT sequence,root FROM history_roots WHERE sequence<?1 ORDER BY sequence",
    "DELETE FROM history_roots WHERE sequence=?1"};
  for(int i=0;i<16;i++) if(!hprepare(s,i,qs[i])) return fail(s,"history prepare failed");
  return ok();
}
LEAN_EXPORT lean_obj_res lx_history_register(b_lean_obj_arg a,b_lean_obj_arg hash,b_lean_obj_arg children,lean_obj_arg w) {
  (void)w;WRITE_STORE(a);size_t n=lean_sarray_size(children);
  if(!transaction_active(s) || !s->history[0] || lean_sarray_size(hash)!=32 || n%32 || n>512) return fail(s,"invalid history registration");
  const void *h=lean_sarray_cptr(hash);
  if(!hbindstep(s,0,h)) return fail(s,"history insert failed");
  sqlite3_bind_blob(s->history[1],1,h,32,SQLITE_TRANSIENT);
  int rc=sqlite3_step(s->history[1]),registered=rc==SQLITE_ROW?sqlite3_column_int(s->history[1],0):0;reset(s->history[1]);
  if(rc!=SQLITE_ROW) return fail(s,"history reference missing");
  if(registered) return ok();
  if(!hbindstep(s,2,h) || !hbindstep(s,5,h)) return fail(s,"history registration failed");
  for(size_t i=0;i<n;i+=32) {
    const void *child=lean_sarray_cptr(children)+i;
    if(!hbindstep(s,3,child)) return fail(s,"history child reference failed");
    sqlite3_bind_blob(s->history[4],1,h,32,SQLITE_TRANSIENT);sqlite3_bind_int(s->history[4],2,(int)(i/32));
    sqlite3_bind_blob(s->history[4],3,child,32,SQLITE_TRANSIENT);
    if(!hstep(s->history[4])) return fail(s,"history edge failed");
  }
  return ok();
}
static int hrelease(store *s,const void *h) {
  if(!hbindstep(s,6,h) || sqlite3_changes(s->db)!=1) return 0;
  return hbindstep(s,5,h);
}
static int hzero(const unsigned char *h) { for(int i=0;i<32;i++)if(h[i])return 0;return 1; }
LEAN_EXPORT lean_obj_res lx_history_publish(b_lean_obj_arg a,uint32_t seq,b_lean_obj_arg root,b_lean_obj_arg record,uint32_t keep,lean_obj_arg w) {
  (void)w;WRITE_STORE(a);
  if(!transaction_active(s) || !s->history[0] || !seq || !keep || keep>100000 || lean_sarray_size(root)!=32) return fail(s,"invalid history publication");
  const unsigned char *h=lean_sarray_cptr(root);
  sqlite3_bind_int64(s->history[13],1,seq);bind_blob(s->history[13],2,root);
  sqlite3_bind_text(s->history[13],3,lean_string_cstr(record),-1,SQLITE_TRANSIENT);
  if(!hstep(s->history[13])) return fail(s,"history ledger conflict");
  if(!hzero(h) && !hbindstep(s,3,h)) return fail(s,"history root pin failed");
  /* Keep one extra preceding root as the internal replay anchor. */
  sqlite3_bind_int64(s->history[14],1,seq>keep?seq-keep:0);
  int rc;
  while((rc=sqlite3_step(s->history[14]))==SQLITE_ROW) {
    int64_t old=sqlite3_column_int64(s->history[14],0);
    const unsigned char *r=sqlite3_column_blob(s->history[14],1);
    if(sqlite3_column_bytes(s->history[14],1)!=32 || (!hzero(r)&&!hrelease(s,r))) {reset(s->history[14]);return fail(s,"history root release failed");}
    sqlite3_bind_int64(s->history[15],1,old);
    if(!hstep(s->history[15])) {reset(s->history[14]);return fail(s,"history pruning failed");}
  }
  reset(s->history[14]);return rc==SQLITE_DONE?ok():fail(s,"history pruning read failed");
}
LEAN_EXPORT lean_obj_res lx_history_read(b_lean_obj_arg a,uint32_t seq,lean_obj_arg w) {
  (void)w;STORE(a);sqlite3_stmt *q=NULL;
  if(sqlite3_prepare_v2(s->db,"SELECT record FROM history_roots WHERE sequence=?1",-1,&q,NULL)!=SQLITE_OK) return fail(s,"history read failed");
  sqlite3_bind_int64(q,1,seq);int rc=sqlite3_step(q);
  lean_object *out=lean_mk_string(rc==SQLITE_ROW?(const char *)sqlite3_column_text(q,0):"");sqlite3_finalize(q);
  return rc==SQLITE_ROW||rc==SQLITE_DONE?lean_io_result_mk_ok(out):fail(s,"history read failed");
}
LEAN_EXPORT lean_obj_res lx_history_ready(b_lean_obj_arg a,lean_obj_arg w) {
  (void)w;STORE(a);sqlite3_stmt *q=NULL;
  if(sqlite3_prepare_v2(s->db,"SELECT 1 FROM history_nodes WHERE refs>0 AND registered=0 LIMIT 1",-1,&q,NULL)!=SQLITE_OK)return fail(s,"history readiness failed");
  int rc=sqlite3_step(q);sqlite3_finalize(q);
  return rc==SQLITE_DONE||rc==SQLITE_ROW?lean_io_result_mk_ok(lean_box(rc==SQLITE_DONE)):fail(s,"history readiness failed");
}
LEAN_EXPORT lean_obj_res lx_history_gc(b_lean_obj_arg a,uint32_t limit,lean_obj_arg w) {
  (void)w;WRITE_STORE(a);
  if(!transaction_active(s) || !s->history[0] || limit>4096)return fail(s,"invalid history collection");
  uint32_t removed=0;
  for(uint32_t i=0;i<limit;i++) {
    int rc=sqlite3_step(s->history[7]);unsigned char h[32];
    if(rc==SQLITE_DONE){reset(s->history[7]);break;}
    if(rc!=SQLITE_ROW || sqlite3_column_bytes(s->history[7],0)!=32){reset(s->history[7]);return fail(s,"history garbage read failed");}
    memcpy(h,sqlite3_column_blob(s->history[7],0),32);reset(s->history[7]);
    if(!hbindstep(s,8,h))return fail(s,"history garbage dequeue failed");
    sqlite3_bind_blob(s->history[1],1,h,32,SQLITE_TRANSIENT);rc=sqlite3_step(s->history[1]);
    int registered=rc==SQLITE_ROW && sqlite3_column_int(s->history[1],0);
    int collect=rc==SQLITE_ROW && sqlite3_column_int64(s->history[1],1)==0;reset(s->history[1]);
    if(rc!=SQLITE_ROW && rc!=SQLITE_DONE)return fail(s,"history garbage reference failed");
    if(!collect)continue;
    /* A cancelled acquisition can leave an unfetched child placeholder. */
    if(!registered) {
      if(!hbindstep(s,11,h))return fail(s,"history placeholder delete failed");
      continue;
    }
    unsigned char *wire=NULL;size_t n=0;int leaf=0;
    int found=read_node(s,h,&wire,&n,&leaf);free(wire);
    if(found<0)return fail(NULL,s->node_error);
    if(!found||!n)return fail(s,"history garbage node missing");
    sqlite3_bind_blob(s->history[9],1,h,32,SQLITE_TRANSIENT);
    while((rc=sqlite3_step(s->history[9]))==SQLITE_ROW) {
      if(sqlite3_column_bytes(s->history[9],0)!=32 || !hrelease(s,sqlite3_column_blob(s->history[9],0))) {reset(s->history[9]);return fail(s,"history garbage child failed");}
    }
    reset(s->history[9]);
    if(rc!=SQLITE_DONE || !hbindstep(s,12,h) || !hbindstep(s,10,h) || !hbindstep(s,11,h))return fail(s,"history garbage delete failed");
    s->counts[0]--;s->counts[1]-=leaf;s->counts[2]-=(int64_t)n;removed++;
  }
  return lean_io_result_mk_ok(lean_box_uint32(removed));
}
LEAN_EXPORT lean_obj_res lx_store_scan(b_lean_obj_arg a,b_lean_obj_arg after,uint32_t limit,lean_obj_arg w) {
  (void)w;STORE(a);sqlite3_stmt *q=NULL;
  if(s->metadata_only)return fail(s,"metadata-only handle cannot scan nodes");
  if(limit>4096 || (lean_sarray_size(after)!=0&&lean_sarray_size(after)!=32))return fail(s,"invalid scan");
  const char *query=s->nudb?"SELECT hash FROM node_catalog WHERE hash>?1 ORDER BY hash LIMIT ?2":"SELECT hash,wire FROM nodes WHERE hash>?1 ORDER BY hash LIMIT ?2";
  if(sqlite3_prepare_v2(s->db,query,-1,&q,NULL)!=SQLITE_OK)return fail(s,"scan prepare failed");
  bind_blob(q,1,after);sqlite3_bind_int(q,2,limit);
  size_t used=0,capacity=8*1024*1024+2097188;unsigned char *data=malloc(capacity);
  if(!data){sqlite3_finalize(q);return fail(s,"scan allocation failed");}
  int rc;
  while((rc=sqlite3_step(q))==SQLITE_ROW) {
    const unsigned char *hash=sqlite3_column_blob(q,0),*wire=NULL;
    unsigned char *owned=NULL;size_t length=0;
    if(sqlite3_column_bytes(q,0)!=32){free(data);sqlite3_finalize(q);return fail(s,"invalid scan hash");}
    if(s->nudb){
      int found=read_node(s,hash,&owned,&length,NULL);
      if(found<=0){free(owned);free(data);sqlite3_finalize(q);return fail(NULL,found<0?s->node_error:"scan node missing");}
      wire=owned;
    }else{wire=sqlite3_column_blob(q,1);length=(size_t)sqlite3_column_bytes(q,1);}
    if(length==0||length>2097152){free(owned);free(data);sqlite3_finalize(q);return fail(s,"invalid scan node");}
    unsigned n=(unsigned)length;
    memcpy(data+used,hash,32);used+=32;
    for(int k=3;k>=0;k--)data[used++]=(unsigned char)((unsigned)n>>(k*8));
    memcpy(data+used,wire,(size_t)n);used+=(size_t)n;free(owned);
    if(used>=8*1024*1024)break;
  }
  lean_object *out=blob(data,used);free(data);sqlite3_finalize(q);
  return rc==SQLITE_DONE||rc==SQLITE_ROW?lean_io_result_mk_ok(out):fail(s,"scan failed");
}
LEAN_EXPORT lean_obj_res lx_inbox_init(b_lean_obj_arg a,lean_obj_arg w) {
  (void)w;WRITE_STORE(a);
  return sql(s,"CREATE TABLE IF NOT EXISTS exports(sequence INTEGER NOT NULL,hash BLOB PRIMARY KEY CHECK(length(hash)=32),digest BLOB NOT NULL,payload TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'pending',error TEXT NOT NULL DEFAULT '') WITHOUT ROWID; CREATE INDEX IF NOT EXISTS exports_sequence ON exports(sequence);")?ok():fail(s,"inbox schema failed");
}
LEAN_EXPORT lean_obj_res lx_inbox_put(b_lean_obj_arg a,uint32_t seq,b_lean_obj_arg hash,b_lean_obj_arg digest,b_lean_obj_arg payload,lean_obj_arg w) {
  (void)w;WRITE_STORE(a);sqlite3_stmt *q=NULL;
  if(!transaction_active(s) || !seq || lean_sarray_size(hash)!=32 || lean_sarray_size(digest)!=32)return fail(s,"invalid inbox entry");
  if(sqlite3_prepare_v2(s->db,"SELECT sequence,digest FROM exports WHERE hash=?1",-1,&q,NULL)!=SQLITE_OK)return fail(s,"inbox lookup failed");
  bind_blob(q,1,hash);int rc=sqlite3_step(q),same=rc==SQLITE_ROW && sqlite3_column_int64(q,0)==seq && sqlite3_column_bytes(q,1)==32 && !memcmp(sqlite3_column_blob(q,1),lean_sarray_cptr(digest),32);sqlite3_finalize(q);
  if(rc==SQLITE_ROW)return same?ok():fail(s,"export conflict");
  if(rc!=SQLITE_DONE)return fail(s,"inbox lookup failed");
  if(sqlite3_prepare_v2(s->db,"INSERT INTO exports(sequence,hash,digest,payload) VALUES(?1,?2,?3,?4)",-1,&q,NULL)!=SQLITE_OK)return fail(s,"inbox insert failed");
  sqlite3_bind_int64(q,1,seq);bind_blob(q,2,hash);bind_blob(q,3,digest);sqlite3_bind_text(q,4,lean_string_cstr(payload),-1,SQLITE_TRANSIENT);
  int done=hstep(q);sqlite3_finalize(q);return done?ok():fail(s,"inbox insert failed");
}
LEAN_EXPORT lean_obj_res lx_inbox_get(b_lean_obj_arg a,uint32_t seq,b_lean_obj_arg hash,lean_obj_arg w) {
  (void)w;STORE(a);sqlite3_stmt *q=NULL;
  if(sqlite3_prepare_v2(s->db,"SELECT payload FROM exports WHERE sequence=?1 AND hash=?2 AND status!='rejected'",-1,&q,NULL)!=SQLITE_OK)return fail(s,"inbox get failed");
  sqlite3_bind_int64(q,1,seq);bind_blob(q,2,hash);int rc=sqlite3_step(q);lean_object *out=lean_mk_string(rc==SQLITE_ROW?(const char *)sqlite3_column_text(q,0):"");sqlite3_finalize(q);
  return rc==SQLITE_ROW||rc==SQLITE_DONE?lean_io_result_mk_ok(out):fail(s,"inbox get failed");
}
LEAN_EXPORT lean_obj_res lx_inbox_mark(b_lean_obj_arg a,b_lean_obj_arg hash,b_lean_obj_arg status,b_lean_obj_arg error,lean_obj_arg w) {
  (void)w;WRITE_STORE(a);sqlite3_stmt *q=NULL;if(!transaction_active(s))return fail(s,"inbox mark outside transaction");
  if(sqlite3_prepare_v2(s->db,"UPDATE exports SET status=?2,error=?3 WHERE hash=?1",-1,&q,NULL)!=SQLITE_OK)return fail(s,"inbox mark failed");
  bind_blob(q,1,hash);sqlite3_bind_text(q,2,lean_string_cstr(status),-1,SQLITE_TRANSIENT);sqlite3_bind_text(q,3,lean_string_cstr(error),-1,SQLITE_TRANSIENT);
  int done=hstep(q);sqlite3_finalize(q);return done?ok():fail(s,"inbox mark failed");
}
LEAN_EXPORT lean_obj_res lx_inbox_prune(b_lean_obj_arg a,uint32_t before,lean_obj_arg w) {
  (void)w;WRITE_STORE(a);sqlite3_stmt *q=NULL;if(!transaction_active(s))return fail(s,"inbox prune outside transaction");
  if(sqlite3_prepare_v2(s->db,"DELETE FROM exports WHERE sequence<?1",-1,&q,NULL)!=SQLITE_OK)return fail(s,"inbox prune failed");
  sqlite3_bind_int64(q,1,before);int done=hstep(q);sqlite3_finalize(q);
  if(!done)return fail(s,"inbox prune failed");
  const char *queries[]={
    "DELETE FROM metadata WHERE key IN (SELECT 'header:'||substr(key,12) FROM metadata WHERE key GLOB 'header_seq:*' AND CAST(value AS INTEGER)<?1)",
    "DELETE FROM metadata WHERE key GLOB 'header_seq:*' AND CAST(value AS INTEGER)<?1",
    "DELETE FROM metadata WHERE key GLOB 'wanted:*' AND CAST(value AS INTEGER)<?1",
    "DELETE FROM metadata WHERE key GLOB 'certificate:*' AND CAST(substr(key,13) AS INTEGER)<?1"
  };
  for(size_t i=0;i<sizeof queries/sizeof queries[0];i++) {
    if(sqlite3_prepare_v2(s->db,queries[i],-1,&q,NULL)!=SQLITE_OK)return fail(s,"inbox metadata prune failed");
    sqlite3_bind_int64(q,1,before);done=hstep(q);sqlite3_finalize(q);
    if(!done)return fail(s,"inbox metadata prune failed");
  }
  return ok();
}
LEAN_EXPORT lean_obj_res lx_history_garbage_ready(b_lean_obj_arg a,lean_obj_arg w) {
  (void)w;STORE(a);sqlite3_stmt *q=NULL;
  if(sqlite3_prepare_v2(s->db,"SELECT 1 FROM history_gc LIMIT 1",-1,&q,NULL)!=SQLITE_OK)return fail(s,"history garbage readiness failed");
  int rc=sqlite3_step(q);sqlite3_finalize(q);
  return rc==SQLITE_DONE||rc==SQLITE_ROW?lean_io_result_mk_ok(lean_box(rc==SQLITE_ROW)):fail(s,"history garbage readiness failed");
}
