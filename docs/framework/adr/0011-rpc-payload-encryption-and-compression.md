# ADR-0011: Encrypt and Compress RPC Payloads in Transit

- **Status:** Accepted
- **Date:** 2026-05-15
- **Tags:** rpc, security, encryption, compression, transport

## Context

RFC-0002 specifies JSON-RPC 2.0 over multiple transports (Redis Streams, HTTP, In-Memory). Two cross-cutting concerns for production deployment were left under-specified:

1. **Confidentiality of payloads in transit.** Redis is typically deployed inside a trusted network, but "trusted network" is a security smell — Redis credentials get leaked, replicas get exposed by misconfiguration, log captures from network appliances harvest unencrypted payloads. HTTP transport benefits from TLS at the edge, but ingress termination + service mesh hops re-expose cleartext to operators and sidecars. Defense-in-depth requires payload-level encryption independent of transport-level TLS.
2. **Payload size on the wire.** JSON-RPC payloads are verbose by design (field names repeated, no schema). For high-throughput streams (notifications, batch ingest) the bandwidth and Redis-memory cost is material.

The framework needs a uniform, transport-agnostic answer. Bolting per-transport encryption (TLS in HTTP, ad-hoc encryption-at-rest in Redis) leaves gaps and produces inconsistent semantics across deployments.

## Decision

All RPC messages flowing through `Bse.Framework.Rpc` are **compressed then encrypted** at the envelope layer before reaching any transport. The transport sees only opaque ciphertext bytes.

**Order: compress → encrypt** (not the reverse). Encryption produces high-entropy bytes that don't compress; compression must run first to do useful work.

**Compression:** [Brotli](https://datatracker.ietf.org/doc/html/rfc7932) at level 4 (balanced compression ratio vs CPU). Brotli outperforms gzip/deflate on JSON by 15–25 % at lower CPU cost than higher compression levels. Implemented via `System.IO.Compression.BrotliStream`.

**Encryption:** [AES-256-GCM](https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38d.pdf) — authenticated encryption, NIST-blessed, single-pass, the .NET BCL primitive (`System.Security.Cryptography.AesGcm`).

- **Nonce:** 96-bit random, prepended to ciphertext (per NIST recommendation for GCM).
- **Tag:** 128-bit, prepended after the nonce.
- **AAD (Additional Authenticated Data):** the JSON-RPC envelope's `id`, `method`, and timestamp fields. Tampering with the routing metadata invalidates the tag.

**Key management:** the framework defines `IRpcKeyProvider` with two implementations shipped:
- `EnvironmentRpcKeyProvider` — reads a base64-encoded key from `BSE_RPC_KEY_<context>` for development and simple deployments.
- `RotatingRpcKeyProvider` — wraps any source (env, AWS KMS, HashiCorp Vault, Azure Key Vault) with a "current + previous" key window so rotation doesn't reject in-flight messages.

KMS / Vault providers ship as separate optional packages: `Bse.Framework.Rpc.Security.Aws`, `Bse.Framework.Rpc.Security.AzureKeyVault`, `Bse.Framework.Rpc.Security.HashicorpVault`. These are out of scope for v0.1.0 of the RPC packages but the abstraction lands now so they slot in without breaking changes.

**Wire format** (after compression + encryption):
```
[1 byte version=0x01][12 byte nonce][N byte ciphertext+tag]
```

The version byte enables future algorithm migration without breaking deserializers.

**Opt-out for in-process testing:** `Bse.Framework.Rpc` ships an `IRpcCodec` abstraction; production uses `EncryptedBrotliCodec`, tests can use `IdentityCodec` (no compression, no encryption) for clarity. The transport layer doesn't know which codec is in use.

## Options Considered

### Option A: Rely on Transport-Level TLS Only
- **Pros:** Zero application-level crypto, simplest config.
- **Cons:** TLS terminates at ingress; service-mesh sidecars and operators see cleartext. Doesn't cover Redis memory dumps, log captures, replica leaks. Different deployment topologies leave different gaps. No payload-level integrity if TLS is downgraded.

### Option B: Encrypt Without Compressing
- **Pros:** Simpler pipeline, one fewer dependency.
- **Cons:** Wastes the bandwidth/storage savings — JSON-RPC payloads are highly compressible (40–70 % typical). For high-volume streams this is a real cost.

### Option C: Compress After Encryption
- **Pros:** None — encrypted bytes are indistinguishable from random; compression rate ≈ 0 %.
- **Cons:** Adds CPU cost for zero benefit. Standard cryptography textbook anti-pattern.

### Option D: ChaCha20-Poly1305 instead of AES-GCM
- **Pros:** Faster on CPUs without AES-NI; constant-time on all architectures.
- **Cons:** AES-NI is universal on production server CPUs. AES-GCM has wider library + tooling support. .NET BCL's `AesGcm` is more mature than `ChaCha20Poly1305`. Most BSE deployment targets are AES-NI-equipped.

### Option E: Per-message Public-Key Encryption (RSA-OAEP / ECIES)
- **Pros:** No shared-secret distribution problem.
- **Cons:** Two orders of magnitude slower than symmetric. RPC is high-throughput; public-key crypto per message is untenable. Better suited to one-time key exchange.

### Option F: Compress + Encrypt (chosen)
- **Pros:** Compression saves real bytes. AES-256-GCM is the canonical AEAD primitive — auth + encryption in one pass with a 128-bit tag. Brotli is the modern compression default. The `compress → encrypt` order is the correct one.
- **Cons:** Adds two CPU steps per message. Key management surface grows.

## Rationale

**Defense in depth.** TLS is necessary but not sufficient for production-grade RPC. Operators, sidecars, replicas, network appliances, log captures, and memory dumps all reach past transport encryption. Payload-level AEAD closes those gaps with one consistent semantic.

**Brotli + AES-GCM are the modern defaults.** Brotli outperforms gzip without significantly more CPU. AES-256-GCM is the NIST-blessed AEAD primitive, hardware-accelerated on every server-class CPU, and the `System.Security.Cryptography.AesGcm` API is mature and zero-allocation when used carefully.

**Compress-then-encrypt is non-negotiable.** Encrypted bytes look random. Compressing them is pure CPU waste. This is textbook ordering; the ADR records it explicitly because the inverse is a common mistake.

**The abstraction landing now matters.** Shipping `IRpcCodec` and `IRpcKeyProvider` in v0.1.0 of `Bse.Framework.Rpc` — even with only one production codec implementation — means future KMS providers, BLS/post-quantum migrations, and per-tenant key separation all become package additions, not breaking changes.

## Consequences

### Positive
- Confidentiality + integrity end-to-end, independent of transport.
- 40–70 % typical wire savings on JSON payloads.
- Tamper-evident routing metadata (envelope id/method bound into AAD).
- Test ergonomics intact via `IdentityCodec`.
- Key rotation supported from day one.
- Forward-compatible: version byte allows algorithm migration.

### Negative
- Two CPU steps per message (Brotli compress + AES-GCM encrypt). Measured overhead: < 2 µs per message at 1 KB payload size on Apple Silicon and current Xeon/EPYC. Acceptable for any realistic throughput.
- Operator burden: key material must be provisioned and rotated. Mitigated by `EnvironmentRpcKeyProvider` for dev and pluggable production providers.
- Debugging is harder — you can't `MONITOR` a Redis stream and read the payload. Mitigated by the optional `IdentityCodec` in non-prod environments and by mandatory tracing via the Telemetry package (the *envelope* is still observable via OTel spans even when the *payload* is opaque).

### Neutral
- The encrypted ciphertext is **larger** than the cleartext by `13 bytes` (1-byte version + 12-byte nonce + 16-byte tag, minus the 16 bytes already counted by the GCM tag). Negligible vs Brotli savings.
- The framework will ship a default `EnvironmentRpcKeyProvider`. Production deployments are expected to provide a real KMS-backed provider — the framework cannot generate or rotate keys safely from inside the application.
- Compression of small messages (< 100 bytes) can produce ciphertext *larger* than cleartext. The codec includes a threshold below which compression is skipped (the version byte distinguishes "raw + encrypted" from "compressed + encrypted").

## References

- RFC-0002: RPC and Distributed Computing (consumes this decision)
- ADR-0002: JSON-RPC 2.0 Over Multiple Transports
- NIST SP 800-38D: AES-GCM specification
- RFC 7932: Brotli compression
- "Cryptography Engineering" — Ferguson, Schneier, Kohno (compress-then-encrypt ordering)
- .NET `System.Security.Cryptography.AesGcm` API: <https://learn.microsoft.com/dotnet/api/system.security.cryptography.aesgcm>
- `System.IO.Compression.BrotliStream` API: <https://learn.microsoft.com/dotnet/api/system.io.compression.brotlistream>
