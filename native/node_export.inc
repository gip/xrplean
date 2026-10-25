/* Produce a standalone SQLite copy for existing independent readback tools.
   Source metadata is copied from the same pinned snapshot as its node catalog. */
static lean_obj_res export_store(b_lean_obj_arg a,b_lean_obj_arg target,lean_obj_arg w,int clone) {
  (void)w;STORE(a);
  if(s->metadata_only)return fail(s,"cannot clone a metadata-only handle");
  if(s->transaction)return fail(s,"export during transaction");
  const char *name=lean_string_cstr(target);int fd=-1,created=0;
  sqlite3 *out=NULL;sqlite3_stmt *rows=NULL,*put=NULL;sqlite3_backup *backup=NULL;
  char error[768]="SQLite export failed";
  /* Reject pre-existing targets and sidecars; this utility never overwrites data. */
  for(int i=0;i<3;i++){
    const char *suffix=i==0?"-wal":i==1?"-shm":"-journal";
    size_t n=strlen(name)+strlen(suffix)+1;char *p=malloc(n);
    if(!p)return fail(NULL,"export allocation failed");
    snprintf(p,n,"%s%s",name,suffix);struct stat info;
    int exists=lstat(p,&info)==0;free(p);if(exists)return fail(NULL,"export sidecar already exists");
  }
  fd=open(name,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0600);
  if(fd<0)return fail(NULL,"export target exists or cannot be created");
  close(fd);created=1;
  if(sqlite3_open_v2(name,&out,SQLITE_OPEN_READWRITE,NULL)!=SQLITE_OK)goto failed;
  backup=sqlite3_backup_init(out,"main",s->db,"main");
  if(!backup)goto failed;
  int rc=sqlite3_backup_step(backup,-1);int finished=sqlite3_backup_finish(backup);backup=NULL;
  if(rc!=SQLITE_DONE||finished!=SQLITE_OK)goto failed;
  if(sqlite3_exec(out,"PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; BEGIN IMMEDIATE;",NULL,NULL,NULL)!=SQLITE_OK)goto failed;
  if(s->nudb && !clone){
    if(sqlite3_exec(out,"DELETE FROM nodes",NULL,NULL,NULL)!=SQLITE_OK)goto failed;
    if(sqlite3_prepare_v2(s->db,"SELECT hash FROM node_catalog ORDER BY hash",-1,&rows,NULL)!=SQLITE_OK)goto failed;
    if(sqlite3_prepare_v2(out,"INSERT INTO nodes VALUES(?1,?2)",-1,&put,NULL)!=SQLITE_OK)goto failed;
    while((rc=sqlite3_step(rows))==SQLITE_ROW){
      unsigned char hash[32],*wire=NULL;size_t size=0;
      if(sqlite3_column_bytes(rows,0)!=32){snprintf(error,sizeof error,"invalid export hash");goto failed;}
      memcpy(hash,sqlite3_column_blob(rows,0),32);
      int found=read_node(s,hash,&wire,&size,NULL);
      if(found<=0){free(wire);snprintf(error,sizeof error,"%s",found<0?s->node_error:"export node missing");goto failed;}
      sqlite3_bind_blob(put,1,hash,32,SQLITE_TRANSIENT);
      sqlite3_bind_blob(put,2,wire,(int)size,SQLITE_TRANSIENT);free(wire);
      int done=sqlite3_step(put)==SQLITE_DONE;reset(put);if(!done)goto failed;
    }
    if(rc!=SQLITE_DONE)goto failed;
    if(sqlite3_exec(out,"UPDATE node_storage SET backend='sqlite',generation='' WHERE id=1; DELETE FROM node_catalog;",NULL,NULL,NULL)!=SQLITE_OK)goto failed;
  }
  sqlite3_finalize(rows);rows=NULL;sqlite3_finalize(put);put=NULL;
  if(sqlite3_exec(out,"COMMIT",NULL,NULL,NULL)!=SQLITE_OK)goto failed;
  if(sqlite3_close(out)!=SQLITE_OK)goto failed;
  out=NULL;
  if(clone && s->nudb && !lx_nudb_clone(s->nudb,name)){
    snprintf(error,sizeof error,"NuDB clone: %s",lx_nudb_error());goto failed;
  }
  char *parent=strdup(name);
  if(!parent){snprintf(error,sizeof error,"export parent allocation failed");goto failed;}
  char *slash=strrchr(parent,'/');
  if(slash){if(slash==parent)slash[1]=0;else *slash=0;}else{free(parent);parent=strdup(".");}
  if(!parent){snprintf(error,sizeof error,"export parent allocation failed");goto failed;}
  fd=open(parent,O_RDONLY|O_DIRECTORY);free(parent);
  int synced=fd>=0 && fsync(fd)==0;if(fd>=0)close(fd);
  if(!synced){snprintf(error,sizeof error,"export directory sync failed");goto failed;}
  return ok();
failed:
  if(out && !strcmp(error,"SQLite export failed"))snprintf(error,sizeof error,"SQLite export: %s",sqlite3_errmsg(out));
  if(backup)sqlite3_backup_finish(backup);
  sqlite3_finalize(rows);sqlite3_finalize(put);
  if(out)sqlite3_close(out);
  if(created)unlink(name);
  return fail(NULL,error);
}
LEAN_EXPORT lean_obj_res lx_store_export_sqlite(b_lean_obj_arg a,b_lean_obj_arg target,lean_obj_arg w) {
  return export_store(a,target,w,0);
}
LEAN_EXPORT lean_obj_res lx_store_clone(b_lean_obj_arg a,b_lean_obj_arg target,lean_obj_arg w) {
  return export_store(a,target,w,1);
}
