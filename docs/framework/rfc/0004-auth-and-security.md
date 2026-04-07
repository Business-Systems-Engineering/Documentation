# RFC-0004: Authentication, Authorization, and Security

- **Status:** Approved
- **Date:** 2026-04-06
- **Related ADRs:** ADR-0004
- **Related RFCs:** RFC-0001, RFC-0006

## Abstract

The framework provides a hybrid authentication system: opaque tokens (with Redis session store) for user sessions, and short-lived asymmetric-signed JWTs for service-to-service RPC. Both flows are issued by **OpenIddict** for OAuth 2.0/OIDC compliance. Built on **`Microsoft.AspNetCore.Identity.Core`** for proven primitives (account lockout, security stamp, MFA, password history). Includes WebAuthn/passkey support, Argon2id password hashing with HIBP breach checking, RBAC permissions integrated with ASP.NET Core's `IAuthorizationHandler`, audit logging for all auth events, multi-tenant CORS, API key support, and a comprehensive security control set aligned with NIST SP 800-63B-4 and OWASP ASVS 5.0.

## Motivation

The existing BSE apps have critical security debt:
- **DES encryption** with hardcoded key `"Business-Systems"` for token generation
- **Plain text passwords** in `G_USERS` table
- **No MFA** anywhere
- **No proper RBAC** (`G_ROLE_USERS` table exists but unused)
- **`[AllowAnonymous]` everywhere** with manual `CheckUser()` validation in each controller
- **No rate limiting** (vulnerable to brute force)
- **No audit logging** (regulatory non-compliance)
- **No password breach detection**
- **No account lockout**
- **CORS wildcard** (`*`)
- **No API key support** for partner integrations

This is a SOC 2 audit failure waiting to happen.

## Goals

- Replace DES tokens with industry-standard authentication (Argon2id, OpenIddict, JWT with key rotation)
- Provide MFA (TOTP) and passkeys (WebAuthn)
- RBAC permission system integrated with ASP.NET Core authorization
- Audit logging for all auth events (NIST/OWASP requirement)
- Hybrid token model (opaque for users, JWT for services)
- API key authentication for partner integrations
- Multi-tenant CORS isolation
- Rate limiting per user/tenant/endpoint (Redis-backed for distributed)
- Migration path from existing plain-text passwords
- Compliance with NIST SP 800-63B-4 and OWASP ASVS 5.0

## Non-Goals

- Replacing OpenIddict with custom OAuth implementation
- Supporting username/password as the ONLY auth method (MFA is mandatory for AAL2)
- Implementing custom cryptographic primitives

## Design

### Auth Abstractions (Bse.Framework.Auth)

```csharp
public interface ICurrentUser
{
    bool IsAuthenticated { get; }
    string UserId { get; }
    string? UserName { get; }
    string? Email { get; }
    string TenantId { get; }
    string? BranchId { get; }
    IReadOnlyList<string> Roles { get; }
    IReadOnlyList<Claim> Claims { get; }
    T? GetClaim<T>(string claimType);
}

public interface IPermissionChecker
{
    Task<bool> HasPermissionAsync(string permission);
    Task<bool> HasAnyPermissionAsync(params string[] permissions);
    Task<bool> HasAllPermissionsAsync(params string[] permissions);
}
```

### Permission Definition (Code-First)

```csharp
public interface IPermissionDefinitionProvider
{
    void Define(PermissionDefinitionContext context);
}

public class StudentPermissions : IPermissionDefinitionProvider
{
    public const string View = "Students.View";
    public const string Create = "Students.Create";
    public const string Edit = "Students.Edit";
    public const string Delete = "Students.Delete";
    public const string Enroll = "Students.Enroll";

    public void Define(PermissionDefinitionContext context)
    {
        var group = context.AddGroup("Students", "Student Management");
        group.AddPermission(View, "View students");
        group.AddPermission(Create, "Create students").RequirePermission(View);
        group.AddPermission(Edit, "Edit students").RequirePermission(View);
        group.AddPermission(Delete, "Delete students").RequirePermission(Edit);
        group.AddPermission(Enroll, "Enroll students").RequirePermission(Edit);
    }
}
```

### Authorization Built on ASP.NET Core (Not Parallel)

Every `[RequirePermission("Students.View")]` becomes a registered ASP.NET Core policy. This composes with:
- `[Authorize(Policy = "Students.View")]` on controllers
- `.RequireAuthorization("Students.View")` on minimal APIs
- SignalR hub authorization
- Blazor `AuthorizeView` components

```csharp
[RpcMethod]
[RequirePermission(StudentPermissions.Enroll)]
public async Task<EnrollmentResult> Enroll(EnrollRequest request) { ... }
```

Wildcard support:
- `"Students.*"` matches `Students.View`, `Students.Create`, etc.
- `"*"` is super-admin (matches everything)

#### Resource-Based Authorization

```csharp
public class StudentEditHandler : AuthorizationHandler<StudentEditRequirement, Student>
{
    protected override Task HandleRequirementAsync(
        AuthorizationHandlerContext context,
        StudentEditRequirement requirement,
        Student student)
    {
        if (context.User.HasPermission("Students.Edit") &&
            student.BranchId == context.User.GetClaim<string>("BranchId"))
        {
            context.Succeed(requirement);
        }
        return Task.CompletedTask;
    }
}
```

### Token Architecture

#### User Sessions (Opaque Tokens)

- **Format:** `bse_session_<32 bytes base64url>` from `RandomNumberGenerator.GetBytes(32)` (CSPRNG)
- **Storage:** Redis with key = `SHA256(token)` (NOT raw token — protects against Redis leak)
- **Session data:** `{ userId, tenantId, branchId, roles, permissions, createdAt, expiresAt, lastActivityAt, ipAddress, userAgentHash }`
- **TTL:** Configurable (default 8h sliding + 12h absolute)
- **Revocation:** Delete Redis key → instant logout
- **Session fixation prevention:** Regenerate token ID on EVERY privilege change (login, MFA step-up, role change, impersonation, password change)

#### Service-to-Service (JWT)

- **Algorithm:** EdDSA (Ed25519) preferred → ES256 → PS256 → RS256 (`alg` pinned on verifier, `none` rejected)
- **Lifetime:** 5 minutes
- **Signing:** Asymmetric, JWKS endpoint per service
- **Key rotation:** Every 90 days, old + new keys in JWKS during overlap
- **Claims:** `sub`, `tenant`, `roles` (small list), `iss`, `aud`, `exp`, `nbf`, `iat`, `jti`, `trace_id`
- **NOT in JWT:** Full permission sets (resolved at destination from cache)
- **Validation:** ALL standard claims on every hop (`iss`, `aud`, `exp`, `nbf`, `jti`)
- **Clock skew:** 60 seconds max
- **Revocation:** `jti` denylist in Redis for sensitive operations

### OpenIddict Integration

OpenIddict serves as the **single OAuth 2.0/OIDC authority** for both flows. It provides:
- `/.well-known/openid-configuration` discovery
- `/.well-known/jwks.json` for public keys
- `/connect/token`, `/connect/authorize`, `/connect/revoke`, `/connect/introspect`
- Standard grants: `authorization_code+PKCE`, `client_credentials`, `refresh_token`
- Reference tokens (opaque) AND JWT tokens issued from same authority
- Standard `Microsoft.AspNetCore.Authentication.JwtBearer` middleware works in downstream services

### Built on Microsoft.AspNetCore.Identity.Core

The framework inherits Identity primitives:
- `UserManager<TUser>` + `SignInManager<TUser>`
- Account lockout state machine
- Security stamp (invalidates tokens on password/role/permission changes)
- 2FA/MFA primitives (TOTP, recovery codes, "remember device")
- Passkey/WebAuthn support (.NET 9/10 native)
- Token providers (email confirmation, password reset, change email)
- Password history infrastructure
- Concurrency stamps on user records

The framework adds:
- Custom `IUserStore` backed by existing `G_USERS` table (migration)
- Redis session store via OpenIddict reference tokens
- Multi-tenant scoping
- RPC auth context propagation

### MFA & Passkeys

#### TOTP (RFC 6238)
- QR code enrollment
- 6-digit codes, 30-second window
- 10 single-use recovery codes generated at enrollment
- "Remember this device" cookie (encrypted, 30-day default)

#### WebAuthn / Passkeys (.NET 9/10 native)
- Phishing-resistant
- Hardware-backed (Touch ID, Face ID, YubiKey)
- Multiple credentials per user

#### Step-Up Authentication
- Re-auth required before sensitive operations:
  - Changing email
  - Granting admin roles
  - Deleting data
  - Configuring billing
  - Exporting data
- `acr_claim` in JWT/session indicates current auth level
- Configurable per `[RequirePermission]` attribute

### Password Security (NIST 800-63B-4 Compliant)

- **Algorithm:** Argon2id (m=19 MiB, t=2, p=1 — OWASP minimum)
- **Application-wide pepper** from Key Vault, applied via HMAC before Argon2id
- **Min length:** 8 chars (user-chosen) / 6 chars (machine-generated)
- **Max length:** ≥64 chars
- **Allowed:** All printable ASCII + Unicode
- **NO composition rules** (no "must have uppercase/digit/symbol")
- **NO periodic expiration** (only on evidence of compromise)
- **Allow paste** (password manager support)
- **Breach check:** HIBP Pwned Passwords API via k-anonymity (SHA-1 prefix). MANDATORY by NIST.
- **Lockout:** After 5-10 failures, progressive backoff, 15 min default (separate from rate limiting)
- **Password history:** Last 10 hashes per user

#### Password Migration from Plain Text

1. Add `PasswordHash` column (nullable initially)
2. On first successful login with old plain-text password:
   - Hash with Argon2id
   - Store hash in `PasswordHash`
   - Clear plain-text `Password` column
3. Legacy plain text encrypted at rest until cleared
4. Read access audited
5. Force expiry for users dormant > 6 months
6. After migration period, reject logins without `PasswordHash`

### Session Management

```csharp
public interface ISessionManager
{
    Task<SessionInfo> CreateSessionAsync(string userId, string tenantId,
                                         SessionOptions options, CancellationToken ct);
    Task<SessionInfo?> ValidateSessionAsync(string token, CancellationToken ct);
    Task RevokeSessionAsync(string token, CancellationToken ct);
    Task RevokeAllSessionsAsync(string userId, CancellationToken ct);  // "logout everywhere"
    Task<IReadOnlyList<SessionInfo>> GetActiveSessionsAsync(string userId, CancellationToken ct);
}
```

- Sliding expiration + absolute expiration
- Concurrent session limit per device-class
- Hijack detection via fingerprint hash (UA + Accept-Language + stable cookie), NOT raw IP
- Mismatch → soft challenge (re-MFA), not hard revoke
- Resilience: Redis Sentinel/Cluster, fail-closed on Redis unavailable for write paths

### API Key Authentication

```
Format:    bse_live_<32 bytes base64url>
           Prefix readable for debugging
           Registered with GitHub secret scanning partner program

Storage:   SHA-256 hash only (NOT Argon2id — too slow per request)
           Constant-time equality comparison
           Show full key only at creation, never again

Features:
  - Per-key scopes/permissions
  - Per-key expiry
  - Last-used timestamp
  - IP allowlist (optional)
  - Tenant binding
  - Per-key rate limits
  - All uses audited
  - Revocation API
  - Rotation with overlap window
```

### Audit Logging (OWASP Top 10:2025 A09)

First-class events with stable schema:

```
auth.login.success / auth.login.failure (with reason code)
auth.logout / auth.logout_everywhere
auth.session.created / .revoked / .expired
auth.mfa.enrolled / .success / .failure
auth.password.changed / .reset_requested / .reset_completed
auth.permission.denied (required permission, user, resource)
auth.role.assigned / .revoked
auth.permission.granted / .revoked
auth.impersonation.started / .ended
auth.api_key.created / .used / .revoked
auth.token.issued / .revoked
auth.account.locked / .unlocked
```

#### Storage

- Append-only, separate from application DB
- Partitioned audit table with no UPDATE/DELETE grants
- OR external SIEM/OpenSearch
- Each event tagged with `TraceId`, `CorrelationId`, `RequestId`

#### Never Logged

- Passwords, full tokens, OTP codes, secrets
- Log token IDs (`jti`, `SHA256(session_id)`)

#### Alerting

Required by ASVS 5.0 V7. Alert on:
- Brute force / credential stuffing
- Privilege escalation
- New geo location / impossible travel
- Mass permission changes

### Auth Context Propagation in RPC

```
When Service A calls Service B via RPC:

1. AuthContextMiddleware (Service A outbound):
   - Mints short-lived JWT from current ICurrentUser claims
   - Signs with service signing key
   - Attaches to TransportMessage.Auth

2. AuthContextMiddleware (Service B inbound):
   - Extracts JWT from TransportMessage.Auth
   - Validates signature (no Redis lookup)
   - Populates ICurrentUser and ITenantContext
   - ClaimsPrincipal available — standard .NET [Authorize] works

3. Zero-trust:
   - Each service validates JWT independently
   - Service signing keys rotated via configuration
   - Tenant context flows automatically
```

### Service-to-Service Mutual Auth

Threat: A malicious internal service could mint tokens claiming to represent any user.

Mitigations:
- mTLS between services (transport-level mutual auth)
- OR all S2S JWTs signed by central authority (OpenIddict), not self-signed
- SPIFFE/SPIRE for service identity (optional, advanced)
- Service identity verified before accepting impersonation claims
- Audit log includes both real service identity AND claimed user identity

### Multi-Tenant CORS

```csharp
public class TenantCorsPolicyProvider : ICorsPolicyProvider
{
    public async Task<CorsPolicy?> GetPolicyAsync(HttpContext context, string? policyName)
    {
        var tenant = await _tenantResolver.ResolveAsync(context);
        var origin = context.Request.Headers["Origin"].ToString();

        // Validate origin matches a registered tenant origin (prevents reflective bug)
        if (!tenant.AllowedOrigins.Contains(origin))
            return null;

        return new CorsPolicyBuilder()
            .WithOrigins(origin)
            .AllowCredentials()
            .SetPreflightMaxAge(TimeSpan.FromSeconds(7200))  // Chrome max
            .Build();
    }
}
```

- Response always sets `Vary: Origin` (prevents cache poisoning)
- Never `AllowAnyOrigin()` + `AllowCredentials()` together
- Per-tenant allowed origins list

### Rate Limiting

```csharp
services.AddBseAuth(auth => {
    auth.RateLimiting(limits => {
        limits.PerUser(requests: 100, window: TimeSpan.FromMinutes(1));
        limits.PerTenant(requests: 1000, window: TimeSpan.FromMinutes(1));
        limits.LoginEndpoint(attempts: 5, window: TimeSpan.FromMinutes(15));
    });
});
```

- .NET 8's `System.Threading.RateLimiting`
- Sliding window (Lua-atomic in Redis)
- Redis-backed for distributed enforcement
- Response headers: `Retry-After`, `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`
- Bypass list: health checks, internal probes, observability scrapes

### XSS Defense

Input sanitization is NOT the right control (fragile, mangles legitimate data).

Correct controls:
1. Output encoding at rendering boundary (Razor + React both do this automatically)
2. Strong CSP header (`default-src 'self'`, `script-src` with nonces)
3. Where untrusted HTML must render: explicit DOMPurify-equivalent at the sink
4. Never use string interpolation into HTML

### SQL Injection Defense

Roslyn analyzer enforces "impossible by construction":
- Detects string concatenation in `[Query("...")]` attributes → compile error
- Detects raw SQL outside the data layer → compile warning
- Detects `FormattableString` interpolation in EF `SqlQueryRaw` → compile error
- Allowlist: explicit `[TrustedRawSql]` attribute for migration scripts only

### Encryption at Rest

`Microsoft.AspNetCore.DataProtection`:
- Used for SHORT-LIVED purpose-bound payloads only (cookies, anti-forgery tokens, password reset tokens)
- NOT for database encryption at rest

Database encryption at rest:
- SQL Server: Always Encrypted (column-level) or TDE (database-level)
- PostgreSQL: pgcrypto for column encryption, LUKS/dm-crypt for disk
- Key management: Azure Key Vault, AWS KMS, HashiCorp Vault
- Framework provides `IFieldEncryptor` abstraction

### Security Headers

Applied by middleware:
- `Strict-Transport-Security` (HSTS)
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `Content-Security-Policy`
- `Referrer-Policy: strict-origin-when-cross-origin`

### Tenant Impersonation (Distinct from Cross-Tenant Ops)

```csharp
public interface IImpersonationContext
{
    Task<ImpersonationSession> StartAsync(
        string targetTenantId,
        string? targetUserId,
        string reason,
        TimeSpan duration,
        CancellationToken ct);
    Task EndAsync(string sessionId, CancellationToken ct);
}
```

Process:
1. Support engineer requests with reason
2. Approval mechanism: customer admin clicks approve / auto-approved with notification / senior engineer break-glass
3. Time-limited token (1h default, 8h max), JWT contains BOTH support engineer AND impersonated user
4. UI shows persistent banner: "You are impersonating X"
5. Read-only by default; write requires additional approval
6. Two audit records per action (real engineer + impersonated user)
7. Cannot impersonate suspended/deleted tenants
8. Cannot change password/MFA/permissions via impersonation

### Break-Glass Recovery

Emergency super-admin access path:
- Bootstrap admin credential stored in Key Vault (not database)
- Requires physical access to deployment infrastructure
- Bypasses Redis (works when session store down)
- Every use generates pager alert + audit
- Time-limited (1h max)
- Forces password rotation after use

### CI Security Gates

Required in pipeline:
- `dotnet list package --vulnerable --include-transitive` (fail on High/Critical)
- Semgrep with .NET ruleset OR CodeQL OR SonarCloud
- Gitleaks for secret scanning
- GitHub secret scanning partner registration for `bse_live_` prefix
- Penetration testing annually + after major auth changes
- Threat model document (STRIDE) for auth boundary
- Fuzz testing JWT validator + JSON-RPC dispatcher
- ASVS L2 coverage matrix maintained

Cryptographic agility:
- Algorithm names in configuration, not code
- Argon2id parameters configurable
- JWT alg configurable
- Rotate without redeploying

## Migration Path

| Current Pattern | Framework Replacement |
|---|---|
| `SecuritySystem.Encrypt(GUID, "Business-Systems")` | OpenIddict reference token + Argon2id hash |
| `CheckUser(Token, UserCode)` in every controller | `[Authorize(Policy = "...")]` + `IAuthorizationHandler` |
| `[AllowAnonymous]` everywhere | Secure by default, anonymous opt-in |
| `G_USERS.Tokenid` | Redis session store via OpenIddict |
| `G_USERS.Password` plain text | Argon2id + HIBP breach check |
| DES with hardcoded key | Database TDE/Always Encrypted + Key Vault |
| No MFA | TOTP + WebAuthn passkeys via Identity.Core |
| No audit | Full auth event taxonomy with SIEM integration |
| 8h token, no refresh | OAuth2 refresh tokens with rotation |
| Manual `CompCode` extraction | `ICurrentUser.TenantId` from validated claims |
| No rate limiting | Redis-backed sliding window |
| Open CORS `*` | Tenant-scoped CORS policy provider |
| No API keys | First-class API key auth scheme |

## References

- ADR-0004
- NIST SP 800-63B-4: https://csrc.nist.gov/pubs/sp/800/63/b/4/final
- OWASP ASVS 5.0
- OWASP Top 10:2025
- OpenIddict: https://documentation.openiddict.com/
- Microsoft.AspNetCore.Identity.Core
- Have I Been Pwned Pwned Passwords API
- Argon2id (RFC 9106)
