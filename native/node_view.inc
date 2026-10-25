/* Generic persistence indirection only. Lean authenticates every loaded node and
   decides which complete parent/root may be reused. Source payloads are immutable.
   An index reader pins its SQLite snapshot; new mappings only append. */
static store *view_source(store *s,const char *path) {
  if(!path || !*path || !strcmp(path,s->path))return NULL;
  for(unsigned i=0;i<8;i++)if(s->view_sources[i]){
    store *child=lean_get_external_data(s->view_sources[i]);
    if(child->path && !strcmp(path,child->path))return child;
  }
  lean_object *name=lean_mk_string(path);
  lean_object *result=open_store(name,s->max_bytes,1,0,lean_box(0));
  lean_dec(name);
  if(!lean_io_result_is_ok(result)){lean_dec(result);return NULL;}
  lean_object *handle=lean_io_result_get_value(result);lean_inc(handle);lean_dec(result);
  store *child=lean_get_external_data(handle);
  if(!strcmp(child->path,s->path)){lean_dec(handle);return NULL;}
  unsigned slot=s->view_next++%8;
  if(s->view_sources[slot])lean_dec(s->view_sources[slot]);
  s->view_sources[slot]=handle;
  return child;
}
static int read_node_depth(store *s,const void *hash,unsigned char **data,size_t *size,int *leaf,unsigned depth) {
  int found=read_local_node(s,hash,data,size,leaf);
  if(found || !s->view_lookup)return found;
  if(depth>=8){snprintf(s->node_error,sizeof s->node_error,"cyclic or excessively nested state view");return -1;}
  sqlite3_bind_blob(s->view_lookup,1,hash,32,SQLITE_TRANSIENT);
  int rc=sqlite3_step(s->view_lookup);
  const char *value=rc==SQLITE_ROW?(const char*)sqlite3_column_text(s->view_lookup,0):NULL;
  char *path=value && *value?strdup(value):NULL;
  reset(s->view_lookup);
  if(rc!=SQLITE_ROW && rc!=SQLITE_DONE){snprintf(s->node_error,sizeof s->node_error,"state view lookup failed");return -1;}
  if(rc==SQLITE_ROW && !path){snprintf(s->node_error,sizeof s->node_error,"invalid state view source");return -1;}
  store *source=view_source(s,path?path:s->view_base);free(path);
  if(!source){snprintf(s->node_error,sizeof s->node_error,"state view source unavailable");return -1;}
  found=read_node_depth(source,hash,data,size,leaf,depth+1);
  if(found<0)snprintf(s->node_error,sizeof s->node_error,"state view: %.480s",source->node_error);
  if(rc==SQLITE_ROW && found==0){snprintf(s->node_error,sizeof s->node_error,"indexed state node missing");return -1;}
  return found;
}
LEAN_EXPORT lean_obj_res lx_store_view_init(b_lean_obj_arg a,b_lean_obj_arg base,lean_obj_arg w) {
  (void)w;WRITE_STORE(a);
  if(s->transaction)return fail(s,"state view initialization in transaction");
  const char *path=lean_string_cstr(base);
  if(!*path || !strcmp(s->path,path))return fail(s,"invalid state view base");
  if(!sql(s,"CREATE TABLE IF NOT EXISTS xl_view_config(id INTEGER PRIMARY KEY CHECK(id=1),base_path TEXT NOT NULL);"
      "CREATE TABLE IF NOT EXISTS xl_node_sources(hash BLOB PRIMARY KEY CHECK(length(hash)=32),path TEXT NOT NULL) WITHOUT ROWID;"))return fail(s,"state view schema failed");
  sqlite3_stmt *q=NULL;
  if(sqlite3_prepare_v2(s->db,"INSERT OR IGNORE INTO xl_view_config VALUES(1,?1)",-1,&q,NULL)!=SQLITE_OK)return fail(s,"state view base prepare failed");
  sqlite3_bind_text(q,1,path,-1,SQLITE_TRANSIENT);int rc=sqlite3_step(q);sqlite3_finalize(q);
  if(rc!=SQLITE_DONE)return fail(s,"state view base write failed");
  if(!s->view_lookup && !prepare_view(s))return fail(s,"state view setup failed");
  return s->view_base && !strcmp(s->view_base,path)?ok():fail(s,"state view base changed");
}
LEAN_EXPORT lean_obj_res lx_store_view_index(b_lean_obj_arg a,b_lean_obj_arg input,lean_obj_arg w) {
  (void)w;WRITE_STORE(a);store *source=lean_get_external_data(input);
  if(!transaction_active(s) || !s->view_lookup || !source->db || source->transaction || source->view_lookup)
    return fail(s,"invalid state view index transaction");
  sqlite3_stmt *read=NULL,*put=NULL;
  const char *query=source->nudb?"SELECT hash FROM node_catalog":"SELECT hash FROM nodes";
  if(sqlite3_prepare_v2(source->db,query,-1,&read,NULL)!=SQLITE_OK)return fail(s,"state source scan failed");
  if(sqlite3_prepare_v2(s->db,"INSERT OR IGNORE INTO xl_node_sources VALUES(?1,?2)",-1,&put,NULL)!=SQLITE_OK){sqlite3_finalize(read);return fail(s,"state index prepare failed");}
  int rc,good=1;
  while((rc=sqlite3_step(read))==SQLITE_ROW){
    if(sqlite3_column_bytes(read,0)!=32){good=0;break;}
    sqlite3_bind_blob(put,1,sqlite3_column_blob(read,0),32,SQLITE_TRANSIENT);
    sqlite3_bind_text(put,2,source->path,-1,SQLITE_TRANSIENT);
    if(sqlite3_step(put)!=SQLITE_DONE){good=0;break;}
    reset(put);
  }
  sqlite3_finalize(read);sqlite3_finalize(put);
  return good && rc==SQLITE_DONE?ok():fail(s,"state view indexing failed");
}
LEAN_EXPORT lean_obj_res lx_store_view_base(b_lean_obj_arg a,lean_obj_arg w) {
  (void)w;STORE(a);
  return lean_io_result_mk_ok(lean_mk_string(s->view_base?s->view_base:""));
}
