# ADR-0012: AES-256-GCM Codec Framing and Key Rotation

- **Status:** Accepted
- **Date:** 2026-07-05
- **Deciders:** BSE Framework Team
- **Tags:** rpc, security, encryption, aes-gcm, key-rotation

## Context

ADR-0011 established that RPC envelopes traveling over Redis Streams must be encrypted and
compressed. It recorded the *what* (AES-256-GCM + Brotli, via `EncryptedBrotliCodec`) but
deferred the *how* of wire framing and key lifecycle to a follow-on decision.

Two operational realities drive this ADR:

1. **Key rotation.** A service that can only decrypt with the key currently in use cannot
   roll over to a new key without dropping any in-flight messages encrypted under the old one.
   The wire format must carry enough information for the receiver to select the correct
   decryption key.

2. **Integrity-oracle prevention.** Propagating `CryptographicException` details to callers
   (even internal callers) can enable padding-oracle-style timing or message attacks. The codec
   must surface a generic failure instead.

## Decision

`EncryptedBrotliCodec` uses a **versioned, key-id-prefixed wire frame** as the unit of
encryption. The complete frame layout is:

```
[1 byte  version = 0x01]
[1 byte  keyIdLen]
[N bytes keyId UTF-8]
[12 bytes nonce — CSPRNG per message]
[ciphertext || 16 bytes GCM tag]
```

The first two fields (version + keyIdLen + keyId bytes) are bound as **AES-GCM additional
authenticated data (AAD)**, so any tampering with the key-identity header is caught by the
GCM tag:

```csharp
// AAD = [version(1) | keyIdLen(1) | keyId bytes]
var aad = new byte[1 + 1 + keyIdBytes.Length];
aad[0] = version;
aad[1] = (byte)keyIdBytes.Length;
keyIdBytes.CopyTo(aad, 2);
```

Key material is supplied by `IRpcKeyProvider`. Two built-in implementations cover the common
cases:

- `EnvironmentRpcKeyProvider` — reads `BSE_RPC_KEY_ID` and `BSE_RPC_KEY_MATERIAL_BASE64`
  at construction time; intended for development and CI only (no rotation support).
- `RotatingRpcKeyProvider(keys, currentKeyId)` — holds an ordered list of `RpcKey` values;
  one is designated *current* (used for all new encryptions); the rest remain available for
  decryption until their in-flight messages have drained.

On decode, the codec reads `keyId` from the frame header, calls
`IRpcKeyProvider.GetKeyByIdAsync(keyId)`, and fails with a generic
`BseRpcCodecException("Key '{id}' is not known…")` if the key is absent. GCM authentication
failure is caught and re-thrown as a generic `BseRpcCodecException("Payload authentication
failed…")` — the underlying `CryptographicException` is never propagated.

## Options Considered

### Option A: AES-CBC + separate HMAC
- **Pros:** Widely understood, compatible with older .NET runtimes
- **Cons:** Requires correct IV management and separate MAC computation; CBC + HMAC is
  error-prone to compose correctly; GCM supersedes it for new systems on .NET 9

### Option B: AES-GCM without key-id framing (no rotation)
- **Pros:** Simpler frame — just nonce + ciphertext + tag
- **Cons:** Rotation requires a coordinated cutover at a specific instant; any message
  in-flight during the cutover is unreadable; operationally unacceptable for a messaging system

### Option C: Versioned AES-256-GCM frame with keyId + AAD (chosen)
- **Pros:** Key rotation is a sliding-window operation — old keys stay valid for decrypt while
  the current key advances; AAD binds the version and key-identity metadata into the
  authentication tag; generic `BseRpcCodecException` prevents information leakage
- **Cons:** Frame header grows by 2 + keyIdLen bytes; keyId length is capped at 255 UTF-8
  bytes by the single-byte length field

## Rationale

Authenticated encryption (AEAD) eliminates the separate MAC step while providing both
confidentiality and integrity. Binding the header bytes as AAD prevents a class of attacks
where an attacker swaps the keyId field to force decryption under a different key. The
keyId-in-frame design lets operators rotate keys by adding a new entry to
`RotatingRpcKeyProvider` and advancing `currentKeyId`, with zero downtime — old keys drain
naturally as in-flight messages are consumed.

## Consequences

### Positive
- Key rotation is a first-class, zero-downtime operation: old keys continue to decrypt while
  the current key encrypts; remove a key only after all in-flight messages have been acked
- GCM tag covers both the ciphertext and the framing header (version + keyId) — tampering with
  any byte fails authentication
- `BseRpcCodecException` is the single error type callers handle; no crypto internals leak

### Negative
- `RotatingRpcKeyProvider` holds all key material in managed heap memory; deployments with
  memory-residency requirements (zeroize on rotation) must wrap a hardware-backed provider
  (KMS, HSM, or Vault) — the no-zeroize contract is documented on `IRpcKeyProvider`
- keyId is capped at 255 bytes; longer identifiers (e.g., full KMS ARNs) must be shortened
  or hashed to a stable alias

### Neutral
- The `IdentityCodec` (pass-through, no encryption) remains available for in-process and test
  scenarios where transport-layer encryption is unnecessary
- Wire format version `0x01` is the only supported version; unknown versions throw immediately
  on `ParseFrame` so future formats can be introduced without silent misparses

## References

- ADR-0011: RPC Payload Encryption and Compression
- RFC-0002: RPC and Distributed Computing
- `Bse.Framework.Rpc/Codec/EncryptedBrotliCodec.cs`
- `Bse.Framework.Rpc/Codec/IRpcKeyProvider.cs`
- `Bse.Framework.Rpc/Codec/EnvironmentRpcKeyProvider.cs`
- `Bse.Framework.Rpc/Codec/RotatingRpcKeyProvider.cs`
- NIST SP 800-38D — Recommendation for Block Cipher Modes of Operation: GCM
