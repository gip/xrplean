import LeanXRPL.StateIngest
import Std.Async

namespace XL
open Lean LeanXRPL

structure Config where
  data : System.FilePath := ".xl"
  listen : String := "127.0.0.1:4001"
  rpc : String := "http://127.0.0.1:5005"
  rpcBackoffMax : Nat := 30
  peer : Option Endpoint := none
  peerTimeout : Nat := 30
  proofJobs : Nat := 6
  network : Nat := 0
  root : System.FilePath := "."
  bundle : String := "default"
  batchServiceAddress : String := ""
  batchServiceFee : Nat := 0
  deriving Inhabited

def Config.db (c : Config) := (c.data / "xl.sqlite3").toString

def Config.bundleDir (c : Config) : System.FilePath :=
  if c.bundle == "default" then c.data else c.data / "bundles" / c.bundle

def validBundle (name : String) : Bool :=
  !name.isEmpty && name.length ≤ 64 && name.toList.all (fun c =>
    c.toNat < 128 && (c.isAlphanum || c == '-' || c == '_'))

def obj := Json.mkObj
def str := Json.str

/-- Payment attempts accepted by verification jobs, including reported skips. -/
def successfulPaymentStatuses : List String :=
  ["kernel_checked", "supported_checked", "no_supported_payments"]

def get (j : Json) (key : String) : IO Json := IO.ofExcept (j.getObjVal? key)
def string (j : Json) (key : String) : IO String := IO.ofExcept ((j.getObjVal? key).bind Json.getStr?)
def nat (j : Json) (key : String) : IO Nat := IO.ofExcept ((j.getObjVal? key).bind Json.getNat?)
def array (j : Json) (key : String) : IO (Array Json) := IO.ofExcept ((j.getObjVal? key).bind Json.getArr?)
def optString (j : Json) (key : String) (default := "") : String :=
  ((j.getObjVal? key).bind Json.getStr?).toOption.getD default
def optNat (j : Json) (key : String) (default := 0) : Nat :=
  ((j.getObjVal? key).bind Json.getNat?).toOption.getD default

def require (b : Bool) (message : String) : IO Unit :=
  unless b do throw <| IO.userError message

def hash (s : String) : IO String := do
  let bytes ← IO.ofExcept (unhex s)
  require (bytes.size == 32) "expected a 256-bit hexadecimal hash"
  return hex bytes

def index (n : Nat) : IO Unit := require (n > 0 && n ≤ 4294967295) "ledger index out of range"

def digest (s : String) : IO String := return hex (← Native.sha256 s.toUTF8)

/-- SQL literals are always quoted, including JSON and paths. NUL is rejected. -/
def quote (s : String) : IO String := do
  require (!s.contains '\x00') "NUL is not allowed"
  return "'" ++ s.replace "'" "''" ++ "'"

@[extern "xl_sql"] opaque sql (path : @& String) (query : @& String) : IO (Array (Array String)) :=
  throw <| IO.userError "SQLite unavailable"
@[extern "xl_lock"] opaque lock (path : @& String) : IO UInt32 := throw <| IO.userError "lock unavailable"
@[extern "xl_unlock"] opaque unlock (fd : UInt32) : IO Unit := pure ()

def exec (c : Config) (query : String) : IO Unit := discard <| sql c.db query

def rowsJson (rows : Array (Array String)) (keys : Array String) : IO Json := do
  return toJson (← rows.mapM fun row => do
    require (row.size == keys.size) "database row shape mismatch"
    return obj (keys.toList.zip row.toList |>.map fun (k,v) => (k,str v)))

/-- External tools run in a separate process group; shutdown terminates descendants. -/
def process (c : Config) (stop : IO.Ref Bool) (cmd : String) (args : Array String)
    (log : System.FilePath) (env : Array (String × Option String) := #[]) (timeoutMs : Nat := 0) : IO UInt32 := do
  require (!(← stop.get)) "interrupted"
  let child ← IO.Process.spawn {
    cmd := cmd
    args := args
    cwd := some c.root
    env := env
    stdin := .null
    stdout := .piped
    stderr := .piped
    setsid := true }
  let out ← IO.asTask (do
    let file ← IO.FS.Handle.mk log .write
    repeat
      let bytes ← child.stdout.read 65536
      if bytes.isEmpty then break
      file.write bytes
      file.flush
    file.flush) (prio := .dedicated)
  let err ← IO.asTask child.stderr.readToEnd (prio := .dedicated)
  let mut code := none
  let started ← IO.monoMsNow
  let mut timedOut := false
  while code.isNone do
    if (← stop.get) || (timeoutMs > 0 && (← IO.monoMsNow) - started ≥ timeoutMs) then
      timedOut := !(← stop.get)
      child.kill
    code ← child.tryWait
    if code.isNone then IO.sleep 100
  discard <| IO.ofExcept out.get
  let stderr ← IO.ofExcept err.get
  if !stderr.isEmpty then
    let file ← IO.FS.Handle.mk (System.FilePath.mk (log.toString ++ ".stderr")) .write
    file.putStr stderr
  if ← stop.get then throw <| IO.userError "interrupted"
  require (!timedOut) "proof process exceeded its time limit; diagnostics retained"
  return code.get!

end XL
