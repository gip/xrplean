import Std.Async
import LeanXRPL.Handshake

namespace LeanXRPL
open Std.Async Std.Net

structure Connection where
  socket : TCP.Socket.Client
  tls : Native.TLS

private def flushTLS (c : Connection) : Async Unit := do
  let bytes ← Native.tlsDrain c.tls
  if bytes.size > 0 then c.socket.send bytes

private inductive ReceiveEvent where
  | data (bytes : Option ByteArray)
  | timeout

private def receiveUntil (socket : TCP.Socket.Client) (deadline : Nat) : Async (Option ByteArray) := do
  let now ← IO.monoMsNow
  if now ≥ deadline then return none
  let timer ← Selector.sleep (.ofInt (Int.ofNat (deadline-now)))
  let event ← Selectable.one #[
    .case (socket.recvSelector 16384) (fun b => pure (.data b)),
    .case timer (fun _ => pure .timeout)]
  match (event : ReceiveEvent) with
  | .timeout => return none
  | .data none => throw <| IO.userError "TCP peer closed"
  | .data (some bytes) => return some bytes

/-- Serialized TLS processing: the session is the sole owner of the OpenSSL object. -/
partial def Connection.readUntil (c : Connection) (deadline : Nat) : Async (Option ByteArray) := do
  if let some plain ← Native.tlsRead c.tls then
    flushTLS c
    return some plain
  flushTLS c
  let some encrypted ← receiveUntil c.socket deadline | return none
  Native.tlsFeed c.tls encrypted
  c.readUntil deadline

private def sendPlain (c : Connection) (bytes : ByteArray) : Async Unit := do
  Native.tlsWrite c.tls bytes
  flushTLS c

def Connection.sendControl (c : Connection) (action : OutboundControl) : Async Unit :=
  sendPlain c action.encode

def Connection.sendAction (c : Connection) (action : OutboundAction) : Async Unit := do
  match action with
  | .control _ => pure ()
  | .ledgerBase hash =>
    if hash.size != 32 then throw <| IO.userError "invalid ledger request hash"
  | .transactionNodes hash ids =>
    if hash.size != 32 || ids.isEmpty || ids.size > 16 || ids.any (·.size != 33) then
      throw <| IO.userError "invalid transaction-tree request"
  | .stateNodes hash sequence ids depth =>
    if hash.size != 32 || sequence == 0 || sequence > 4294967295 ||
        ids.isEmpty || ids.size > 256 || depth > 3 || ids.any (·.size != 33) then
      throw <| IO.userError "invalid state-tree request"
  | .stateObjects hash sequence nodes =>
    if hash.size != 32 || sequence == 0 || sequence > 4294967295 || nodes.isEmpty ||
        nodes.size > 64 || nodes.any (fun (id, h) => id.size != 33 || h.size != 32) then
      throw <| IO.userError "invalid state-object request"
  sendPlain c action.encode

def Connection.release (c : Connection) : Async Unit := do
  Native.tlsRelease c.tls
  try c.socket.shutdown catch _ => pure ()

private partial def handshakeTLS (c : Connection) (deadline : Nat) : Async Unit := do
  let done ← Native.tlsHandshake c.tls
  flushTLS c
  if done then return
  let some encrypted ← receiveUntil c.socket deadline | throw <| IO.userError "TLS handshake timeout"
  Native.tlsFeed c.tls encrypted
  handshakeTLS c deadline

private partial def readHTTP (c : Connection) (deadline : Nat) (buffer := ByteArray.empty) (allowRepeated := false) : Async HttpResponse := do
  if let some response ← IO.ofExcept (parseHttp buffer allowRepeated) then return response
  let some bytes ← c.readUntil deadline | throw <| IO.userError "HTTP upgrade timeout"
  readHTTP c deadline (buffer ++ bytes) allowRepeated

/-- Bound redirect bodies; support Content-Length, chunked, and EOF framing. -/
def decodeChunkedBody (bytes : ByteArray) (limit := 65536) : ParseResult (Option ByteArray) := do
  let mut c : Cursor := ⟨bytes, 0, by omega⟩
  let mut out := ByteArray.empty
  for _ in [:bytes.size] do
    let tail := String.fromUTF8! (bytes.extract c.pos bytes.size)
    let line := (tail.splitOn "\r\n").head!
    if line.length == tail.length then return none
    let sizeStr := (line.splitOn ";").head!
    let mut size := 0
    if sizeStr.isEmpty || sizeStr.length > 8 then throw "invalid chunk size"
    for ch in sizeStr.toList do
      let nibble ← match unhex ("0" ++ String.singleton ch) with
        | .ok b => pure b[0]!.toNat | .error e => throw e
      size := size*16+nibble
    if size > limit || out.size+size > limit then throw "HTTP chunked body too large"
    c := (← c.take (line.utf8ByteSize+2)).2
    if c.remaining < size+2 then return none
    let (part, next) ← c.take size
    let (crlf, next) ← next.take 2
    if crlf != byteArray [13,10] then throw "invalid chunk terminator"
    out := out ++ part
    c := next
    if size == 0 then return some out
  return none

private partial def redirectBody (c : Connection) (r : HttpResponse) (deadline : Nat)
    (buffer : ByteArray) : Async ByteArray := do
  if buffer.size > 65536 then throw <| IO.userError "redirect body too large"
  let encoding := (r.header "transfer-encoding").toLower
  if !encoding.isEmpty && encoding != "chunked" then throw <| IO.userError "unsupported HTTP body encoding"
  if encoding == "chunked" then
    if let some body ← IO.ofExcept (decodeChunkedBody buffer) then return body
  else
    let len := r.header "content-length"
    if !len.isEmpty then
      let some len := len.toNat? | throw <| IO.userError "invalid Content-Length"
      if len > 65536 then throw <| IO.userError "redirect body too large"
      if buffer.size ≥ len then return buffer.extract 0 len
    else
      if let .ok _ := parseRedirects buffer then return buffer
  let next ← c.readUntil deadline
  let some next := next | throw <| IO.userError "redirect body timeout"
  redirectBody c r deadline (buffer ++ next)

inductive ConnectResult where
  | peer (connection : Connection) (identity : String) (tail : ByteArray)
  | redirects (endpoints : Array Endpoint)

def connectPeer (endpoint : Endpoint) (key : Std.Mutex Native.NodeKey)
    (selfPublic : ByteArray) (networkID : Nat) (networkPermits : Std.Semaphore) : Async ConnectResult := do
  if !(← networkPermits.tryAcquire) then throw <| IO.userError "DNS/TCP attempts still pending"
  let deadline := (← IO.monoMsNow) + 15000
  let socket ← try TCP.Socket.Client.mk catch e => do
    networkPermits.release
    throw e
  -- Std.Async's race does not cancel DNS/connect. The losing operation has no session side effects
  -- and only retains its socket until the OS completes it; pending operations are separately capped.
  let remote ← Async.race (do
    try
      let ips ← DNS.getAddrInfo endpoint.host (toString endpoint.port)
      let some ip := ips.find? (fun ip => endpoint.explicit || publicIP ip)
        | throw <| IO.userError "no admissible resolved address"
      let address := match ip with
        | .v4 a => SocketAddress.v4 ⟨a, endpoint.port⟩
        | .v6 a => SocketAddress.v6 ⟨a, endpoint.port⟩
      socket.connect address
      pure ip
    finally networkPermits.release) (do
      sleep (.ofInt 15000)
      throw <| IO.userError "DNS/TCP connect timeout")
  let tls ← Native.tlsNew endpoint.host
  let connection := Connection.mk socket tls
  try
    handshakeTLS connection deadline
    let digest ← sessionDigest (← Native.tlsFinished tls false) (← Native.tlsFinished tls true)
    let request ← key.atomically do
      makeUpgrade (← get) digest (toString endpoint) networkID
    sendPlain connection request
    let response ← readHTTP connection deadline
    if response.status == 503 then
      let body ← redirectBody connection response deadline response.tail
      let endpoints ← IO.ofExcept (parseRedirects body)
      connection.release
      return .redirects endpoints
    let identity ← verifyUpgrade response digest selfPublic networkID (← networkTime) remote
    return .peer connection identity response.tail
  catch e =>
    connection.release
    throw e

/-- Signed validator-list retrieval uses the same Lean-owned TLS transport.
The publisher signature is the authentication boundary, including on peer-port sites. -/
private def fetchValidatorListImpl : Async String := do
  let socket ← TCP.Socket.Client.mk
  let deadline := (← IO.monoMsNow)+15000
  let ips ← DNS.getAddrInfo "unl.xrplf.org" "443"
  let some ip := ips.find? publicIP | throw <| IO.userError "validator-list DNS failed"
  let address := match ip with
    | .v4 a => SocketAddress.v4 ⟨a, 443⟩
    | .v6 a => SocketAddress.v6 ⟨a, 443⟩
  socket.connect address
  let c := Connection.mk socket (← Native.tlsNew "unl.xrplf.org")
  try
    handshakeTLS c deadline
    sendPlain c "GET / HTTP/1.1\r\nHost: unl.xrplf.org\r\nConnection: close\r\nAccept-Encoding: identity\r\n\r\n".toUTF8
    let response ← readHTTP c deadline ByteArray.empty true
    if response.status != 200 then throw <| IO.userError s!"validator-list HTTP {response.status}"
    let mut buffer := response.tail
    for _ in [:4096] do
      if buffer.size > 1048576 then throw <| IO.userError "validator-list response too large"
      let body ← if (response.header "transfer-encoding").toLower == "chunked" then
        IO.ofExcept (decodeChunkedBody buffer 1048576)
      else if let some size := (response.header "content-length").toNat? then
        if size > 1048576 then throw <| IO.userError "validator-list Content-Length limit"
        pure (if buffer.size ≥ size then some (buffer.extract 0 size) else none)
      else
        pure (if (Lean.Json.parse (String.fromUTF8! buffer)).isOk then some buffer else none)
      if let some body := body then
        let some text := String.fromUTF8? body | throw <| IO.userError "invalid validator-list UTF8"
        return text
      let some next ← c.readUntil deadline | throw <| IO.userError "validator-list read timeout"
      buffer := buffer ++ next
    throw <| IO.userError "validator-list response limit"
  finally c.release

def fetchValidatorList (permits : Std.Semaphore) : Async String := do
  if !(← permits.tryAcquire) then throw <| IO.userError "validator-list DNS/TCP work still pending"
  Async.race (do
    try fetchValidatorListImpl finally permits.release) (do
    sleep (.ofInt 15000)
    throw <| IO.userError "validator-list download timeout")

end LeanXRPL
