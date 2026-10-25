import LeanXRPL.StateSnapshot
import Std.Data.TreeMap.Basic

namespace LeanXRPL.StateTree

/-- A content address, including the all-zero empty-tree/empty-branch sentinel. -/
structure Hash where
  bytes : ByteArray
  size_eq : bytes.size = 32

/-- A ledger object ID selects a radix-16 path; it is not its leaf's content hash. -/
structure ObjectID where
  bytes : ByteArray
  size_eq : bytes.size = 32

instance : BEq Hash := ⟨fun a b => a.bytes == b.bytes⟩
instance : Hashable Hash := ⟨fun h => hash h.bytes⟩
instance : BEq ObjectID := ⟨fun a b => a.bytes == b.bytes⟩
instance : Inhabited Hash := ⟨⟨zeroHash, rfl⟩⟩
instance : Inhabited ObjectID := ⟨⟨zeroHash, rfl⟩⟩

def Hash.ofBytes (bytes : ByteArray) : Except String Hash :=
  if h : bytes.size = 32 then .ok ⟨bytes, h⟩ else .error "state hash must be 32 bytes"

def ObjectID.ofBytes (bytes : ByteArray) : Except String ObjectID :=
  if h : bytes.size = 32 then .ok ⟨bytes, h⟩ else .error "object ID must be 32 bytes"

def Hash.zero : Hash := ⟨zeroHash, rfl⟩
def Hash.isZero (hash : Hash) : Bool := hash.bytes == zeroHash

def ObjectID.branch (key : ObjectID) (depth : Fin 64) : Fin 16 :=
  have indexBound : depth.val/2 < key.bytes.size := by rw [key.size_eq]; omega
  let byte := (key.bytes[depth.val/2]'indexBound).toNat
  let digit := if depth.val%2 == 0 then byte/16 else byte%16
  ⟨digit%16, Nat.mod_lt _ (by decide)⟩

inductive Node where
  | inner (children : Vector Hash 16)
  | leaf (key : ObjectID) (data : ByteArray)
  deriving Inhabited

/-- An immutable handle. Its root is not a new consensus certificate. -/
structure Tree where
  root : Hash
  deriving Inhabited

def Tree.empty : Tree := ⟨Hash.zero⟩

def decode (wire : ByteArray) : IO (Hash × Node) := do
  let (hash, node) ← decodeStateNode wire
  let hash ← IO.ofExcept (Hash.ofBytes hash)
  match node with
  | .leaf key data => return (hash, .leaf (← IO.ofExcept (ObjectID.ofBytes key)) data)
  | .inner children =>
    let children ← children.mapM (fun bytes => IO.ofExcept (Hash.ofBytes bytes))
    if h : children.size = 16 then return (hash, .inner ⟨children, h⟩)
    else throw <| IO.userError "state inner node must have 16 children"

/-- Preserve XRPL hashing while storing sparse inner nodes compactly. -/
def encode (node : Node) : Except String ByteArray := do
  match node with
  | .leaf key data =>
    if data.size < 12 || data.size > 2097152-33 then throw "state leaf value size limit"
    return (data ++ key.bytes).push 1
  | .inner children =>
    let nonempty := children.toArray.filter (fun hash => !hash.isZero)
    if nonempty.isEmpty then throw "empty inner node"
    if nonempty.size ≥ 12 then
      return (children.toArray.foldl (fun wire hash => wire ++ hash.bytes) ByteArray.empty).push 2
    let mut wire := ByteArray.empty
    for branch in [:16] do
      let hash := children.toArray[branch]!
      if !hash.isZero then wire := (wire ++ hash.bytes).push branch.toUInt8
    return wire.push 3

private structure CacheEntry where
  node : Node
  charge : Nat
  previous : Option Hash := none
  next : Option Hash := none

/-- Lexicographic binary ordering without materializing boxed UInt8 arrays. -/
@[extern "lx_compare_bytes"]
def compareBytes (a b : @& ByteArray) : Ordering := Id.run do
  for i in [:min a.size b.size] do
    let order := compare a[i]! b[i]!
    if order != .eq then return order
  return compare a.size b.size

private def compareHash (a b : Hash) : Ordering := compareBytes a.bytes b.bytes

/-- LRU links have one entry per node: repeated hits cannot grow an access queue. -/
private structure Cache where
  capacity : Nat
  used : Nat := 0
  -- Mutex snapshots share cache state. A persistent tree copies O(log n) paths;
  -- a shared hash table copies its entire bucket array on each LRU link update.
  entries : Std.TreeMap Hash CacheEntry compareHash := {}
  oldest : Option Hash := none
  newest : Option Hash := none
  hits : Nat := 0
  misses : Nat := 0
  evictions : Nat := 0

private def Cache.remove (c : Cache) (key : Hash) : Cache := Id.run do
  let some entry := c.entries[key]? | return c
  let mut c := { c with entries := c.entries.erase key, used := c.used-entry.charge }
  if let some previous := entry.previous then
    if let some e := c.entries[previous]? then c := { c with entries := c.entries.insert previous { e with next := entry.next } }
  else c := { c with oldest := entry.next }
  if let some next := entry.next then
    if let some e := c.entries[next]? then c := { c with entries := c.entries.insert next { e with previous := entry.previous } }
  else c := { c with newest := entry.previous }
  return c

private def Cache.append (c : Cache) (key : Hash) (entry : CacheEntry) : Cache := Id.run do
  let mut c := c
  if let some previous := c.newest then
    if let some e := c.entries[previous]? then c := { c with entries := c.entries.insert previous { e with next := some key } }
  else c := { c with oldest := some key }
  return { c with
    newest := some key
    used := c.used + entry.charge
    entries := c.entries.insert key { entry with previous := c.newest, next := none } }

private def Cache.find (c : Cache) (key : Hash) : Option Node × Cache :=
  match c.entries[key]? with
  | none => (none, { c with misses := c.misses+1 })
  | some entry =>
    if c.newest == some key then (some entry.node, { c with hits := c.hits+1 })
    else
      let c := (c.remove key).append key entry
      (some entry.node, { c with hits := c.hits + 1 })

/-- Conservative cache accounting includes decoded child arrays, keys and LRU links.
This bounds retained entries/payloads, not the whole process or SQLite's own cache. -/
private def Node.cacheCharge : Node → Nat
  | .inner _ => 4096
  | .leaf _ data => data.size+1024

private def Cache.insert (c : Cache) (key : Hash) (node : Node) : Cache := Id.run do
  let charge := node.cacheCharge
  if charge > c.capacity then return c
  let mut c := c.remove key
  for _ in [:c.entries.size] do
    if c.used+charge ≤ c.capacity then break
    let some oldest := c.oldest | break
    c := { (c.remove oldest) with evictions := c.evictions+1 }
  return c.append key ⟨node, charge, none, none⟩

private structure Session where
  store : NodeStore.Store
  backing : Option NodeStore.Store := none
  fallbacks : Array NodeStore.Store := #[]
  writable : Bool
  managed : Bool := false
  cache : Cache
  reads : Nat := 0
  writes : Nat := 0

/-- Owns serialized access to both store handles and its cache. Do not use supplied
NodeStore handles concurrently outside this repository. -/
structure Repository where
  private state : Std.Mutex Session

structure CacheStats where
  capacityBytes : Nat
  chargedBytes : Nat
  entries : Nat
  hits : Nat
  misses : Nat
  evictions : Nat
  diskReads : Nat
  diskWrites : Nat
  deriving Repr

def Repository.readOnly (store : NodeStore.Store) (cacheBytes := 134217728)
    (backing : Option NodeStore.Store := none) : IO Repository := do
  return ⟨← Std.Mutex.new { store, backing, writable := false, cache := { capacity := cacheBytes } }⟩

/-- A standalone workspace, optionally layered over immutable backing stores.
Acquisition stores are rejected as write targets to preserve their audit counts. -/
def Repository.ofStore (store : NodeStore.Store) (cacheBytes := 134217728)
    (backing : Option NodeStore.Store := none)
    (fallbacks : Array NodeStore.Store := #[]) : IO Repository := do
  if (← NodeStore.getMeta store "anchor") != "" || (← NodeStore.getMeta store "complete") != "" ||
      (← NodeStore.stats store).pending != 0 || (← NodeStore.getMeta store "sync_version") != "" ||
      (← NodeStore.getMeta store "history_version") != "" then
    throw <| IO.userError "use a separate workspace for immutable state-tree updates"
  return ⟨← Std.Mutex.new { store, backing, fallbacks, writable := true, cache := { capacity := cacheBytes } }⟩

/-- Only the state manager adopts authenticated snapshots into a managed store. -/
def Repository.managedStore (store : NodeStore.Store) (cacheBytes := 134217728) : IO Repository := do
  if (← NodeStore.getMeta store "history_version") != "1" || (← NodeStore.getMeta store "history_tip") == "" then
    throw <| IO.userError "managed state has no authenticated bootstrap"
  return ⟨← Std.Mutex.new { store, writable := true, managed := true, cache := { capacity := cacheBytes } }⟩

def Node.childReferences : Node → ByteArray
  | .leaf .. => ByteArray.empty
  | .inner children => children.toArray.foldl (fun b h => if h.isZero then b else b ++ h.bytes) ByteArray.empty

def Repository.open (path : System.FilePath) (maxBytes : UInt64 := 68719476736)
    (cacheBytes := 134217728) (nodeBackend : NodeStore.Backend := .detect) : IO Repository := do
  IO.FS.createDirAll (path.parent.getD ".")
  Repository.ofStore (← NodeStore.openStore path.toString maxBytes nodeBackend) cacheBytes

/-- Authenticate a completed snapshot. Updates require a separate overlay path.
An overlay can be reopened; retain computed roots separately from the ledger header. -/
def Repository.openSnapshot (path : System.FilePath) (publisher : String)
    (networkID := 0) (maxBytes : UInt64 := 68719476736) (cacheBytes := 134217728)
    (overlayPath : Option System.FilePath := none)
    (overlayMaxBytes : UInt64 := 68719476736)
    (nodeBackend : NodeStore.Backend := .detect) : IO (Repository × Tree) := do
  let snapshot ← StateSnapshot.open path networkID publisher maxBytes.toNat
  let some header := snapshot.header | throw <| IO.userError "snapshot has no authenticated header"
  if !snapshot.completed then throw <| IO.userError "snapshot acquisition is incomplete"
  let tree := Tree.mk (← IO.ofExcept (Hash.ofBytes header.stateRoot))
  let repository ← match overlayPath with
    | none => Repository.readOnly snapshot.store cacheBytes
    | some overlay => do
      IO.FS.createDirAll (overlay.parent.getD ".")
      Repository.ofStore (← NodeStore.openStore overlay.toString overlayMaxBytes nodeBackend) cacheBytes (some snapshot.store)
  return (repository, tree)

def Repository.cacheStats (r : Repository) : IO CacheStats := r.state.atomically do
  let s ← get
  return ⟨s.cache.capacity, s.cache.used, s.cache.entries.size, s.cache.hits,
    s.cache.misses, s.cache.evictions, s.reads, s.writes⟩

def Repository.diskStats (r : Repository) : IO NodeStore.Stats := r.state.atomically do
  NodeStore.stats (← get).store

def Repository.checkpoint (r : Repository) : IO Unit := r.state.atomically do
  NodeStore.checkpoint (← get).store

/-- Copy all cataloged live payloads into a durable replacement generation. -/
def Repository.compact (r : Repository) : IO UInt64 := r.state.atomically do
  NodeStore.compact (← get).store

def Repository.clearCache (r : Repository) : IO Unit := r.state.atomically do
  modify fun s => { s with cache := { s.cache with entries := {}, used := 0, oldest := none, newest := none } }

private abbrev Computation := StateT Session IO

private def readWire (hash : Hash) : Computation ByteArray := do
  let s ← get
  modify fun s => { s with reads := s.reads+1 }
  let wire ← NodeStore.getNode s.store hash.bytes
  if !wire.isEmpty then return wire
  if let some backing := s.backing then
    modify fun s => { s with reads := s.reads+1 }
    let wire ← NodeStore.getNode backing hash.bytes
    if !wire.isEmpty then return wire
  for backing in s.fallbacks do
    modify fun s => { s with reads := s.reads+1 }
    let wire ← NodeStore.getNode backing hash.bytes
    if !wire.isEmpty then return wire
  return wire

private def verifyWire (expected : Hash) (wire : ByteArray) : IO Node := do
  if wire.isEmpty then throw <| IO.userError s!"missing state node {hex expected.bytes}"
  let (actual, node) ← decode wire
  if actual != expected then throw <| IO.userError "stored state node hash mismatch"
  return node

private def loadNode (hash : Hash) : Computation Node := do
  if hash.isZero then throw <| IO.userError "empty reference has no node"
  let key := hash
  let (cached, cache) := (← get).cache.find key
  modify fun s => { s with cache }
  if let some node := cached then return node
  let node ← verifyWire hash (← readWire hash)
  modify fun s => { s with cache := s.cache.insert key node }
  return node

def Repository.load (r : Repository) (hash : Hash) : IO Node := r.state.atomically do
  let (node, next) ← (loadNode hash).run (← get)
  set next
  return node

private def checkLeafPath (key : ObjectID) (path : Array Nat) : IO Unit := do
  if path.isEmpty || !keyHasPath key.bytes path then throw <| IO.userError "state leaf path mismatch"

private def lookupAt (key : ObjectID) (fuel : Nat) (path : Array Nat)
    (hash : Hash) : Computation (Option ByteArray) := do
  if hash.isZero then return none
  match ← loadNode hash with
  | .leaf leafKey data =>
    checkLeafPath leafKey path
    return if leafKey == key then some data else none
  | .inner children =>
    match fuel with
    | 0 => throw <| IO.userError "state inner node at leaf depth"
    | fuel+1 =>
      if h : path.size < 64 then
        let branch := key.branch ⟨path.size, h⟩
        lookupAt key fuel (path.push branch.val) (children.get branch)
      else throw <| IO.userError "state path depth limit"

def Repository.lookup (r : Repository) (tree : Tree) (key : ObjectID) : IO (Option ByteArray) := r.state.atomically do
  let (value, next) ← (lookupAt key 64 #[] tree.root).run (← get)
  set next
  return value

/-- Exact node position, rather than an object lookup. A leaf encountered before
the requested depth means that position does not exist. -/
def Repository.referenceAt (r : Repository) (tree : Tree) (path : Array Nat) : IO (Option Hash) := r.state.atomically do
  if path.size > 64 || path.any (· ≥ 16) then throw <| IO.userError "invalid state path"
  let action : Computation (Option Hash) := do
    let mut hash := tree.root
    let mut visited := #[]
    for depth in [:path.size+1] do
      if hash.isZero then return none
      let node ← loadNode hash
      match node with
      | .leaf key _ =>
        checkLeafPath key visited
        return if depth == path.size then some hash else none
      | .inner children =>
        if depth ≥ 64 then throw <| IO.userError "state inner node at leaf depth"
        if depth == path.size then return some hash
        let branch := path[depth]!
        if h : branch < 16 then hash := children.get ⟨branch, h⟩
        else throw <| IO.userError "invalid state branch"
        visited := visited.push branch
    return none
  let (result, next) ← action.run (← get)
  set next
  return result

private def persist (node : Node) : Computation Hash := do
  let wire ← IO.ofExcept (encode node)
  let (hash, node) ← decode wire
  if hash.isZero then throw <| IO.userError "nonempty node has zero hash"
  let existing ← readWire hash
  if existing.isEmpty then
    NodeStore.putNode (← get).store hash.bytes wire (match node with | .leaf .. => true | _ => false)
    if (← get).managed then NodeStore.historyRegister (← get).store hash.bytes node.childReferences
    modify fun s => { s with writes := s.writes+1 }
    -- INSERT OR IGNORE must not hide an existing empty/corrupt row.
    modify fun s => { s with reads := s.reads+1 }
    discard <| verifyWire hash (← NodeStore.getNode (← get).store hash.bytes)
  else discard <| verifyWire hash existing
  modify fun s => { s with cache := s.cache.insert hash node }
  return hash

private def splitLeaves (oldKey key : ObjectID) (oldHash newHash : Hash)
    (fuel depth : Nat) : Computation Hash := do
  match fuel with
  | 0 => throw <| IO.userError "distinct object IDs cannot share all 64 branches"
  | fuel+1 =>
    if h : depth < 64 then
      let oldBranch := oldKey.branch ⟨depth, h⟩
      let branch := key.branch ⟨depth, h⟩
      let children := Vector.replicate 16 Hash.zero
      if oldBranch != branch then
        persist (.inner ((children.set oldBranch.val oldHash oldBranch.isLt).set branch.val newHash branch.isLt))
      else
        let child ← splitLeaves oldKey key oldHash newHash fuel (depth+1)
        persist (.inner (children.set branch.val child branch.isLt))
    else throw <| IO.userError "state path depth limit"

private def updateAt (key : ObjectID) (data : ByteArray) (fuel : Nat)
    (path : Array Nat) (hash : Hash) : Computation Hash := do
  if hash.isZero then
    let leaf ← persist (.leaf key data)
    if path.isEmpty then
      let branch := key.branch ⟨0, by decide⟩
      return ← persist (.inner ((Vector.replicate 16 Hash.zero).set branch.val leaf branch.isLt))
    return leaf
  match ← loadNode hash with
  | .leaf oldKey oldData =>
    checkLeafPath oldKey path
    if oldKey == key then
      if oldData == data then return hash
      persist (.leaf key data)
    else
      let leaf ← persist (.leaf key data)
      splitLeaves oldKey key hash leaf fuel path.size
  | .inner children =>
    match fuel with
    | 0 => throw <| IO.userError "state inner node at leaf depth"
    | fuel+1 =>
      if h : path.size < 64 then
        let branch := key.branch ⟨path.size, h⟩
        let oldChild := children.get branch
        let child ← updateAt key data fuel (path.push branch.val) oldChild
        if child == oldChild then return hash
        persist (.inner (children.set branch.val child branch.isLt))
      else throw <| IO.userError "state path depth limit"

/-- Upserts a batch atomically. Old nodes/roots are retained. Failed transactions
also discard staged cache entries, so rolled-back nodes cannot leak through it. -/
def Repository.updateMany (r : Repository) (tree : Tree)
    (changes : Array (ObjectID × ByteArray)) : IO Tree := r.state.atomically do
  let before ← get
  if !before.writable then throw <| IO.userError "state repository is read-only; open a separate update workspace"
  let (root, after) ← NodeStore.transaction before.store do
    let action : Computation Hash := do
      let mut root := tree.root
      for (key, data) in changes do
        discard <| IO.ofExcept (encode (.leaf key data))
        root ← updateAt key data 64 #[] root
      return root
    action.run before
  set after
  return ⟨root⟩

def Repository.update (r : Repository) (tree : Tree) (key : ObjectID) (data : ByteArray) : IO Tree :=
  r.updateMany tree #[(key, data)]

/-- Bulk construction for an ascending snapshot stream. Shared ancestors are
written once per batch, rather than once per object. Existing branches stay
immutable; this operation rejects updates to existing leaves. -/
private def appendSortedAt (changes : Array (ObjectID × ByteArray)) (lo hi : Nat)
    (fuel : Nat) (path : Array Nat) (hash : Hash) : Computation Hash := do
  if lo ≥ hi then return hash
  let mut children := Vector.replicate 16 Hash.zero
  if !hash.isZero then
    match ← loadNode hash with
    | .inner old => children := old
    | .leaf key _ =>
      checkLeafPath key path
      if compareBytes key.bytes changes[lo]!.1.bytes != .lt then
        throw <| IO.userError "snapshot append overlaps existing keys"
      if h : path.size < 64 then
        let branch := key.branch ⟨path.size, h⟩
        children := children.set branch.val hash branch.isLt
      else throw <| IO.userError "state path depth limit"
  else if hi == lo+1 && !path.isEmpty then
    return ← persist (.leaf changes[lo]!.1 changes[lo]!.2)
  match fuel with
  | 0 => throw <| IO.userError "state path depth limit"
  | fuel+1 =>
    if h : path.size < 64 then
      let mut cursor := lo
      while cursor < hi do
        let branch := changes[cursor]!.1.branch ⟨path.size, h⟩
        let start := cursor
        cursor := cursor+1
        while cursor < hi && changes[cursor]!.1.branch ⟨path.size, h⟩ == branch do
          cursor := cursor+1
        let child ← appendSortedAt changes start cursor fuel (path.push branch.val) (children.get branch)
        children := children.set branch.val child branch.isLt
      persist (.inner children)
    else throw <| IO.userError "state path depth limit"

/-- Atomically append an ordered page and its resume record. The callback runs
inside the node catalog transaction, before NuDB flush and catalog commit. It
must only write metadata to this repository's store. Failed callbacks/commits
discard staged cache entries and leave the previous root and cursor intact. -/
def Repository.appendSorted (r : Repository) (tree : Tree)
    (changes : Array (ObjectID × ByteArray))
    (checkpoint : Tree → IO Unit := fun _ => pure ()) : IO Tree := r.state.atomically do
  let before ← get
  if !before.writable || before.managed then
    throw <| IO.userError "snapshot append requires a standalone writable repository"
  for i in [:changes.size] do
    discard <| IO.ofExcept (encode (.leaf changes[i]!.1 changes[i]!.2))
    if i > 0 && compareBytes changes[i-1]!.1.bytes changes[i]!.1.bytes != .lt then
      throw <| IO.userError "snapshot page keys must be strictly increasing"
  let (root, after) ← NodeStore.transaction before.store do
    let result ← (appendSortedAt changes 0 changes.size 64 #[] tree.root).run before
    checkpoint ⟨result.1⟩
    pure result
  set after
  return ⟨root⟩

/-- Collapse a singleton subtree to its leaf, preserving an inner root. A unary
inner node whose subtree still contains multiple leaves cannot be collapsed. -/
private def onlyLeaf (hash : Hash) (fuel : Nat) (path : Array Nat) : Computation (Option Hash) := do
  match fuel with
  | 0 => throw <| IO.userError "state deletion depth limit"
  | fuel+1 =>
    match ← loadNode hash with
    | .leaf key _ => checkLeafPath key path; return some hash
    | .inner children =>
      if path.size ≥ 64 then throw <| IO.userError "state inner node at leaf depth"
      let nonempty := (List.range 16).filter (fun i => !children.toArray[i]!.isZero)
      match nonempty with
      | [branch] => onlyLeaf children.toArray[branch]! fuel (path.push branch)
      | _ => return none

private def deleteAt (key : ObjectID) (fuel : Nat) (path : Array Nat)
    (hash : Hash) : Computation Hash := do
  if hash.isZero then throw <| IO.userError "cannot delete absent state object"
  match ← loadNode hash with
  | .leaf oldKey _ =>
    checkLeafPath oldKey path
    if oldKey != key then throw <| IO.userError "cannot delete absent state object"
    return Hash.zero
  | .inner children =>
    match fuel with
    | 0 => throw <| IO.userError "state deletion depth limit"
    | fuel+1 =>
      if h : path.size < 64 then
        let branch := key.branch ⟨path.size, h⟩
        let child ← deleteAt key fuel (path.push branch.val) (children.get branch)
        let children := children.set branch.val child branch.isLt
        let nonempty := (List.range 16).filter (fun i => !children.toArray[i]!.isZero)
        if nonempty.isEmpty then return Hash.zero
        if !path.isEmpty then
          if let [only] := nonempty then
            if let some leaf ← onlyLeaf children.toArray[only]! (65-path.size) (path.push only) then
              return leaf
        return ← persist (.inner children)
      else throw <| IO.userError "state deletion depth limit"

/-- Compare-and-apply operations used by ledger exports. None means absence,
not an empty serialized object. Every before-image is checked at its exact
position in the evolving tree. The whole batch rolls back on any mismatch. -/
structure Change where
  key : ObjectID
  before : Option ByteArray
  after : Option ByteArray

/-- Receipts for checked primitive edits, composable by matching endpoint roots.
They are not standalone membership witnesses; replay still needs the node store. -/
structure RootTransition where
  before : Hash
  after : Hash
  change : Change

def Repository.replayChanges (r : Repository) (tree : Tree)
    (changes : Array Change) (expectedRoot : Option Hash := none)
    (publish : Tree → IO Unit := fun _ => pure ()) : IO (Tree × Array RootTransition) := r.state.atomically do
  let before ← get
  if !before.writable then throw <| IO.userError "state repository is read-only"
  let ((root, trace), after) ← NodeStore.transaction before.store do
    let action : Computation (Hash × Array RootTransition) := do
      let mut root := tree.root
      let mut trace := #[]
      for change in changes do
        let previous := root
        let actual ← lookupAt change.key 64 #[] root
        if actual != change.before then
          throw <| IO.userError s!"export before-image mismatch for {hex change.key.bytes}"
        match change.before, change.after with
        | none, none => throw <| IO.userError "empty state change"
        | _, some data =>
          discard <| IO.ofExcept (encode (.leaf change.key data))
          root ← updateAt change.key data 64 #[] root
        | some _, none => root ← deleteAt change.key 64 #[] root
        trace := trace.push ⟨previous, root, change⟩
      if expectedRoot.any (· != root) then throw <| IO.userError "export final state root mismatch"
      return (root, trace)
    let ((root, trace), after) ← action.run before
    publish ⟨root⟩
    return ((root, trace), after)
  set after
  return (⟨root⟩, trace)

def Repository.applyChanges (r : Repository) (tree : Tree)
    (changes : Array Change) (expectedRoot : Option Hash := none) : IO Tree := do
  return (← r.replayChanges tree changes expectedRoot).1

def Repository.erase (r : Repository) (tree : Tree) (key : ObjectID) : IO Tree := do
  let some data ← r.lookup tree key | throw <| IO.userError "cannot delete absent state object"
  r.applyChanges tree #[⟨key, some data, none⟩]

end LeanXRPL.StateTree
