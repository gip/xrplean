import Std

namespace LeanXRPL.Native

/-- Opaque, explicitly released OpenSSL state. All access is serialized by its session. -/
opaque TLS : Type := Unit
opaque NodeKey : Type := Unit

@[extern "lx_tls_new"] opaque tlsNew (host : @& String) : IO TLS :=
  throw <| IO.userError "native TLS unavailable"
@[extern "lx_tls_feed"] opaque tlsFeed (tls : @& TLS) (bytes : @& ByteArray) : IO Unit :=
  throw <| IO.userError "native TLS unavailable"
@[extern "lx_tls_drain"] opaque tlsDrain (tls : @& TLS) : IO ByteArray :=
  throw <| IO.userError "native TLS unavailable"
@[extern "lx_tls_handshake"] opaque tlsHandshake (tls : @& TLS) : IO Bool :=
  throw <| IO.userError "native TLS unavailable"
@[extern "lx_tls_read"] opaque tlsRead (tls : @& TLS) : IO (Option ByteArray) :=
  throw <| IO.userError "native TLS unavailable"
@[extern "lx_tls_write"] opaque tlsWrite (tls : @& TLS) (bytes : @& ByteArray) : IO Unit :=
  throw <| IO.userError "native TLS unavailable"
@[extern "lx_tls_finished"] opaque tlsFinished (tls : @& TLS) (peer : Bool) : IO ByteArray :=
  throw <| IO.userError "native TLS unavailable"
@[extern "lx_tls_release"] opaque tlsRelease (tls : @& TLS) : IO Unit := pure ()
@[extern "lx_key_load"] opaque keyLoad (path : @& String) : IO NodeKey :=
  throw <| IO.userError "native cryptography unavailable"
@[extern "lx_key_public"] opaque keyPublic (key : @& NodeKey) : IO ByteArray :=
  throw <| IO.userError "native cryptography unavailable"
@[extern "lx_key_sign"] opaque keySign (key : @& NodeKey) (digest : @& ByteArray) : IO ByteArray :=
  throw <| IO.userError "native cryptography unavailable"
@[extern "lx_verify"] opaque verify (pub : @& ByteArray) (digest : @& ByteArray)
    (signature : @& ByteArray) : IO Bool := pure false
@[extern "lx_verify_canonical"] opaque verifyCanonical (pub : @& ByteArray) (digest : @& ByteArray)
    (signature : @& ByteArray) (lowS : Bool) : IO Bool := pure false
@[extern "lx_ed_verify"] opaque edVerify (pub : @& ByteArray) (message : @& ByteArray)
    (signature : @& ByteArray) : IO Bool := pure false
@[extern "lx_sha256"] opaque sha256 (bytes : @& ByteArray) : IO ByteArray :=
  throw <| IO.userError "native cryptography unavailable"
@[extern "lx_sha512"] opaque sha512 (bytes : @& ByteArray) : IO ByteArray :=
  throw <| IO.userError "native cryptography unavailable"
@[extern "lx_random"] opaque random (size : UInt32) : IO ByteArray :=
  throw <| IO.userError "native cryptography unavailable"
@[extern "lx_ripemd160"] opaque ripemd160 (bytes : @& ByteArray) : IO ByteArray :=
  throw <| IO.userError "native cryptography unavailable"
@[extern "lx_secp_public_valid"] opaque secpPublicValid (bytes : @& ByteArray) : IO Bool := pure false

def sha512Half (bytes : ByteArray) : IO ByteArray := do
  return (← sha512 bytes).extract 0 32

end LeanXRPL.Native
