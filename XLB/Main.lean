import XLB.Acquire
import XLB.Worker
import XLB.Tasks
import XLB.Status
import XL.Http

open Lean LeanXRPL XL Std.Async

private def usage := "XLB: xrplean backend\n  ./xl serve [--data DIR] [--listen 127.0.0.1:4001] [--rpc http://127.0.0.1:5005]\n    [--peer HOST:PORT] [--peer-timeout 30] [--rpc-backoff-max 30] [--proof-jobs 6] [--network-id 0] [--project-root DIR]\nRun from the project root. XLC is the HTTP client. See README.md."

private def config (args : List String) : IO Config := do
  let mut c : Config := {root := ← IO.currentDir}
  let mut rest := args
  while !rest.isEmpty do
    match rest with
    | flag :: value :: tail =>
      match flag with
      | "--data" => c := {c with data := value}
      | "--listen" => c := {c with listen := value}
      | "--rpc" => c := {c with rpc := value}
      | "--rpc-retries" =>
        -- Compatibility with older launchers/scripts: a retry count no longer
        -- limits transient recovery, including when the old value was zero.
        require value.toNat?.isSome "invalid legacy RPC retry count"
      | "--rpc-backoff-max" =>
        let some seconds := value.toNat? | throw <| IO.userError "invalid RPC backoff cap"
        require (seconds > 0 && seconds ≤ 30) "RPC backoff cap must be 1 to 30 seconds"
        c := {c with rpcBackoffMax := seconds}
      | "--peer" =>
        require c.peer.isNone "configure exactly one --peer endpoint"
        c := {c with peer := some (← IO.ofExcept (parseEndpoint value true))}
      | "--peer-timeout" =>
        let some seconds := value.toNat? | throw <| IO.userError "invalid peer timeout"
        require (seconds > 0 && seconds ≤ 3600) "peer timeout must be 1 to 3600 seconds"
        c := {c with peerTimeout := seconds}
      | "--proof-jobs" =>
        let some jobs := value.toNat? | throw <| IO.userError "invalid proof worker count"
        require (jobs > 0 && jobs ≤ 64) "proof worker count must be 1 to 64"
        c := {c with proofJobs := jobs}
      | "--network-id" =>
        let some network := value.toNat? | throw <| IO.userError "invalid network ID"
        require (network ≤ 4294967295) "network ID out of range"
        c := {c with network}
      | "--project-root" => c := {c with root := value}
      | _ => throw <| IO.userError s!"unknown option {flag}"
      rest := tail
    | _ => throw <| IO.userError usage
  IO.FS.createDirAll c.data
  c := {c with data := ← IO.FS.realPath c.data, root := ← IO.FS.realPath c.root}
  require (← (c.root / "tools/generate_merkle_certificate.py").pathExists) "project root missing proof tools; use --project-root"
  return c

private partial def handler (cache : XLB.Status.Cache) (c : Config) (stop : IO.Ref Bool) (request : Http.Request) (bundleOnly : Bool := false) : IO Http.Response := do
  try
    match request.path.splitOn "/" with
    | "" :: "bundles" :: name :: tail =>
      require (validBundle name) "invalid bundle name"
      let context :=  {c with bundle := name}
      if tail.isEmpty && request.method == "GET" then return ⟨200,← XLB.Bundle.info context,none⟩
      return ← handler cache context stop {request with path := "/" ++ String.intercalate "/" tail} true
    | _ => pure ()
    if request.method == "POST" then XLB.Store.ensureBundle c
    match request.method,request.path with
    | "GET","/status" => return ⟨200,← XLB.Status.getStatus cache c stop,none⟩
    | "GET","/health" => return ⟨200,obj [("service",str "XLB"),("network_id",toJson c.network),
        ("pid",toJson ((← IO.Process.getPID).toNat)),("state_backend",str "nudb")],none⟩
    | "GET","/exports" => return ⟨200,← XLB.Store.exports c,none⟩
    | "GET","/bundles" => return ⟨200,← XLB.Bundle.list c,none⟩
    | "GET","/state/info" => return ⟨200,← XLB.Bundle.info c,none⟩
    | "GET","/tasks" => return ⟨200,← XLB.Tasks.list c bundleOnly,none⟩
    | "POST",path =>
      if ["/fetch","/fetch/stream","/state/new","/state/new/stream","/state/update","/state/update/stream"].contains path then
        let kind := if path.startsWith "/state/new" then "state_new" else if path.startsWith "/state/update" then "state_update" else "fetch"
        let task ← XLB.Tasks.submit c kind request.body
        let id := (optString task "task_id").toNat?.getD 0
        if path.endsWith "/stream" then
          return {stream := some (XLB.Tasks.watch c stop id)}
        return ⟨200,← (XLB.Tasks.waitResult c stop id).block,none⟩
      else
        match path with
        | "/tasks" => return ⟨202,← XLB.Tasks.submit c (← string request.body "kind") (← get request.body "request"),none⟩
        | "/ledgers" =>
          discard <| XLB.Store.receive c request.body
          return ⟨204,.null,none⟩
        | "/state" => return ⟨201,← XLB.Acquire.importState c request.body,none⟩
        | "/state/discard" => return ⟨200,← XLB.SharedState.discard c request.body,none⟩
        | "/state/consolidate" => return ⟨200,← XLB.SharedState.consolidate c,none⟩
        | "/trust" => return ⟨200,← XLB.Store.trust c request.body,none⟩
        | "/jobs" => return ⟨202,← XLB.Store.queue c request.body,none⟩
        | _ =>
          match path.splitOn "/" with
          | ["","jobs",raw,"cancel"] =>
            let some id := raw.toNat? | throw <| IO.userError "invalid job ID"
            return ⟨200,← XLB.Store.cancelJob c id,none⟩
          | ["","tasks",raw,action] =>
            let some id := raw.toNat? | throw <| IO.userError "invalid task ID"
            discard <| XLB.Tasks.getTask c id bundleOnly
            match action with
            | "stream" => return {stream := some fun emit => XLB.Tasks.watch c stop id emit (optNat request.body "after_seq")}
            | "wait" => return ⟨200,← (XLB.Tasks.waitResult c stop id).block,none⟩
            | "cancel" => return ⟨200,← XLB.Tasks.cancel c id bundleOnly,none⟩
            | "retry" => return ⟨202,← XLB.Tasks.retry c id bundleOnly,none⟩
            | _ => return ⟨404,obj [("error",str "route not found")],none⟩
          | _ => return ⟨404,obj [("error",str "route not found")],none⟩
    | "GET","/ledgers" => return ⟨200,← XLB.Store.inventory c,none⟩
    | "GET","/jobs" => return ⟨200,← XLB.Store.jobs c,none⟩
    | "GET",path =>
      match path.splitOn "/" with
      | ["","tasks",id] =>
        let some id := id.toNat? | throw <| IO.userError "invalid task ID"
        return ⟨200,← XLB.Tasks.getTask c id bundleOnly,none⟩
      | ["","jobs",id] =>
        let some id := id.toNat? | return ⟨404,obj [("error",str "job not found")],none⟩
        return ⟨200,← XLB.Store.job c id,none⟩
      | _ => return ⟨404,obj [("error",str "route not found")],none⟩
    | _,_ => return ⟨404,obj [("error",str "route not found")],none⟩
  catch error =>
    let message := error.toString
    let status := if (message.splitOn "XL database:").length > 1 || (message.splitOn "cannot open XL database").length > 1 || (message.splitOn "cannot configure XL database").length > 1 then 503 else 422
    return ⟨status,obj [("error",str message)],none⟩

private def serve (c : Config) : IO UInt32 := do
  let fd ← XL.lock (c.data / "backend.lock").toString
  try
    XLB.Store.init c
    XLB.Tasks.init c
    require (← NodeStore.nudbAvailable) "XLB requires NuDB support; rebuild with NuDB and Boost development files"
    let stop ← IO.mkRef false
    let statusCache ← XLB.Status.new
    let server ← Http.listen c.listen
    let interrupt ← Signal.Waiter.mk .sigint false
    let terminate ← Signal.Waiter.mk .sigterm false
    let interruptTask ← interrupt.wait
    let terminateTask ← terminate.wait
    let worker ← IO.asTask (XLB.Worker.run c stop) (prio := .dedicated)
    let monitor : Async Unit := do
      while !(← stop.get) do
        if (← IO.hasFinished interruptTask) || (← IO.hasFinished terminateTask) || (← IO.hasFinished worker) then
          stop.set true
        else sleep (.ofInt 100)
    let acquisition : Async Unit := do
      try XLB.Tasks.run c stop
      catch error => stop.set true; throw error
    (← IO.getStderr).putStrLn s!"XLB listening at http://{c.listen}; network={c.network}; data={c.data}"
    try
      discard <| (Async.concurrently monitor (Async.concurrently acquisition (Http.run server stop (fun request => handler statusCache c stop request)))).block
    finally
      stop.set true
      interrupt.stop
      terminate.stop
    IO.ofExcept worker.get
    return 0
  finally XL.unlock fd

def main (args : List String) : IO UInt32 := do
  if args == ["--help"] || args == ["-h"] then IO.println usage; return 0
  try serve (← config args)
  catch error => (← IO.getStderr).putStrLn error.toString; return 1
