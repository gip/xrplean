import XL.Basic

namespace XL.Http
open Lean LeanXRPL Std.Async Std.Net

structure Request where
  method : String
  path : String
  body : Json

structure Response where
  status : Nat := 200
  body : Json := .null
  stream : Option ((Json → Async Unit) → Async Unit) := none

private def parseHeader (bytes : ByteArray) : Except String (Option (String × String × Nat × ByteArray)) := do
  let mut boundary := none
  for i in [:min bytes.size 32772] do
    if i+3 < bytes.size && bytes[i]! == 13 && bytes[i+1]! == 10 && bytes[i+2]! == 13 && bytes[i+3]! == 10 then
      boundary := some (i+4); break
  let some endPos := boundary | do
    if bytes.size > 32768 then throw "header too large"
    return none
  if endPos > 32768 then throw "header too large"
  let some text := String.fromUTF8? (bytes.extract 0 (endPos-4)) | throw "invalid UTF-8 headers"
  let lines := text.splitOn "\r\n"
  let [method,path,version] := lines.head!.splitOn " " | throw "invalid request line"
  if version != "HTTP/1.1" && version != "HTTP/1.0" then throw "invalid HTTP version"
  let mut headers : List (String × String) := []
  for line in lines.tail do
    let parts := line.splitOn ":"
    if parts.length < 2 then throw "invalid header"
    let name := parts.head!.toLower
    if name.isEmpty || name.toList.any (fun c => !(c.isAlphanum || c == '-')) then throw "invalid header name"
    let value := (String.intercalate ":" parts.tail).trimAscii.toString
    if value.toList.any (fun c => c.toNat < 32 || c.toNat == 127) then throw "invalid header value"
    if headers.any (·.1 == name) then throw "duplicate header"
    headers := (name,value) :: headers
  if headers.any (fun (k,_) => k == "transfer-encoding" || k == "expect" || k == "content-encoding") then
    throw "unsupported framing or encoding"
  let value := fun key => headers.find? (·.1 == key) |>.map (·.2)
  let length ← match value "content-length" with
    | none => if method == "GET" then pure 0 else throw "content-length required"
    | some raw => do
      if raw.isEmpty || !raw.toList.all Char.isDigit then throw "invalid content-length"
      match raw.toNat? with
      | some n => pure n
      | none => throw "invalid content-length"
  if length > 64*1024*1024 then throw "body exceeds 64 MiB"
  if length > 0 && !(value "content-type").any (fun v => (v.splitOn ";").head!.trimAscii.toString.toLower == "application/json") then
    throw "application/json required"
  return some (method,path,length,bytes.extract endPos bytes.size)

private def recv (socket : TCP.Socket.Client) (stop : IO.Ref Bool) (deadline : Nat) : Async ByteArray := do
  let pending ← socket.native.recv? 65536
  while !(← pending.isResolved) do
    if (← stop.get) || (← IO.monoMsNow) ≥ deadline then
      socket.native.cancelRecv
      throw <| IO.userError "request timed out or backend stopping"
    sleep (.ofInt 10)
  let some bytes ← Async.ofPromise (pure pending) | throw <| IO.userError "connection closed"
  return bytes

private def readRequest (socket : TCP.Socket.Client) (stop : IO.Ref Bool) : Async Request := do
  let deadline := (← IO.monoMsNow)+30000
  let mut buffer := ByteArray.empty
  let mut header := none
  while header.isNone do
    header ← IO.ofExcept (parseHeader buffer)
    if header.isNone then buffer := buffer ++ (← recv socket stop deadline)
  let some (method,path,length,initial) := header | throw <| IO.userError "missing header"
  let mut body := initial
  while body.size < length do body := body ++ (← recv socket stop deadline)
  require (body.size == length) "request framing mismatch"
  let json ← if length == 0 then pure .null else do
    let some text := String.fromUTF8? body | throw <| IO.userError "invalid UTF-8 JSON"
    IO.ofExcept (Json.parse text)
  return ⟨method,path,json⟩

private def send (socket : TCP.Socket.Client) (response : Response) : Async Unit := do
  let text := if response.status == 204 then "" else response.body.compress
  let reason := match response.status with
    | 200 => "OK" | 201 => "Created" | 202 => "Accepted" | 204 => "No Content"
    | 400 => "Bad Request" | 404 => "Not Found" | 409 => "Conflict" | 422 => "Unprocessable Content"
    | _ => "Service Unavailable"
  socket.send s!"HTTP/1.1 {response.status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {text.utf8ByteSize}\r\nConnection: close\r\n\r\n{text}".toUTF8

/-- Close-delimited NDJSON allows progress without buffering the complete response. -/
private def sendStream (socket : TCP.Socket.Client)
    (stream : (Json → Async Unit) → Async Unit) : Async Unit := do
  socket.send "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".toUTF8
  let emit := fun event => socket.send (event.compress ++ "\n").toUTF8
  try stream emit
  catch error =>
    try emit (obj [("event",str "error"),("error",str error.toString)])
    catch _ => pure ()

private def serve (socket : TCP.Socket.Client) (stop : IO.Ref Bool) (working : Std.Mutex Nat)
    (handler : Request → IO Response) : Async Unit := do
  try
    let request ← readRequest socket stop
    -- Keep liveness available when all application slots have long-running
    -- requests/observers. Reject excess work before invoking any mutation.
    let health := request.method == "GET" && request.path == "/health"
    let admitted ← if health then pure true else working.atomically do
      if (← getThe Nat) ≥ 8 then return false
      modify (·+1)
      return true
    if !admitted then
      send socket ⟨503,obj [("error",str "XLB is busy; request was not submitted. Inspect task/job history before submitting again.")],none⟩
    else
      try
        let task ← IO.asTask (handler request) (prio := .dedicated)
        let response ← IO.ofExcept (← Async.ofTask task)
        match response.stream with
        | some stream => sendStream socket stream
        | none => send socket response
      finally
        if !health then working.atomically (modify (·-1))
  catch error =>
    try send socket ⟨400,obj [("error",str error.toString)],none⟩ catch _ => pure ()
  finally
    try socket.shutdown catch _ => pure ()

def listen (endpoint : String) : IO TCP.Socket.Server := do
  let e ← IO.ofExcept (parseEndpoint endpoint)
  let some ip := endpointIP e | throw <| IO.userError "listen requires numeric loopback address"
  require (e.host == "127.0.0.1" || e.host == "::1") "v1 binds to loopback only"
  let server ← TCP.Socket.Server.mk
  server.bind (match ip with | .v4 a => .v4 ⟨a,e.port⟩ | .v6 a => .v6 ⟨a,e.port⟩)
  server.listen 16
  return server

def run (server : TCP.Socket.Server) (stop : IO.Ref Bool) (handler : Request → IO Response) : Async Unit := do
  let active ← Std.Mutex.new (0 : Nat)
  let working ← Std.Mutex.new (0 : Nat)
  try
    while !(← stop.get) do
      if (← active.atomically (getThe Nat)) ≥ 16 then sleep (.ofInt 100); continue
      -- Polling preserves accepted sockets: cancelling an acceptSelector in a
      -- timer race can discard a connection already accepted by the native layer.
      let socket ← server.tryAccept
      if let some socket := socket then
        active.atomically (modify (·+1))
        background do
          try serve socket stop working handler
          finally active.atomically (modify (·-1))
      else sleep (.ofInt 10)
  finally
    stop.set true
    while (← active.atomically (getThe Nat)) > 0 do sleep (.ofInt 20)

/-- curl is transport only; Lean constructs and validates all RPC/API JSON. -/
def request (url method : String) (body : Option Json := none) (timeoutSeconds : Nat := 120) : IO Json := do
  require (url.startsWith "http://" || url.startsWith "https://") "expected HTTP(S) URL"
  let args := #["--silent","--show-error","--fail-with-body","--max-time",toString timeoutSeconds,
    "--max-filesize","67108864","--request",method,"--header","Content-Type: application/json"] ++
    (if body.isSome then #["--data-binary","@-"] else #[]) ++ #["--url",url]
  let result ← IO.Process.output {cmd := "curl",args} (body.map Json.compress)
  require (result.exitCode == 0) s!"HTTP request failed: {result.stderr} {result.stdout.take 2000}"
  if result.stdout.isEmpty then return .null
  IO.ofExcept (Json.parse result.stdout)

/-- Read one event at a time; curl does not buffer progress and stdout stays bounded. -/
def streamRequest (url : String) (body : Json) (onEvent : Json → IO Unit) : IO Unit := do
  require (url.startsWith "http://" || url.startsWith "https://") "expected HTTP(S) URL"
  let child ← do
    let (input, child) ← (← IO.Process.spawn {
      cmd := "curl"
      args := #["--silent","--show-error","--fail-with-body","--no-buffer","--max-time","0","--request","POST",
        "--header","Content-Type: application/json","--data-binary","@-","--url",url]
      stdin := .piped
      stdout := .piped
      stderr := .piped }).takeStdin
    input.putStr body.compress
    input.flush
    pure child
  let errors ← IO.asTask child.stderr.readToEnd (prio := .dedicated)
  let finished ← IO.mkRef false
  try
    repeat
      let line ← child.stdout.getLine
      if line.isEmpty then break
      let text := line.trimAscii.toString
      if !text.isEmpty then onEvent (← IO.ofExcept (Json.parse text))
    let code ← child.wait
    finished.set true
    let stderr ← IO.ofExcept errors.get
    require (code == 0) s!"HTTP progress request failed: {stderr}"
  finally
    if !(← finished.get) then
      try child.kill catch _ => pure ()
      try discard <| child.wait catch _ => pure ()


end XL.Http
