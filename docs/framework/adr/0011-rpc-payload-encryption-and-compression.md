# ADR-0011: Encrypt and Compress RPC Payloads in Transit

- **Status:** Accepted
- **Date:** 2026-05-15
- **Deciders:** BSE Framework Team
- **Tags:** rpc, security, encryption, compression

## Context

RFC-0002 specifies JSON-RPC 2.0 over multiple transports (Redis Streams, HTTP, In-Memory). Two
cross-cutting concerns for production deployment were left under-specified:

1. **Confidentiality of payloads in transit.** Redis is typically deployed inside a trusted network,
   but "trusted network" is a security smell — Redis credentials get leaked, replicas get exposed by
   misconfiguration, log captures from network appliances harvest unencrypted payloads. HTTP
   transport benefits from TLS at the edge, but ingress termination and service-mesh hops
   re-expose cleartext to operators and sidecars. Defense-in-depth requires payload-level
   encryption independent of transport-level TLS.
2. **Payload size on the wire.** JSON-RPC payloads are verbose by design (field names repeated,
   no schema). For high-throughput streams the bandwidth and Redis-memory cost is material.

The framework needs a uniform, transport-agnostic answer. Per-transport encryption (TLS in HTTP,
ad-hoc encryption-at-rest in Redis) leaves gaps and produces inconsistent semantics across
deployment topologies.

## Decision

All RPC messages flowing through `Bse.Framework.Rpc` are **compressed then encrypted** at the
envelope layer before reaching any transport. The transport sees only opaque ciphertext bytes.

**Order: compress → encrypt** (not the reverse). Encryption produces high-entropy bytes that do
not compress; compression must run first to do useful work.

**Compression:** [Brotli](https://datatracker.ietf.org/doc/html/rfc7932) at `CompressionLevel.Fastest`
(Brotli internal quality 1 — fastest while still meaningfully shrinking JSON). Implemented via
`System.IO.Compression.BrotliStream`.

**Encryption:** [AES-256-GCM](https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38d.pdf)
— authenticated encryption (AEAD), NIST-blessed, single-pass, implemented via
`System.Security.Cryptography.AesGcm`.

- **Nonce:** 96-bit random, generated per message with `RandomNumberGenerator.Fill`.
- **Tag:** 128-bit GCM authentication tag, appended after the ciphertext.
- **AAD (Additional Authenticated Data):** the version byte and key-ID framing bytes. Tampering
  with the routing header invalidates the tag.

**Key management:** the framework defines `IRpcKeyProvider` with two implementations:

- `EnvironmentRpcKeyProvider` — reads a base64-encoded key from `BSE_RPC_KEY_<context>` for
  development and simple deployments.
- `RotatingRpcKeyProvider` — wraps any key source with a "current + previous" key window so
  rotation does not reject in-flight messages. Configured via `BseRpcBuilder.UseRotatingKeys(...)`.

KMS / Vault-backed providers (`Bse.Framework.Rpc.Security.Aws`, `...AzureKeyVault`,
`...HashicorpVault`) are out of scope for v0.1.0 but the `IRpcKeyProvider` abstraction lands now
so they slot in without breaking changes.

**Wire format** produced by `EncryptedBrotliCodec` (`Bse.Framework.Rpc`):

```
[1 byte  version = 0x01]
[1 byte  keyIdLen]
[N bytes keyId (UTF-8, max 255 bytes)]
[12 bytes nonce]
[ciphertext bytes]
[16 bytes GCM authentication tag]
```

The `keyId` framing enables key rotation: the decoder reads the key ID, resolves the matching
`RpcKey` from `IRpcKeyProvider`, and decrypts. Keys retired from encryption can remain registered
for decryption until all in-flight messages have drained.

The version byte enables future algorithm migration without breaking existing decoders.

**Opt-out for testing:** `Bse.Framework.Rpc` ships `IRpcCodec` as an abstraction.
`EncryptedBrotliCodec` is the production implementation; `IdentityCodec` (no compression, no
encryption) is available in `Bse.Framework.Testing` for unit and integration tests.
The transport layer does not know which codec is active.

## Options Considered

### Option A: Rely on transport-level TLS only
- **Pros:** Zero application-level crypto; simplest configuration.
- **Cons:** TLS terminates at ingress. Service-mesh sidecars, operators, memory dumps, log
  captures, and Redis replica streams all reach past transport encryption. Different deployment
  topologies leave different gaps. No payload integrity if TLS is downgraded or absent.

### Option B: Compress only (no encryption)
- **Pros:** Simpler pipeline; one fewer dependency.
- **Cons:** Payloads on Redis remain readable to any process with Redis credentials. No
  integrity protection beyond what the transport provides.

### Option C: Encrypt + compress at the codec layer [chosen]
- **Pros:** Confidentiality and integrity end-to-end, independent of transport. Brotli saves
  40–70 % on typical JSON payloads. AES-256-GCM is the canonical AEAD primitive — authentication
  and encryption in one pass. Compress-then-encrypt is the correct ordering. `IRpcCodec` + keyId
  framing makes key rotation and algorithm migration non-breaking.
- **Cons:** Two CPU steps per message (Brotli compress + AES-GCM encrypt). Key material must be
  provisioned and rotated. Debugging is harder — `MONITOR` on a Redis stream shows opaque bytes.

## Rationale

**Defense in depth.** TLS is necessary but not sufficient for production-grade RPC. Payload-level
AEAD closes the gaps left by ingress termination, sidecar proxies, replica streams, and log
captures — with one consistent semantic across all transports.

**Brotli + AES-256-GCM are the modern defaults.** Brotli outperforms gzip on JSON without
significantly more CPU. AES-256-GCM is hardware-accelerated on every server-class CPU and
the `System.Security.Cryptography.AesGcm` API is mature and zero-allocation when used carefully.

**Compress-then-encrypt is non-negotiable.** Encrypted bytes look random; compressing them is pure
CPU waste at near-zero ratio. This ADR records the ordering explicitly because the inverse is a
common implementation mistake.

**The abstraction landing now matters.** Shipping `IRpcCodec` and `IRpcKeyProvider` in v0.1.0 —
even with only two codec implementations — means future KMS providers, per-tenant keys, and
algorithm migrations become package additions, not breaking changes.

## Consequences

### Positive
- Confidentiality + integrity end-to-end, independent of transport.
- 40–70 % typical wire savings on JSON payloads.
- Tamper-evident framing: version byte + key ID bound into AAD.
- Test ergonomics intact via `IdentityCodec`.
- Key rotation supported from day one via `RotatingRpcKeyProvider`.
- Forward-compatible: version byte allows algorithm migration.

### Negative
- Two CPU steps per message (Brotli + AES-GCM). Measured overhead: < 2 µs per message at
  1 KB payload on AES-NI-equipped CPUs. Acceptable for any realistic throughput.
- Operator burden: key material must be provisioned and rotated. Mitigated by
  `EnvironmentRpcKeyProvider` for dev and pluggable production providers.
- Debugging over Redis is harder — payloads are opaque ciphertext. Mitigated by `IdentityCodec`
  in non-production environments and by mandatory OTel tracing (envelope metadata is observable
  in spans even when the payload is encrypted).

### Neutral
- The wire overhead from framing headers (version + keyIdLen + keyId + nonce + tag) is negligible
  relative to Brotli savings on payloads larger than ~100 bytes.
- Small messages (< ~100 bytes) may produce compressed output larger than cleartext. The current
  codec always compresses; a minimum-size threshold can be added via the version byte if benchmarks
  show a need.
- The framework cannot safely generate or rotate keys internally. Production deployments must
  supply a real key source; `EnvironmentRpcKeyProvider` is the development default only.

## References

- RFC-0002: RPC and Distributed Computing
- ADR-0002: JSON-RPC 2.0 Over Multiple Transports
- ADR-0012: AES-GCM Codec Framing and Key Rotation
- NIST SP 800-38D: AES-GCM specification
- RFC 7932: Brotli compression
- `System.Security.Cryptography.AesGcm`: <https://learn.microsoft.com/dotnet/api/system.security.cryptography.aesgcm>
- `System.IO.Compression.BrotliStream`: <https://learn.microsoft.com/dotnet/api/system.io.compression.brotlistream>
- "Cryptography Engineering" — Ferguson, Schneier, Kohno (compress-then-encrypt ordering)
