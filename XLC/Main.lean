import XLC.Fetch

open Lean XL

private def usage := "xrplean (XL): CLI and local backend\n\
  ./xl start [XLB options] | stop | status [--data DIR]\n\
  ./xl serve [XLB options]                 # foreground backend\n\
  ./xl health\n\
  ./xl ui [--port 4173] [--backend URL] [--dev [--speculos URL]]\n\
  ./xl speculos prepare|run [--directory DIR] [--port 5000]\n\
  ./xl ledger get --bundle NAME --index latest|INDEX[:END] [--state] [--detach]\n\
  ./xl ledger show [--bundle NAME] [--index INDEX] [--hash HASH]\n\
  ./xl ledger receive --file EXPORT.json\n\
  ./xl ledger trust --index INDEX --hash HASH [--reason TEXT]\n\
  ./xl ledger verify --index INDEX[:END] --checks merkle,payments [--hash HASH | --export-id ID]\n\
  ./xl bundle new --bundle NAME --index latest|INDEX|START:END [--detach]\n\
  ./xl bundle update --bundle NAME --index latest|INDEX|:END|START:END [--detach]\n\
  ./xl bundle show [--bundle NAME]\n\
  ./xl job show [--bundle NAME] [--id ID] | job cancel --id ID\n\
  ./xl task show [--bundle NAME] [--id ID | --running | --done]\n\
  ./xl task wait --id ID [--no-progress] | task retry --id ID | task cancel --id ID\n\
  ./xl export show [--bundle NAME]\n\
  ./xl state import --index INDEX --hash HASH --file WITNESSES.json\n\
Options may follow the command. --backend URL selects XLB (default http://127.0.0.1:4001).\n\
--bundle NAME (-b NAME) selects independent state, trust and proof history; default: default.\n\
show lists records unless a selector is given; bundle show without --bundle lists bundles.\n\
ledger get / bundle new / bundle update also accept --transport auto|peer|rpc, --hash HASH,\n\
--no-progress and --detach. Ranges are inclusive; --index has the short form -i.\n\
Acquisition runs in XLB; --detach returns its task ID. Ctrl+C only detaches progress.\n\
Tasks track acquisition; jobs track verification. All results are JSON; progress uses stderr.\n\
Trust requires a stored ledger. Passing both checks grants verified trust; operator anchors stay separate.\n\
Legacy commands (fetch, ledgers, jobs, job ID, tasks, task ID, state new/update/info/list,\n\
receive, trust, verify, exports and restart) remain compatibility aliases."

private def number (raw : String) : IO Nat := do
  let some n := raw.toNat? | throw <| IO.userError s!"invalid number: {raw}"
  return n

private def fileJson (path : String) : IO Json := do
  require ((← (System.FilePath.mk path).metadata).byteSize ≤ 64*1024*1024) "file exceeds 64 MiB"
  IO.ofExcept (Json.parse (← IO.FS.readFile path))

private def valueOptions := ["--index", "-i", "--id", "--hash", "--file", "--reason", "--checks", "--export-id", "--transport"]

private structure CliOptions where
  values : List (String × String) := []
  flags : List String := []

private def CliOptions.has (o : CliOptions) (key : String) : Bool := o.flags.contains key
private def CliOptions.get (o : CliOptions) (key : String) : Option String := o.values.lookup key
private def CliOptions.need (o : CliOptions) (key : String) : IO String := do
  let some value := o.get key | throw <| IO.userError s!"missing {key}"
  return value

/-- Reject unknown, duplicate and incomplete options before sending any request. -/
private def options (args allowed : List String) : IO CliOptions := do
  let mut result : CliOptions := {}
  let mut rest := args
  while !rest.isEmpty do
    let key := if rest.head! == "-i" then "--index" else rest.head!
    require (allowed.contains key) s!"unknown option: {rest.head!}"
    require ((result.get key).isNone && !result.has key) s!"duplicate option: {key}"
    if valueOptions.contains key then
      let _ :: value :: tail := rest | throw <| IO.userError s!"missing value for {key}"
      require (!value.isEmpty && !value.startsWith "--") s!"missing value for {key}"
      result := {result with values := (key,value)::result.values}
      rest := tail
    else
      result := {result with flags := key::result.flags}
      rest := rest.tail!
  return result

private def interval (raw : String) : IO (Nat × Nat) := do
  let (first,last) ← match raw.splitOn ":" with
    | [one] => let n ← number one; pure (n,n)
    | [a,b] => pure (← number a, ← number b)
    | _ => throw <| IO.userError "index must be INDEX or START:END"
  index first; index last
  require (last ≥ first && last-first < 10000) "range must contain 1 to 10000 ledgers"
  return (first,last)

private def legacyRange (command : List String) (tail : List String) : List String :=
  match tail with
  | first :: next :: rest =>
    if next.startsWith "-" then command ++ ["--index",first,next] ++ rest
    else command ++ ["--index",first++":"++next] ++ rest
  | [first] => command ++ ["--index",first]
  | [] => command

/-- Old spellings use the same option validation and HTTP dispatch as the noun/verb CLI. -/
private def normalize (args : List String) : List String :=
  match args with
  | ["ledgers"] => ["ledger","show"]
  | ["exports"] => ["export","show"]
  | ["jobs"] => ["job","show"]
  | "tasks" :: rest => ["task","show"] ++ rest
  | ["job",id] => if id.toNat?.isSome then ["job","show","--id",id] else args
  | ["task",id] => if id.toNat?.isSome then ["task","show","--id",id] else args
  | "job" :: "cancel" :: id :: rest =>
    if id.toNat?.isSome then ["job","cancel","--id",id] ++ rest else args
  | "task" :: action :: id :: rest =>
    if ["wait","retry","cancel"].contains action && id.toNat?.isSome then ["task",action,"--id",id] ++ rest else args
  | "fetch" :: tail => legacyRange ["ledger","get"] tail
  | "verify" :: tail => legacyRange ["ledger","verify"] tail
  | ["receive",path] => ["ledger","receive","--file",path]
  | "trust" :: idx :: h :: rest => ["ledger","trust","--index",idx,"--hash",h] ++ rest
  | "state" :: action :: rest =>
    if ["new","update"].contains action then ["bundle",action] ++ rest
    else if action == "info" then ["bundle","info"] ++ rest
    else if action == "list" then ["bundle","list"] ++ rest
    else match rest with
      | [idx,h,path] => if action == "import" then ["state","import","--index",idx,"--hash",h,"--file",path] else args
      | _ => args
  | _ => args

/-- Snapshot downloads can take longer than one individual xrpld RPC call. -/
private def api (url method : String) (body : Option Json := none) : IO Json :=
  Http.request url method body 0

private def acquire (url backend bundle kind : String) (body : Json) (detach silent : Bool) : IO Json := do
  let task ← api (url++"/tasks") "POST" (some (obj [("kind",str kind),("request",body)]))
  if detach then return task
  let id ← string task "task_id"
  if !silent then
    (← IO.getStderr).putStrLn s!"Task {id} runs in XLB; Ctrl+C detaches. Inspect with ./xl task show --backend {backend} --bundle {bundle} --id {id}."
  if silent then return ← api (url++"/tasks/"++id++"/wait") "POST" (some (obj []))
  XLC.Fetch.run url (obj []) ("/tasks/"++id++"/stream")

private def hashField (o : CliOptions) : IO (List (String × Json)) := do
  if let some value := o.get "--hash" then return [("ledger_hash",str (← hash value))]
  return []

private def run (backend bundle : String) (bundleExplicit : Bool) (args : List String) : IO UInt32 := do
  let url := backend ++ "/bundles/" ++ bundle
  let taskUrl := if bundleExplicit then url else backend
  let mut result := Json.null
  match normalize args with
  | "bundle" :: action :: rest =>
    if ["show","list","info"].contains action then
      discard <| options rest ["--json"]
      result ← if action == "info" || (action == "show" && bundleExplicit) then api (url++"/state/info") "GET"
        else api (backend++"/bundles") "GET"
    else
      require (["new","update"].contains action) "bundle command must be new, update, or show"
      let o ← options rest ["--index","--transport","--hash","--no-progress","--json","--detach"]
      let mut fields := [("index",str (← o.need "--index"))] ++ (← hashField o)
      if let some transport := o.get "--transport" then
        require (["auto","peer","rpc"].contains transport) "transport must be auto, peer, or rpc"
        fields := ("transport",str transport)::fields
      result ← acquire url backend bundle (if action == "new" then "state_new" else "state_update") (obj fields)
        (o.has "--detach") (o.has "--no-progress")
  | "task" :: "show" :: rest | "task" :: "list" :: rest =>
    let o ← options rest ["--id","--running","--done"]
    require (!(o.has "--running" && o.has "--done")) "select either --running or --done"
    if let some id := o.get "--id" then
      discard <| number id
      require (!o.has "--running" && !o.has "--done") "--id cannot be combined with status filters"
      result ← api (taskUrl++"/tasks/"++id) "GET"
    else
      let tasks ← IO.ofExcept ((← api (taskUrl++"/tasks") "GET").getArr?)
      result := toJson (tasks.filter fun task =>
        let active := ["queued","running"].contains (optString task "status")
        if o.has "--running" then active else if o.has "--done" then !active else true)
  | "task" :: action :: rest =>
    require (["wait","retry","cancel"].contains action) "task command must be show, wait, retry, or cancel"
    let o ← options rest (if action == "wait" then ["--id","--no-progress"] else ["--id"])
    let id ← o.need "--id"
    discard <| number id
    result ← if action == "retry" || action == "cancel" then api (taskUrl++"/tasks/"++id++"/"++action) "POST" (some (obj []))
      else if o.has "--no-progress" then api (taskUrl++"/tasks/"++id++"/wait") "POST" (some (obj []))
      else XLC.Fetch.run taskUrl (obj []) ("/tasks/"++id++"/stream")
  | ["health"] => result ← api (url++"/health") "GET"
  | "export" :: "show" :: rest | "export" :: "list" :: rest =>
    discard <| options rest []
    result ← api (url++"/exports") "GET"
  | "ledger" :: "show" :: rest | "ledger" :: "list" :: rest =>
    let o ← options rest ["--index","--hash"]
    let idx ← (o.get "--index").mapM fun raw => do
      let n ← number raw
      index n
      pure n
    let selected ← (o.get "--hash").mapM hash
    let rows ← IO.ofExcept ((← api (url++"/ledgers") "GET").getArr?)
    result := toJson (rows.filter fun row =>
      (idx.isNone || optString row "ledger_index" == toString idx.get!) &&
      (selected.isNone || optString row "ledger_hash" == selected.get!))
  | "job" :: "cancel" :: rest =>
    let o ← options rest ["--id"]
    let id ← o.need "--id"
    discard <| number id
    result ← api (url++"/jobs/"++id++"/cancel") "POST" (some (obj []))
  | "job" :: "show" :: rest | "job" :: "list" :: rest =>
    let o ← options rest ["--id"]
    let path ← match o.get "--id" with
      | none => pure "/jobs"
      | some id => discard <| number id; pure ("/jobs/"++id)
    result ← api (url++path) "GET"
  | "ledger" :: "get" :: rest =>
    let o ← options rest ["--index","--state","--transport","--hash","--no-progress","--detach"]
    let selector ← o.need "--index"
    let selection ← if selector == "latest" then pure [("from",str "latest")] else do
      let (first,last) ← interval selector
      require ((o.get "--hash").isNone || first == last) "--hash requires a single ledger"
      pure [("from",toJson first),("to",toJson last)]
    let mut fields := selection ++ [("state",.bool (o.has "--state"))] ++ (← hashField o)
    if let some transport := o.get "--transport" then
      require (["auto","peer","rpc"].contains transport) "transport must be auto, peer, or rpc"
      fields := ("transport",str transport)::fields
    result ← acquire url backend bundle "fetch" (obj fields) (o.has "--detach") (o.has "--no-progress")
  | "ledger" :: "receive" :: rest =>
    let o ← options rest ["--file"]
    result ← api (url++"/ledgers") "POST" (some (← fileJson (← o.need "--file")))
  | "state" :: "import" :: rest =>
    let o ← options rest ["--index","--hash","--file"]
    let idx ← number (← o.need "--index")
    index idx
    let h ← hash (← o.need "--hash")
    let nodes ← array (← fileJson (← o.need "--file")) "nodes"
    result ← api (url++"/state") "POST" (some (obj [("ledger_index",toJson idx),("ledger_hash",str h),("nodes",toJson nodes)]))
  | "ledger" :: "trust" :: rest =>
    let o ← options rest ["--index","--hash","--reason"]
    let idx ← number (← o.need "--index")
    index idx
    let h ← hash (← o.need "--hash")
    result ← api (url++"/trust") "POST" (some (obj [("ledger_index",toJson idx),("ledger_hash",str h),
      ("reason",str ((o.get "--reason").getD "operator decision"))]))
  | "ledger" :: "verify" :: rest =>
    let o ← options rest ["--index","--checks","--hash","--export-id"]
    let (first,last) ← interval (← o.need "--index")
    let checks := (← o.need "--checks").splitOn ","
    require (!checks.isEmpty && checks.all (["merkle","payments"].contains ·)) "select --checks merkle, payments, or merkle,payments"
    require ((o.get "--hash").isNone || (o.get "--export-id").isNone) "select either --hash or --export-id"
    require (((o.get "--hash").isNone && (o.get "--export-id").isNone) || first == last) "--hash and --export-id require a single ledger"
    let mut fields := [("from",toJson first),("to",toJson last),("checks",toJson checks)] ++ (← hashField o)
    if let some id := o.get "--export-id" then fields := ("export_id",toJson (← number id))::fields
    result ← api (url++"/jobs") "POST" (some (obj fields))
  | "serve" :: rest =>
    let child ← IO.Process.spawn {cmd := ".lake/build/bin/xlb",args := rest.toArray}
    return ← child.wait
  | _ => throw <| IO.userError usage
  IO.println result.pretty
  return 0

def main (args : List String) : IO UInt32 := do
  -- Foreground server options (including --help) belong to XLB.
  if args.head? != some "serve" && (args.isEmpty || args.contains "--help" || args.contains "-h") then
    IO.println usage
    return 0
  try
    let mut backend := "http://127.0.0.1:4001"
    let mut bundle := "default"
    let mut bundleExplicit := false
    let mut backendExplicit := false
    let mut rest := args
    let mut command : List String := []
    while !rest.isEmpty do
      match rest with
      | "--backend" :: value :: tail =>
        require (!backendExplicit) "duplicate option: --backend"
        require (!value.isEmpty && !value.startsWith "--") "missing value for --backend"
        backend := value; backendExplicit := true; rest := tail
      | "--bundle" :: value :: tail | "-b" :: value :: tail =>
        require (!bundleExplicit) "duplicate option: --bundle"
        require (!value.isEmpty && !value.startsWith "--") "missing value for --bundle"
        bundle := value; bundleExplicit := true; rest := tail
      | ["--backend"] | ["--bundle"] | ["-b"] => throw <| IO.userError s!"missing value for {rest.head!}"
      | key :: value :: tail =>
        if valueOptions.contains key then
          command := command ++ [key,value]; rest := tail
        else command := command ++ [key]; rest := value::tail
      | item :: tail => command := command ++ [item]; rest := tail
      | [] => pure ()
    require (validBundle bundle) "invalid bundle name"
    run backend bundle bundleExplicit command
  catch error => (← IO.getStderr).putStrLn error.toString; return 1
