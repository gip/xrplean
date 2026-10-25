/* Called with the store's owning worker/mutex held. SQLite serializes publication;
   existing read-only handles pin their own catalog snapshot and NuDB generation. */
LEAN_EXPORT lean_obj_res lx_store_compact_needed(b_lean_obj_arg a,lean_obj_arg w) {
  (void)w;STORE(a);
  if(!s->nudb)return lean_io_result_mk_ok(lean_box(0));
  uint64_t physical=0;
  if(!lx_nudb_bytes(s->nudb,&physical))return nudb_fail(s,"measure node generation");
  uint64_t live=(uint64_t)s->counts[2]+(uint64_t)s->counts[0]*80+8192;
  return lean_io_result_mk_ok(lean_box(physical>live+live/4+16777216));
}
LEAN_EXPORT lean_obj_res lx_store_compact(b_lean_obj_arg a,lean_obj_arg w) {
  (void)w;WRITE_STORE(a);
  if(s->transaction)return fail(s,"node compaction during transaction");
  if(!s->nudb)return lean_io_result_mk_ok(lean_box_uint64(0));
  uint64_t before=0,after=0,budget=0;
  char generation[35];void *next=NULL;sqlite3_stmt *q=NULL;
  int begun=0,published=0;char error[768]="node compaction failed";
  if(!lx_nudb_bytes(s->nudb,&before)||!lx_nudb_new_generation(generation))return nudb_fail(s,"prepare node compaction");
  if(!sql(s,"BEGIN IMMEDIATE"))return fail(s,"begin node compaction");
  begun=1;
  if(!node_budget(s,&budget)){snprintf(error,sizeof error,"metadata allocation limit");goto failed;}
  next=lx_nudb_open(s->path,generation,1);
  if(!next)goto native_failed;
  if(sqlite3_prepare_v2(s->db,"SELECT hash,bytes FROM node_catalog ORDER BY hash",-1,&q,NULL)!=SQLITE_OK)goto sql_failed;
  unsigned batch=0;int rc;
  while((rc=sqlite3_step(q))==SQLITE_ROW){
    unsigned char hash[32],*data=NULL;size_t size=0;
    if(sqlite3_column_bytes(q,0)!=32){snprintf(error,sizeof error,"invalid live node hash");goto failed;}
    memcpy(hash,sqlite3_column_blob(q,0),32);
    int found=read_node(s,hash,&data,&size,NULL);
    if(found<=0){free(data);snprintf(error,sizeof error,"%s",found<0?s->node_error:"live node missing");goto failed;}
    int done=lx_nudb_put(next,hash,data,size,budget);free(data);
    if(!done)goto native_failed;
    if(++batch==1024){if(!lx_nudb_flush(next,budget))goto native_failed;batch=0;}
  }
  if(rc!=SQLITE_DONE)goto sql_failed;
  sqlite3_finalize(q);q=NULL;
  if(!lx_nudb_flush(next,budget)||!lx_nudb_bytes(next,&after))goto native_failed;
  /* Verify every copied byte through the replacement's index before publication.
     Content-hash/path authentication remains in Lean, as for ordinary reads. */
  if(sqlite3_prepare_v2(s->db,"SELECT hash FROM node_catalog ORDER BY hash",-1,&q,NULL)!=SQLITE_OK)goto sql_failed;
  while((rc=sqlite3_step(q))==SQLITE_ROW){
    unsigned char hash[32],*original=NULL,*copied=NULL;size_t original_size=0,copied_size=0;
    if(sqlite3_column_bytes(q,0)!=32){snprintf(error,sizeof error,"invalid verification hash");goto failed;}
    memcpy(hash,sqlite3_column_blob(q,0),32);
    int found=read_node(s,hash,&original,&original_size,NULL);
    if(found<=0){free(original);snprintf(error,sizeof error,"%s",found<0?s->node_error:"verification source missing");goto failed;}
    int done=lx_nudb_get(next,hash,&copied,&copied_size);
    int same=done&&copied&&original_size==copied_size&&(!original_size||!memcmp(original,copied,original_size));
    free(original);free(copied);
    if(!done)goto native_failed;
    if(!same){snprintf(error,sizeof error,"copied node verification failed");goto failed;}
  }
  if(rc!=SQLITE_DONE)goto sql_failed;
  sqlite3_finalize(q);q=NULL;
  const char *fault=getenv("LEANXRPL_STORAGE_TEST_FAULT");
  if(fault&&!strcmp(fault,"compact-before-publish"))_exit(87);
  if(sqlite3_prepare_v2(s->db,"UPDATE node_storage SET generation=?1 WHERE id=1 AND backend='nudb-v1'",-1,&q,NULL)!=SQLITE_OK)goto sql_failed;
  sqlite3_bind_text(q,1,generation,-1,SQLITE_TRANSIENT);
  if(sqlite3_step(q)!=SQLITE_DONE||sqlite3_changes(s->db)!=1)goto sql_failed;
  sqlite3_finalize(q);q=NULL;
  if(!sql(s,"COMMIT"))goto sql_failed;
  begun=0;published=1;
  if(fault&&!strcmp(fault,"compact-after-publish"))_exit(88);
  void *old=s->nudb;s->nudb=next;next=NULL;
  lx_nudb_retire(old);lx_nudb_release(old);
  return lean_io_result_mk_ok(lean_box_uint64(before>after?before-after:0));
native_failed:
  snprintf(error,sizeof error,"node compaction: %s",lx_nudb_error());goto failed;
sql_failed:
  snprintf(error,sizeof error,"node compaction metadata: %s",sqlite3_errmsg(s->db));
failed:
  sqlite3_finalize(q);
  if(begun)sql(s,"ROLLBACK");
  if(next){if(!published)lx_nudb_retire(next);lx_nudb_release(next);}
  return fail(NULL,error);
}
