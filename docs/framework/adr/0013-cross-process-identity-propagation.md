# ADR-0013: Cross-Process Identity Propagation on the Envelope

- **Status:** Accepted
- **Date:** 2026-07-05
- **Deciders:** BSE Framework Team
- **Tags:** auth, identity, rpc, cross-process

## Context

When service A calls service B over an RPC transport, the receiving handler must know *who*
initiated the original request — for audit logging, ownership checks, and per-user data
filtering. The envelope is the only conduit available; there is no shared session store that
both processes can reach at handler-invocation time without additional latency.

The question is how much identity to carry on the envelope. Two failure modes exist:
- **Too much:** Shipping roles, claims, and company/branch context from the caller means the
  receiver trusts whatever the sender asserts. A compromised or buggy upstream service can
  claim elevated roles it doesn't hold.
- **Too little:** Shipping only an opaque `UserId` with no human-readable handle forces
  downstream services to paper over the gap by using `UserId` as a display code — a pattern
  that had appeared as `UserCode ?? UserId` fallbacks in early handler drafts.

A second subtlety is `TenantId`: multi-tenancy is a separate cross-cutting concern. It is
propagated by a parallel decorator (`TenantOutgoingEnvelopeDecorator`) and scope
(`TenantRpcEnvelopeScope`) and is intentionally not mixed into the user propagation path.

## Decision

Propagate **only minimal, stable identity** across process boundaries: `UserId` and `UserCode`
on `TransportMessage`. Richer identity (roles, claims, `CompCode`, `BraCode`, `FinYear`) is
**never trusted from the wire** and must be re-fetched by handlers that need it.

On the outbound side, `BseUserOutgoingEnvelopeDecorator` stamps both fields when the current
user is authenticated and the envelope does not already carry a user id:

```csharp
return envelope with { UserId = current.UserId, UserCode = current.UserCode };
```

On the inbound side, `BseUserRpcEnvelopeScope.Push` reconstructs a minimal `BseUser` from the
envelope and pushes it into `IBseUserAccessor` before the dispatcher resolves the handler:

```csharp
var minimalUser = new BseUser(
    UserId: envelope.UserId,
    UserCode: envelope.UserCode,
    CompCode: null, BraCode: null, FinYear: null,
    Roles: Array.Empty<string>(),
    Claims: new Dictionary<string, string>(0, StringComparer.Ordinal),
    Extensions: new Dictionary<string, string>(0, StringComparer.Ordinal),
    IsAuthenticated: true);
```

Handlers that need roles or company context must fetch them from the auth or user-profile
service using the propagated `UserId` as the lookup key.

`UserCode` was added alongside `UserId` specifically to carry the human-readable caller
identifier (e.g., an employee login code) without falling back to displaying a GUID. The
earlier draft had `accessor.UserCode ?? accessor.UserId` fallbacks in audit-log helpers —
a code smell indicating that `UserCode` was implicitly expected but not guaranteed on the
wire. Making it an explicit, nullable envelope field removes the ambiguity: if `UserCode` is
null the downstream service knows it was not supplied, not that it equals `UserId`.

## Options Considered

### Option A: Propagate the full BseUser (roles, claims, CompCode, BraCode, FinYear)
- **Pros:** Handlers receive everything they need with no extra fetch; zero added latency
- **Cons:** Receiver must trust assertions made by the sender; a compromised upstream can
  escalate privileges by inflating the roles array; payload grows with each new claim type;
  stale roles are invisible until the next RPC hop

### Option B: Propagate UserId only
- **Pros:** Minimal attack surface — receiver can only act on a user id it verifies itself
- **Cons:** Forces `UserCode ?? UserId` fallback patterns in display and audit code;
  downstream services that need a human-readable code must issue an extra lookup even when
  the caller already has it

### Option C: Propagate UserId + UserCode, re-fetch the rest (chosen)
- **Pros:** Covers the common audit/display case without trusting privileged claims; each
  field is semantically clear (`UserId` = identity key, `UserCode` = display handle);
  roles and company context are always fetched under the receiver's own authority
- **Cons:** Handlers needing roles must do an extra round-trip to the auth service; the
  framework cannot prevent a caller from stamping an arbitrary `UserId` (transport-level
  encryption from ADR-0012 limits but does not eliminate inter-service forgery risk)

## Rationale

Defense-in-depth: even if an intermediate service is compromised, it cannot assert elevated
roles to downstream services because those roles are re-fetched from the authoritative source
at the point of use. Adding `UserCode` as a first-class field eliminates the fallback smell
that emerges when display code and identity key are conflated, while keeping the wire overhead
small (one extra nullable string).

## Consequences

### Positive
- Downstream handlers cannot be tricked into acting on inflated roles claimed by a rogue caller
- `UserCode` on the envelope is semantically unambiguous — handlers know exactly what it
  represents and when it is absent
- `IBseUserAccessor.Current.IsAuthenticated` is correctly `true` on the receiving side when
  a `UserId` is present, enabling `[RequiresAuthentication]` enforcement (ADR-0014) across
  process boundaries

### Negative
- Handlers requiring roles or company context must call the auth/user-profile service;
  framework cannot cache or batch those lookups automatically
- There is no cryptographic proof that the `UserId` on the envelope was set by the legitimate
  originating service — transport encryption (ADR-0012) provides confidentiality and integrity
  of the frame but not caller authentication at the application layer

### Neutral
- `TenantId` propagation follows the same decorator/scope pattern but is owned by
  `Bse.Framework.MultiTenancy.Rpc` and is independent of the user propagation path
- `BseUserRpcEnvelopeScope` returns a no-op disposable when `envelope.UserId` is null, so
  anonymous RPC calls leave the accessor untouched

## References

- ADR-0014: Per-Handler Authorization via an Invocation-Filter Pipeline
- RFC-0002: RPC and Distributed Computing
- RFC-0004: Auth and Security
- `Bse.Framework.Auth.Rpc/BseUserOutgoingEnvelopeDecorator.cs`
- `Bse.Framework.Auth.Rpc/BseUserRpcEnvelopeScope.cs`
- `Bse.Framework.Rpc/Envelope/TransportMessage.cs`
