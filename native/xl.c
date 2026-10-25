/* Application persistence and process ownership only; all XRPL logic is Lean. */
#include <lean/lean.h>
#include <sqlite3.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>

static lean_obj_res error(const char *s) {
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(s)));
}
/* Every invocation owns its connection; multi-statement transactions share it.
   Closing on error rolls back the entire open transaction. */
LEAN_EXPORT lean_obj_res xl_sql(b_lean_obj_arg path, b_lean_obj_arg text, lean_obj_arg world) {
  (void)world;
  sqlite3 *db = NULL;
  if (sqlite3_open_v2(lean_string_cstr(path), &db, SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
    if (db) sqlite3_close(db);
    return error("cannot open XL database");
  }
  sqlite3_busy_timeout(db, 10000);
  if (sqlite3_exec(db, "PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;", NULL,NULL,NULL) != SQLITE_OK) {
    sqlite3_close(db); return error("cannot configure XL database");
  }
  lean_object *rows = lean_mk_empty_array();
  const char *cursor = lean_string_cstr(text), *tail;
  sqlite3_stmt *st = NULL;
  while (*cursor) {
    int rc = sqlite3_prepare_v2(db,cursor,-1,&st,&tail);
    if (rc != SQLITE_OK) goto fail;
    cursor = tail;
    if (!st) continue;
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
      lean_object *row = lean_mk_empty_array();
      for (int i=0;i<sqlite3_column_count(st);i++) {
        const char *value = (const char*)sqlite3_column_text(st,i);
        row = lean_array_push(row,lean_mk_string(value ? value : ""));
      }
      rows = lean_array_push(rows,row);
    }
    if (rc != SQLITE_DONE) goto fail;
    sqlite3_finalize(st); st = NULL;
  }
  sqlite3_close(db);
  return lean_io_result_mk_ok(rows);
fail:;
  char message[512];
  snprintf(message,sizeof(message),"XL database: %s",sqlite3_errmsg(db));
  if(st) sqlite3_finalize(st);
  sqlite3_close(db); lean_dec(rows);
  return error(message);
}
LEAN_EXPORT lean_obj_res xl_lock(b_lean_obj_arg path, lean_obj_arg world) {
  (void)world;
  int fd = open(lean_string_cstr(path),O_CREAT|O_RDWR,0600);
  if(fd < 0) return error("cannot open backend lock");
  if(flock(fd,LOCK_EX|LOCK_NB)) {close(fd);return error("another XLB owns this data directory");}
  fcntl(fd,F_SETFD,FD_CLOEXEC);
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)fd));
}
LEAN_EXPORT lean_obj_res xl_unlock(uint32_t fd, lean_obj_arg world) {
  (void)world; close((int)fd); return lean_io_result_mk_ok(lean_box(0));
}
