import XL.Basic
import Std.Http.Protocol.H1

namespace XL.Rpc
open Lean Std.Async Std.Net

private def awaitIO (stop : IO.Ref Bool) (deadline : Nat)
    (pending : IO.Promise (Except IO.Error α)) : Async α := do
  require (!(← stop.get)) "acquisition interrupted"
  require ((← IO.monoMsNow) < deadline) "HTTP request timed out"
  while !(← pending.isResolved) do
    require (!(← stop.get)) "acquisition interrupted"
    require ((← IO.monoMsNow) < deadline) "HTTP request timed out"
    sleep (.ofInt 10)
  Async.ofPromise (pure pending)

private def transport (retryable : IO.Ref Bool) (action : Async α) : Async α := do
  try action
  catch error => retryable.set true; throw error

private def retryStatus (status : Nat) : Bool :=
  [408,429,500,502,503,504].contains status

private def connect (addresses : Array IPAddr) (port : UInt16) (stop : IO.Ref Bool)
    (deadline : Nat) : Async TCP.Socket.Client := do
  let mut lastError := IO.userError "RPC hostname has no addresses"
  for address in addresses do
    let socket ← TCP.Socket.Client.mk
    try
      awaitIO stop deadline (← socket.native.connect (match address with
        | .v4 a => .v4 ⟨a,port⟩ | .v6 a => .v6 ⟨a,port⟩))
      return socket
    catch error =>
      lastError := error
      try socket.shutdown catch _ => pure ()
      require (!(← stop.get)) "acquisition interrupted"
  throw lastError

private def https (url : String) (body : Json) (stop retryable : IO.Ref Bool)
    (timeoutMs : Nat) : Async Json := do
  let deadline := (← IO.monoMsNow)+timeoutMs
  let child ← do
    let (input, child) ← (← IO.Process.spawn {cmd := "curl", args := #[
      "--silent","--show-error","--fail-with-body","--max-time",toString (max 1 ((timeoutMs+999)/1000)),"--max-filesize","67108864",
      "--request","POST","--header","Content-Type: application/json","--data-binary","@-",
      "--write-out","\n%{http_code}","--url",url], stdin := .piped, stdout := .piped, stderr := .piped}).takeStdin
    input.putStr body.compress
    input.flush
    pure child
  let output ← IO.asTask child.stdout.readToEnd (prio := .dedicated)
  let errors ← IO.asTask child.stderr.readToEnd (prio := .dedicated)
  let finished ← IO.mkRef false
  try
    let mut code := none
    while code.isNone do
      require (!(← stop.get)) "acquisition interrupted"
      require ((← IO.monoMsNow) < deadline) "HTTP request timed out"
      code ← child.tryWait
      if code.isNone then sleep (.ofInt 50)
    finished.set true
    let stdout ← IO.ofExcept (← Async.ofTask output)
    let stderr ← IO.ofExcept (← Async.ofTask errors)
    let lines := stdout.splitOn "\n"
    let status := lines.getLast!.toNat?.getD 0
    let text := String.intercalate "\n" lines.dropLast
    if code.getD 1 != 0 then
      retryable.set ([5,6,7,18,28,35,52,55,56].contains (code.getD 1).toNat || retryStatus status)
      throw <| IO.userError s!"HTTP request failed: {stderr} {text.take 2000}"
    IO.ofExcept (Json.parse text)
  finally
    if !(← finished.get) then
      try child.kill catch _ => pure ()
      try discard <| child.wait catch _ => pure ()

/-- Native event-loop HTTP, with Std.Http's bounded HTTP/1 response decoder.
    HTTPS retains curl's certificate verification on a separate IO task. -/
private def requestOnce (url : String) (body : Json) (stop retryable : IO.Ref Bool)
    (timeoutMs : Nat := 120000) : Async Json := do
  if url.startsWith "https://" then
    return ← https url body stop retryable timeoutMs
  let some uri := Std.Http.URI.parse? url | throw <| IO.userError "invalid RPC URL"
  require (toString uri.scheme == "http") "expected HTTP(S) RPC URL"
  let some authority := uri.authority | throw <| IO.userError "RPC URL requires a host"
  require (authority.userInfo.isNone && uri.fragment.isNone) "RPC URL must not contain credentials or a fragment"
  let port := match authority.port with | .value n => n | _ => 80
  let deadline := (← IO.monoMsNow)+timeoutMs
  let addresses ← match authority.host with
    | .ipv4 a => pure #[IPAddr.v4 a]
    | .ipv6 a => pure #[IPAddr.v6 a]
    | .name name => transport retryable (awaitIO stop deadline
        (← Std.Internal.UV.DNS.getAddrInfo (toString name) (toString port) 0))
  let socket ← transport retryable (connect addresses port stop deadline)
  try
    let path := if uri.path.isEmpty then "/" else toString uri.path
    let target := path ++ Std.Http.URI.Query.formatOption uri.query
    let text := body.compress
    let wire := s!"POST {target} HTTP/1.1\r\nHost: {authority}\r\nContent-Type: application/json\r\nContent-Length: {text.utf8ByteSize}\r\nConnection: close\r\n\r\n{text}"
    transport retryable <| awaitIO stop deadline (← socket.native.send #[wire.toUTF8])
    let mut machine : Std.Http.Protocol.H1.Machine .sending := {
      config := {enableKeepAlive := false, maxHeaderBytes := 32768}
      reader := {state := .needStartLine}
      writer := {state := .complete, messageHead := {method := .post, version := .v11}} }
    let mut status := 0
    let mut bytes := ByteArray.empty
    let mut eof := false
    repeat
      require (!(← stop.get)) "acquisition interrupted"
      require ((← IO.monoMsNow) < deadline) "HTTP request timed out"
      let (next, events) := machine.step
      machine := next
      let mut needInput := false
      for event in events.events do
        match event with
        | .endHeaders head => status := head.status.toCode.toNat
        | .needMoreData _ => needInput := true
        | .failed error => throw <| IO.userError s!"invalid RPC HTTP response: {repr error}"
        | _ => pure ()
      repeat
        let (next, chunk) := machine.pullBody
        machine := next
        let some chunk := chunk | break
        bytes := bytes ++ chunk.chunk.data
        require (bytes.size ≤ 64*1024*1024) "RPC response exceeds 64 MiB"
        if chunk.final && status ≥ 200 then
          let some text := String.fromUTF8? bytes | throw <| IO.userError "invalid UTF-8 RPC response"
          retryable.set (retryStatus status)
          require (status < 300) s!"HTTP request failed: status {status}: {text.take 2000}"
          return ← IO.ofExcept (Json.parse text)
      if machine.failed then throw <| IO.userError s!"invalid RPC HTTP response: {repr machine.error}"
      if eof && (machine.isReaderClosed || machine.isReaderComplete) then
        throw <| IO.userError "RPC connection closed before a complete response"
      if needInput || machine.reader.input.atEnd || machine.pullBodyStalled then
        let incoming ← transport retryable <| awaitIO stop deadline (← socket.native.recv? 65536)
        match incoming with
        | some data => machine := machine.feed data
        | none =>
          eof := true
          retryable.set true
          machine := machine.noMoreInput
  finally
    socket.native.cancelRecv
    try socket.shutdown catch _ => pure ()

/-- A bounded observation; unlike acquisition, it never retries an upstream outage. -/
def observe (c : Config) (body : Json) (stop : IO.Ref Bool) : Async Json := do
  requestOnce c.rpc body stop (← IO.mkRef false) 3000

/-- Transient failures retry until recovery or shutdown. The delay saturates at
    the cap, and every attempt reuses the exact JSON request. -/
def request (c : Config) (body : Json) (stop : IO.Ref Bool)
    (onRetry : Nat → Nat → String → IO Unit := fun _ _ _ => pure ()) : Async Json := do
  let mut attempt := 0
  let cap := max 1000 (min 30000 (c.rpcBackoffMax*1000))
  let mut delay := 1000
  repeat
    require (!(← stop.get)) "acquisition interrupted"
    let retryable ← IO.mkRef false
    try return ← requestOnce c.rpc body stop retryable
    catch error =>
      if (← stop.get) || !(← retryable.get) then throw error
      attempt := attempt+1
      onRetry attempt delay error.toString
      let deadline := (← IO.monoMsNow)+delay
      while (← IO.monoMsNow) < deadline do
        require (!(← stop.get)) "acquisition interrupted"
        sleep (.ofInt 50)
      delay := min cap (delay*2)

end XL.Rpc
