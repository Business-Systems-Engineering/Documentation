# ADR-0004: Authentication via a BSE.Common Adapter

- **Status:** Accepted (supersedes ADR-0004: Hybrid Authentication — Opaque Tokens for Users + JWT for Services)
- **Date:** 2026-07-05
- **Deciders:** BSE Framework Team
- **Tags:** auth, security, jwt, bse-common

## Context

The original ADR-0004 proposed embedding an OpenIddict-based OAuth 2.0/OIDC server directly
inside the framework to handle both user sessions (opaque tokens) and service-to-service JWTs.
That design was accurate for the threat model it addressed but assumed the framework would own
the auth server, the token generation pipeline, and all cryptographic primitives.

As the framework matured alongside BSE.Common, it became clear that `BSE.Common.Security`
already implements the vetted hybrid JWT bearer + opaque token design — complete with
`AddBseAuth(config)` (JWT bearer, authorization policies, `ITokenGenerator`,
`IRefreshTokenGenerator`) and `AddBseSecurity(config)` (encryption, hashing, MFA via
`IEncryptionService`, `IPasswordHasher`, `IDataHasher`, `ITotpService`). Duplicating or
superseding that library from within the framework would create two competing auth stacks,
diverging security primitives, and a painful upgrade story for every service that already
depends on BSE.Common.

The framework therefore adopts a thin-adapter pattern: `Bse.Framework.Auth.Jwt` delegates
entirely to BSE.Common's registration calls and adds only the ASP.NET Core middleware shim
(`BseAuthUserMiddleware`) that bridges BSE.Common's `ClaimsPrincipal` into the framework's
`IBseUser` / `IBseUserAccessor` abstraction.

## Decision

The framework exposes authentication through a **BSE.Common adapter** (`Bse.Framework.Auth.Jwt`).
The adapter contains zero crypto or JWT implementation of its own:

```csharp
// All registration delegates to BSE.Common — no in-framework JWT code.
public BseAuthJwtBuilder UseJwtBearer()
{
    Services.AddBseAuth(_configuration);   // BSE.Common
    return this;
}

public BseAuthJwtBuilder UseSecurity()
{
    Services.AddBseSecurity(_configuration); // BSE.Common
    return this;
}
```

`BseAuthUserMiddleware` (placed after `UseAuthentication` / `UseAuthorization`) maps the
authenticated `ClaimsPrincipal` into a `BseUser` record, scoping it to the request via
`IBseUserAccessor.Push`:

```csharp
// Claim mapping: uid → UserId, user_code → UserCode,
// comp_code/bra_code/fin_year → int?, roles → string[], ext_* → Extensions.
var user = BuildBseUser(ctx.User);
using var scope = accessor.Push(user);
await _next(ctx);
```

Services call a single fluent extension to wire the full pipeline:

```csharp
builder.AddBseAuthJwt(configuration);  // registers both UseJwtBearer + UseSecurity by default
app.UseBseAuthJwt();                   // adds UseAuthentication → UseAuthorization → BseAuthUserMiddleware
```

## Options Considered

### Option A: OpenIddict-based OAuth2/OIDC server in-framework
- **Pros:** Full OIDC compliance, self-contained, no external library dependency
- **Cons:** Massive scope — the framework must own token issuance, key rotation, JWKS endpoints,
  and consent flows; duplicates BSE.Common's existing, tested implementation; high ongoing CVE surface

### Option B: Bespoke custom auth (no BSE.Common, no OpenIddict)
- **Pros:** Maximum control over every detail
- **Cons:** Security primitives written from scratch invite implementation bugs; no shared upgrade
  path with services already on BSE.Common; violates the principle of using battle-tested libraries
  for cryptographic concerns

### Option C: Adapter over BSE.Common.Security (chosen)
- **Pros:** Reuses audited, BSE-standard primitives; a single `AddBseAuth` call gets JWT bearer,
  policies, and token generation; framework only adds the thin `BseUser` mapping shim; upgrades to
  BSE.Common automatically flow to all framework consumers
- **Cons:** Framework takes a compile-time dependency on BSE.Common; if BSE.Common's API changes,
  `BseAuthJwtBuilder` must track the change

## Rationale

BSE.Common.Security is the org-wide standard for auth primitives. The correct boundary is:
BSE.Common owns token issuance and verification; `Bse.Framework.Auth.Jwt` owns the seam that
converts those tokens into the framework's own `IBseUser` identity model. Keeping the adapter
thin (zero crypto, zero JWT parsing in-framework) means the framework never diverges from the
security posture of BSE.Common and the upgrade path for individual services is trivially a
package version bump.

## Consequences

### Positive
- Framework inherits BSE.Common's vetted JWT bearer pipeline, including `Approved`, `UserApproved`,
  and `AdminApproved` authorization policies out of the box
- `BseAuthUserMiddleware` gives every service a uniform, typed `IBseUser` abstraction regardless of
  which BSE.Common release is in use
- The fluent builder (`AddBseAuthJwt`) allows custom `BseAuthOptions` callbacks for services with
  non-default claim mappings without bypassing BSE.Common's core registration

### Negative
- A breaking change in `BSE.Common.Security.DependencyInjection` requires a matching update in
  `BseAuthJwtBuilder`
- Services that supply a custom `configure` callback on `AddBseAuthJwt` must explicitly call both
  `UseJwtBearer()` and `UseSecurity()` — omitting either leaves `IEncryptionService` or
  `ITokenGenerator` unregistered at runtime

### Neutral
- The `BseAuthModule` (abstractions layer: `IBseUserAccessor`, `IBseUser`, `BseUser`) remains
  independent of BSE.Common and can be registered alone for services that need the user accessor
  without JWT (e.g., pure RPC consumers using cross-process identity propagation only)
- RPC-layer identity propagation (`BseUserOutgoingEnvelopeDecorator`, `BseUserRpcEnvelopeScope`)
  lives in the separate `Bse.Framework.Auth.Rpc` package and requires no BSE.Common dependency
  (see ADR-0013)

## References

- ADR-0013: Cross-Process Identity Propagation on the Envelope
- ADR-0014: Per-Handler Authorization via an Invocation-Filter Pipeline
- RFC-0004: Auth and Security
- BSE.Common: `AuthServiceCollectionExtensions.AddBseAuth`, `ServiceCollectionExtensions.AddBseSecurity`
- `Bse.Framework.Auth.Jwt/DependencyInjection/BseAuthJwtBuilder.cs`
- `Bse.Framework.Auth.Jwt/Middleware/BseAuthUserMiddleware.cs`
