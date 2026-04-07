# ADR-0004: Hybrid Authentication — Opaque Tokens for Users + JWT for Services

- **Status:** Accepted
- **Date:** 2026-04-06
- **Tags:** auth, security, jwt, sessions

## Context

The existing BSE apps use a custom token system: `"HGFD-" + DES(GUID)` with the encryption key `"Business-Systems"` hardcoded in source. Passwords are stored in plain text in the `G_USERS` table. There is no MFA, no proper RBAC enforcement (the `G_ROLE_USERS` table exists but isn't wired to authorization), no rate limiting, no audit logging, and `[AllowAnonymous]` is on every endpoint with manual `CheckUser()` validation. This is a critical security debt.

We need an authentication system that provides instant revocation for user sessions (when users log out, change passwords, or get suspended) AND efficient stateless verification for service-to-service RPC calls (no Redis lookup per internal call).

## Decision

Use a **hybrid authentication architecture**:
- **User sessions:** Opaque tokens (random 256-bit, stored in Redis) for instant revocation
- **Service-to-service:** Short-lived JWTs (5 min) signed with asymmetric keys, no Redis lookup needed
- Both flows issued by **OpenIddict** (OAuth 2.0/OIDC compliant)

## Options Considered

### Option A: JWT + Refresh Tokens Everywhere
- **Pros:** Standard, stateless, works for distributed services, no Redis lookup
- **Cons:** Cannot instantly revoke (relies on token expiry), large tokens, claim staleness

### Option B: Opaque Tokens + Redis Sessions Everywhere
- **Pros:** Instant revocation, smaller tokens, no algorithm-confusion attacks
- **Cons:** Redis lookup per request (latency for high-frequency S2S calls)

### Option C: External IdP Integration (Ory/Auth0/Azure AD)
- **Pros:** Delegates complexity to specialist, battle-tested
- **Cons:** External dependency, less control, integration complexity

### Option D: Hybrid (JWT for S2S, Opaque for Users)
- **Pros:** Right tool for each job — instant revocation where it matters (user sessions), no lookup overhead where it doesn't (internal RPC), works with OpenIddict (single issuer for both)
- **Cons:** Two token types, slightly more complex to reason about

## Rationale

User sessions need instant revocation (account locked, password changed, suspicious activity). Service-to-service calls happen at high frequency and don't need revocation if lifetimes are short (5 minutes). Hybrid gives us the best of both. OpenIddict is the only sensible authority choice — Apache 2.0 licensed, .NET-native, supports both reference (opaque) and JWT token formats, handles OAuth 2.0/OIDC compliance for free.

## Consequences

### Positive
- Instant revocation for user sessions via Redis key deletion
- Zero-latency service-to-service auth (signature verification only)
- OAuth 2.0/OIDC compliant via OpenIddict — interoperable with `Microsoft.AspNetCore.Authentication.JwtBearer`
- Standard `/.well-known/openid-configuration`, `/.well-known/jwks.json`, `/token`, `/authorize`, `/revoke`, `/introspect` endpoints
- Built on `Microsoft.AspNetCore.Identity.Core` for proven primitives (lockout, security stamp, MFA, password history)
- Redis already in stack (no new infrastructure)

### Negative
- Two token types to handle in middleware
- Redis must be highly available for user sessions (Sentinel/Cluster required)
- Service signing keys must be rotated (90-day cadence)
- JWT must include `kid` for key rotation, `aud` for replay prevention

### Neutral
- Per-tenant authentication (different IdPs per tenant) supported via Finbuckle-style per-tenant options
- API keys added as a third auth scheme for partner integrations

## References

- ADR-0001: Modular Package Architecture
- RFC-0004: Auth and Security
- NIST SP 800-63B-4 (July 2025)
- OWASP ASVS 5.0
- OpenIddict: https://documentation.openiddict.com/
- Microsoft.AspNetCore.Identity.Core
