/* One payload catalog/generation, with isolated acquisition checkpoints. All
   visibility, cursor, frontier and counter changes use the same SQLite commit. */
LEAN_EXPORT lean_obj_res lx_store_scope(b_lean_obj_arg a,b_lean_obj_arg name,lean_obj_arg w) {
  (void)w;STORE(a);
  const char *scope=lean_string_cstr(name);
  if(!*scope)return ok(); /* Legacy checkpoints retain their original namespace. */
  if(s->transaction || s->scoped || strlen(scope)>256)return fail(s,"invalid acquisition scope");
  if(!s->readonly && !sql(s,
      "CREATE TABLE IF NOT EXISTS acquisition_pending(scope TEXT NOT NULL,id BLOB NOT NULL CHECK(length(id)=33),hash BLOB NOT NULL CHECK(length(hash)=32),due INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(scope,id)) WITHOUT ROWID;"
      "CREATE TABLE IF NOT EXISTS acquisition_counters(scope TEXT PRIMARY KEY,nodes INTEGER NOT NULL,leaves INTEGER NOT NULL,bytes INTEGER NOT NULL,pending INTEGER NOT NULL) WITHOUT ROWID;"))
    return fail(s,"acquisition scope schema failed");
  char *query=NULL;sqlite3_stmt *q=NULL;
  if(!s->readonly){
    query=sqlite3_mprintf("INSERT OR IGNORE INTO acquisition_counters VALUES(%Q,0,0,0,0)",scope);
    int good=query && sql(s,query);sqlite3_free(query);
    if(!good)return fail(s,"acquisition scope initialize failed");
  }
  query=sqlite3_mprintf("SELECT nodes,leaves,bytes,pending FROM acquisition_counters WHERE scope=%Q",scope);
  int good=query && sqlite3_prepare_v2(s->db,query,-1,&q,NULL)==SQLITE_OK;
  sqlite3_free(query);
  if(!good || sqlite3_step(q)!=SQLITE_ROW){sqlite3_finalize(q);return fail(s,"acquisition scope missing");}
  memcpy(s->global_counts,s->counts,sizeof s->counts);
  for(int i=0;i<4;i++)s->counts[i]=sqlite3_column_int64(q,i);
  sqlite3_finalize(q);
#define SCOPE_PREP(field,format) do { \
    query=sqlite3_mprintf(format,scope); \
    if(s->field){sqlite3_finalize(s->field);s->field=NULL;} \
    good=query && sqlite3_prepare_v2(s->db,query,-1,&s->field,NULL)==SQLITE_OK; \
    sqlite3_free(query);if(!good)return fail(s,"acquisition scope prepare failed"); \
  } while(0)
  SCOPE_PREP(pending_get,"SELECT hash FROM acquisition_pending WHERE scope=%Q AND id=?1");
  SCOPE_PREP(pending_add,"INSERT OR IGNORE INTO acquisition_pending(scope,id,hash) VALUES(%Q,?1,?2)");
  SCOPE_PREP(pending_del,"DELETE FROM acquisition_pending WHERE scope=%Q AND id=?1");
  if(!s->readonly){
    SCOPE_PREP(reserve,"SELECT id FROM acquisition_pending WHERE scope=%Q AND NOT EXISTS(SELECT 1 FROM temp.request_leases l WHERE l.id=acquisition_pending.id AND l.due>?1) ORDER BY id LIMIT ?2");
    SCOPE_PREP(pending_ready,"SELECT 1 FROM acquisition_pending WHERE scope=%Q AND NOT EXISTS(SELECT 1 FROM temp.request_leases l WHERE l.id=acquisition_pending.id AND l.due>?1) LIMIT 1");
  }
  SCOPE_PREP(meta_get,"SELECT value FROM metadata WHERE key=('acquisition/' || %Q || '/' || ?1)");
  SCOPE_PREP(meta_put,"INSERT INTO metadata VALUES(('acquisition/' || %Q || '/' || ?1),?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value");
  SCOPE_PREP(scope_stats,"UPDATE acquisition_counters SET nodes=?1,leaves=?2,bytes=?3,pending=?4 WHERE scope=%Q");
#undef SCOPE_PREP
  s->scoped=1;
  return ok();
}
