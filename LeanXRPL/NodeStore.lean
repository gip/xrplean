import LeanXRPL.Trust

namespace LeanXRPL.NodeStore

/-- Backend is persisted in SQLite. Detection opens existing stores or creates SQLite. -/
inductive Backend where
  | detect | sqlite | nudb
  deriving Inhabited, BEq, Repr

def Backend.parse : String → Except String Backend
  | "auto" => .ok .detect
  | "sqlite" => .ok .sqlite
  | "nudb" => .ok .nudb
  | _ => .error "node backend must be auto, sqlite, or nudb"

private def Backend.code : Backend → UInt8
  | .detect => 0 | .sqlite => 1 | .nudb => 2

/-- Serialized by its owner; SQLite owns metadata/catalog and optionally payloads. -/
opaque Store : Type := Unit
@[extern "lx_store_worker_enter"] opaque enterWorker : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_worker_leave"] opaque leaveWorker : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_open_backend"] private opaque openNative (path : @& String) (maxBytes : UInt64) (backend : UInt8) : IO Store := throw <| IO.userError "node store unavailable"
def openStore (path : String) (maxBytes : UInt64) (backend : Backend := .detect) : IO Store :=
  openNative path maxBytes backend.code
/-- Acquisition metadata/frontiers are namespaced; node payloads remain global. -/
@[extern "lx_store_scope"] opaque setScope (store : @& Store) (scope : @& String) : IO Unit := throw <| IO.userError "node scope unavailable"
@[extern "lx_store_backend"] opaque backendName (store : @& Store) : IO String := throw <| IO.userError "node store unavailable"
@[extern "lx_store_nudb_available"] opaque nudbAvailable : IO Bool := pure false
@[extern "lx_store_compact"] opaque compact (store : @& Store) : IO UInt64 := throw <| IO.userError "node store unavailable"
@[extern "lx_store_compact_needed"] opaque compactNeeded (store : @& Store) : IO Bool := throw <| IO.userError "node store unavailable"
@[extern "lx_store_disk_bytes"] opaque diskBytes (store : @& Store) : IO UInt64 := throw <| IO.userError "node store unavailable"
@[extern "lx_store_export_sqlite"] opaque exportSQLite (store : @& Store) (target : @& String) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_open_readonly"] opaque openReadOnly (path : @& String) (maxBytes : UInt64) : IO Store := throw <| IO.userError "node store unavailable"
@[extern "lx_store_open_metadata"] opaque openMetadata (path : @& String) (maxBytes : UInt64) : IO Store := throw <| IO.userError "node store unavailable"
@[extern "lx_store_clone"] opaque cloneStore (store : @& Store) (target : @& String) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_publish_clone"] opaque publishClone (source target : @& String) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_begin"] opaque begin (store : @& Store) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_commit"] opaque commit (store : @& Store) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_rollback"] opaque rollback (store : @& Store) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_close"] opaque checkpoint (store : @& Store) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_dispose"] opaque dispose (store : @& Store) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_get"] opaque getNode (store : @& Store) (hash : @& ByteArray) : IO ByteArray := throw <| IO.userError "node store unavailable"
/- A view is an append-only hash-to-immutable-catalog index plus one full base.
   Lookup opens at most eight source catalogs; it never copies the base payloads. -/
@[extern "lx_store_view_init"] opaque viewInit (store : @& Store) (base : @& String) : IO Unit := throw <| IO.userError "state view unavailable"
@[extern "lx_store_view_index"] opaque viewIndex (view source : @& Store) : IO Unit := throw <| IO.userError "state view unavailable"
@[extern "lx_store_view_base"] opaque viewBase (view : @& Store) : IO String := throw <| IO.userError "state view unavailable"
@[extern "lx_store_put"] opaque putNode (store : @& Store) (hash wire : @& ByteArray) (leaf : Bool) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_pending_get"] opaque expected (store : @& Store) (id : @& ByteArray) : IO ByteArray := throw <| IO.userError "node store unavailable"
@[extern "lx_store_pending_add"] opaque addPending (store : @& Store) (id hash : @& ByteArray) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_pending_del"] opaque removePending (store : @& Store) (id : @& ByteArray) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_reserve"] opaque reserve (store : @& Store) (now : UInt64) (limit : UInt32) : IO ByteArray := throw <| IO.userError "node store unavailable"
@[extern "lx_store_pending_ready"] opaque pendingReady (store : @& Store) (now : UInt64) : IO Bool := throw <| IO.userError "node store unavailable"
@[extern "lx_store_pending_release"] opaque releasePending (store : @& Store) (ids : @& ByteArray) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_ledger_indices"] opaque ledgerIndices (store : @& Store) : IO String := throw <| IO.userError "node store unavailable"
@[extern "lx_store_meta_get"] opaque getMeta (store : @& Store) (key : @& String) : IO String := throw <| IO.userError "node store unavailable"
@[extern "lx_store_meta_put"] opaque putMeta (store : @& Store) (key value : @& String) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_stats"] opaque rawStats (store : @& Store) : IO ByteArray := throw <| IO.userError "node store unavailable"
@[extern "lx_store_sync_init"] opaque syncInit (store : @& Store) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_sync_closed_reset"] opaque syncClosedReset (store : @& Store) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_sync_closed"] opaque syncClosed (store : @& Store) (hash id : @& ByteArray) : IO Bool := throw <| IO.userError "node store unavailable"
@[extern "lx_store_sync_mark"] opaque syncMark (store : @& Store) (hash id : @& ByteArray) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_sync_wait_get"] opaque syncWaiting (store : @& Store) (id : @& ByteArray) : IO ByteArray := throw <| IO.userError "node store unavailable"
@[extern "lx_store_sync_wait_put"] opaque syncWait (store : @& Store) (id hash : @& ByteArray) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_sync_wait_del"] opaque syncUnwait (store : @& Store) (id : @& ByteArray) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_sync_reset"] opaque syncReset (store : @& Store) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_sync_previous"] opaque syncPrevious (store : @& Store) (id : @& ByteArray) : IO ByteArray := throw <| IO.userError "node store unavailable"
@[extern "lx_store_sync_previous_put"] opaque syncPreviousPut (store : @& Store) (id hash : @& ByteArray) : IO Unit := throw <| IO.userError "node store unavailable"
@[extern "lx_store_sync_previous_reset"] opaque syncPreviousReset (store : @& Store) : IO Unit := throw <| IO.userError "node store unavailable"

@[extern "lx_history_init"] opaque historyInit (store : @& Store) : IO Unit := throw <| IO.userError "history unavailable"
@[extern "lx_history_register"] opaque historyRegister (store : @& Store) (hash children : @& ByteArray) : IO Unit := throw <| IO.userError "history unavailable"
@[extern "lx_history_publish"] opaque historyPublish (store : @& Store) (sequence : UInt32) (root : @& ByteArray) (record : @& String) (keep : UInt32) : IO Unit := throw <| IO.userError "history unavailable"
@[extern "lx_history_read"] opaque historyRead (store : @& Store) (sequence : UInt32) : IO String := throw <| IO.userError "history unavailable"
@[extern "lx_history_ready"] opaque historyReady (store : @& Store) : IO Bool := throw <| IO.userError "history unavailable"
@[extern "lx_history_gc"] opaque historyCollect (store : @& Store) (limit : UInt32) : IO UInt32 := throw <| IO.userError "history unavailable"
@[extern "lx_history_garbage_ready"] opaque historyGarbageReady (store : @& Store) : IO Bool := throw <| IO.userError "history unavailable"
@[extern "lx_store_scan"] opaque scanNodes (store : @& Store) (after : @& ByteArray) (limit : UInt32) : IO ByteArray := throw <| IO.userError "scan unavailable"
@[extern "lx_inbox_init"] opaque inboxInit (store : @& Store) : IO Unit := throw <| IO.userError "inbox unavailable"
@[extern "lx_inbox_put"] opaque inboxPut (store : @& Store) (sequence : UInt32) (hash digest : @& ByteArray) (payload : @& String) : IO Unit := throw <| IO.userError "inbox unavailable"
@[extern "lx_inbox_get"] opaque inboxGet (store : @& Store) (sequence : UInt32) (hash : @& ByteArray) : IO String := throw <| IO.userError "inbox unavailable"
@[extern "lx_inbox_mark"] opaque inboxMark (store : @& Store) (hash : @& ByteArray) (status error : @& String) : IO Unit := throw <| IO.userError "inbox unavailable"
@[extern "lx_inbox_prune"] opaque inboxPrune (store : @& Store) (before : UInt32) : IO Unit := throw <| IO.userError "inbox unavailable"

structure Stats where
  nodes : Nat
  leaves : Nat
  bytes : Nat
  pending : Nat
  deriving Inhabited

def stats (store : Store) : IO Stats := do
  let b ← rawStats store
  if b.size != 32 then throw <| IO.userError "invalid node store statistics"
  return ⟨bytesNat (b.extract 0 8), bytesNat (b.extract 8 16), bytesNat (b.extract 16 24), bytesNat (b.extract 24 32)⟩

def transaction {α : Type} (store : Store) (action : IO α) : IO α := do
  begin store
  try
    let result ← action
    commit store
    return result
  catch error =>
    rollback store
    throw error

end LeanXRPL.NodeStore
