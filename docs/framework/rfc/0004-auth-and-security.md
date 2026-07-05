# RFC-0004: Authentication, Identity Propagation, and Authorization

- **Status:** Implemented
- **Date:** 2026-07-05
- **Authors:** BSE Framework Team
- **Related ADRs:** ADR-0004, ADR-0013, ADR-0014
- **Related RFCs:** RFC-0001, RFC-0002, RFC-0006

## Abstract

The BSE Framework auth stack is implemented across three focused packages — `Bse.Framework.Auth`
(abstractions), `Bse.Framework.Auth.Jwt` (HTTP adapter over BSE.Common), and
`Bse.Framework.Auth.Rpc` (cross-process propagation) — plus a built-in invocation filter in
`Bse.Framework.Rpc`. Together they deliver a complete identity pipeline: JWT claims are mapped
to a strongly-typed `IBseUser` and stored in an `AsyncLocal` slot; outgoing RPC envelopes are
automatically stamped with the caller's identity; inbound envelopes reconstruct a minimal user
context before the handler is resolved; and `[RequiresAuthentication]` on any handler class
causes the dispatcher to gate the call with a typed `-32006` error before a single line of
application code executes.

## Motivation

Before this work the framework had no shared identity model. Individual services extracted JWT
claims ad-hoc, passed `UserCode` strings through hand-rolled method parameters, and had no
mechanism to propagate the caller's identity across an RPC hop. The result was:

- Duplicate claim-parsing logic in every service.
- `CompCode` treated as a tenant discriminator in some services and a user attribute in others.
- Cross-process calls that silently dropped the caller's identity, making audit-trail
  reconstruction impossible.
- No declarative way to mark an RPC handler as requiring an authenticated caller; services
  implemented their own null-checks inconsistently.

The prior art is well-established. ASP.NET Core's `IHttpContextAccessor` and its
`AsyncLocal`-backed implementation show the accessor pattern. Microsoft.AspNetCore.Identity
separates the identity model (`ClaimsPrincipal`) from the authentication middleware (token
validators). NIST SP 800-63B defines authentication assurance levels that the JWT adapter
honours via BSE.Common's token-verification layer.

## Goals

- A single, immutable `IBseUser` value object that all framework packages share.
- An `AsyncLocal`-backed accessor so any code in the call tree can read the current user
  without explicit parameter threading.
- An HTTP adapter that maps BSE.Common JWT claims to `IBseUser` without reimplementing
  any cryptography.
- Automatic identity stamping on outgoing RPC envelopes and automatic reconstruction on
  inbound envelopes.
- A declarative `[RequiresAuthentication]` attribute that the source generator and dispatcher
  enforce without coupling the `Bse.Framework.Rpc` package to `Bse.Framework.Auth`.
- Structured-log enrichment with `UserId` on every RPC dispatch.

## Non-Goals

- Reimplementing JWT cryptography or token issuance — that is BSE.Common's responsibility.
- Policy-based or role-based authorization at the RPC handler level (planned; see Open Questions).
- Cross-service role/claims propagation — only `UserId` and `UserCode` travel in the envelope;
  downstream services re-fetch richer identity from the auth backend if they need it.
- WebAuthn, TOTP, session management, API keys, or audit logging — those concerns belong in
  the Identity microservice and are outside the framework transport layer.

## Design

### Overview

The stack has four layers, each narrowly responsible:

```
┌─────────────────────────────────────────────────────┐
│ Bse.Framework.Auth                                  │
│   IBseUser / BseUser / BseUser.Empty                │
│   IBseUserAccessor / AsyncLocalBseUserAccessor      │
└──────────────────┬──────────────────────────────────┘
                   │ depended on by
   ┌───────────────┼───────────────────┐
   ▼                                   ▼
┌─────────────────────┐   ┌──────────────────────────┐
│ Bse.Framework.      │   │ Bse.Framework.Auth.Rpc   │
│ Auth.Jwt            │   │   BseUserOutgoing-        │
│   BseAuthUser-      │   │     EnvelopeDecorator     │
│     Middleware      │   │   BseUserRpc-             │
│   (HTTP adapter)    │   │     EnvelopeScope         │
└─────────────────────┘   └──────────────────────────┘
                                        │ hooks into
                           ┌────────────▼─────────────┐
                           │ Bse.Framework.Rpc        │
                           │   AuthenticationInvocation│
                           │     Filter (-32006 gate)  │
                           └──────────────────────────┘
```

`Bse.Framework.Auth` has no dependency on RPC, HTTP, or BSE.Common — it is the portable
foundation everything else builds on. `Bse.Framework.Auth.Jwt` depends on Auth and BSE.Common
but not on Rpc. `Bse.Framework.Auth.Rpc` depends on Auth and Rpc but not on Auth.Jwt.
`Bse.Framework.Rpc`'s `AuthenticationInvocationFilter` depends only on the envelope's
`UserId` field — no Auth package reference required (ADR-0014).

### Components

#### Identity Value Object (`Bse.Framework.Auth`)

```csharp
public interface IBseUser
{
    string                           UserId     { get; }
    string?                          UserCode   { get; }
    int?                             CompCode   { get; }
    int?                             BraCode    { get; }
    int?                             FinYear    { get; }
    IReadOnlyCollection<string>      Roles      { get; }
    IReadOnlyDictionary<string,string> Claims   { get; }
    IReadOnlyDictionary<string,string> Extensions { get; }
    bool                             IsAuthenticated { get; }
}
```

`BseUser` is a `sealed record` implementing `IBseUser`. All nine members are positional
constructor parameters; the type is immutable by construction. `BseUser.Empty` is the
singleton unauthenticated sentinel:

```csharp
public static readonly IBseUser Empty = new BseUser(
    UserId: string.Empty, UserCode: null,
    CompCode: null, BraCode: null, FinYear: null,
    Roles: Array.Empty<string>(),
    Claims: new Dictionary<string, string>(StringComparer.Ordinal),
    Extensions: new Dictionary<string, string>(0, StringComparer.Ordinal),
    IsAuthenticated: false);
```

`IBseUser` mirrors `BSE.Common.Security.Tokens.UserTokenContext` to allow one-to-one mapping
from a validated JWT with no impedance mismatch.

#### Accessor (`Bse.Framework.Auth`)

```csharp
public interface IBseUserAccessor
{
    IBseUser    Current { get; }           // never null; returns BseUser.Empty when no user pushed
    IDisposable Push(IBseUser user);       // scope user to current async context; restores on Dispose
}
```

`AsyncLocalBseUserAccessor` backs the accessor with a `static readonly AsyncLocal<IBseUser?>`.
The static field means all DI-resolved instances share the same slot — middleware writing the
slot is visible anywhere in the same async context tree, regardless of which instance holds the
reference. This is the same pattern ASP.NET Core uses for `IHttpContextAccessor`.

`Push` captures the previous value, sets the slot, and returns a `RestoreScope` that writes
the previous value back on `Dispose`. The implementation is idempotent-on-double-dispose via a
`_disposed` guard.

`AddBseAuth()` registers the accessor via `TryAddSingleton`, so services that call it multiple
times (e.g. when both the JWT and RPC integration call it as a prerequisite) always end up with
a single shared instance.

#### JWT Adapter (`Bse.Framework.Auth.Jwt`)

This package contains **zero JWT cryptography**. It is a thin adapter over BSE.Common's auth
pipeline (ADR-0004):

```csharp
// DI registration — delegates entirely to BSE.Common
public static IBseFrameworkBuilder AddBseAuthJwt(
    this IBseFrameworkBuilder builder,
    IConfiguration configuration,
    Action<BseAuthJwtBuilder>? configure = null)
```

`BseAuthJwtBuilder` exposes two methods:

| Method | Delegation target |
|---|---|
| `UseJwtBearer()` | `services.AddBseAuth(configuration)` (BSE.Common) — registers JWT bearer, `ITokenGenerator`, `IRefreshTokenGenerator`, and authorization policies |
| `UseSecurity()` | `services.AddBseSecurity(configuration)` (BSE.Common) — registers `IEncryptionService`, `IPasswordHasher`, `IDataHasher`, `ITotpService` |

When `configure` is `null` both methods are called automatically. When a custom callback is
supplied, the caller is responsible for invoking `UseJwtBearer()` and `UseSecurity()` as
needed — forgetting `UseSecurity()` leaves `IPasswordHasher` unregistered.

`BseAuthUserMiddleware` runs after `UseAuthentication` / `UseAuthorization` and maps the
`ClaimsPrincipal` to `IBseUser`:

| JWT claim | `IBseUser` member | Notes |
|---|---|---|
| `uid` | `UserId` | Falls back to `ClaimTypes.NameIdentifier` |
| `user_code` | `UserCode` | Null when claim absent |
| `comp_code` | `CompCode` | `int.TryParse`; non-numeric → `null` |
| `bra_code` | `BraCode` | `int.TryParse`; non-numeric → `null` |
| `fin_year` | `FinYear` | `int.TryParse`; non-numeric → `null` |
| `roles` (repeated) | `Roles` | All occurrences collected in declaration order |
| all claims | `Claims` | First-wins on duplicate types |
| `ext_*` claims | `Extensions` | Prefix stripped: `ext_dept` → `Extensions["dept"]` |

For unauthenticated requests (`HttpContext.User.Identity.IsAuthenticated == false`) the
middleware is a no-op; `IBseUserAccessor.Current` continues to return `BseUser.Empty`.

The full pipeline is registered by:

```csharp
// Program.cs / Startup.cs

// DI
builder.Services.AddBseFramework()
    .AddBseAuthJwt(configuration);       // wires BSE.Common JWT + BseUser mapping

// Middleware — order matters
app.UseRouting();
app.UseBseAuthJwt();                     // UseAuthentication + UseAuthorization + BseAuthUserMiddleware
app.UseBseMultiTenancy();                // reads tenant_id claim after authentication
app.MapControllers();
```

#### Cross-Process Identity (`Bse.Framework.Auth.Rpc`, ADR-0013)

Two singletons bridge the `IBseUserAccessor` slot and the `TransportMessage` envelope.

**Outgoing decorator** — stamps envelopes before publishing:

```csharp
public TransportMessage Decorate(TransportMessage envelope)
{
    var current = _accessor.Current;

    if (!current.IsAuthenticated || envelope.UserId is not null)
        return envelope;                 // no-op: anonymous or already stamped

    return envelope with { UserId = current.UserId, UserCode = current.UserCode };
}
```

The `envelope.UserId is not null` guard prevents accidental overwrite of an explicitly-set
identity — useful for background jobs that synthesize their own caller identity.

**Inbound scope** — reconstructs a minimal user from the envelope before the handler is
resolved:

```csharp
public IDisposable Push(TransportMessage envelope)
{
    if (envelope.UserId is null)
        return NoOpDisposable.Instance;  // singleton; no heap allocation for open methods

    var minimalUser = new BseUser(
        UserId: envelope.UserId,
        UserCode: envelope.UserCode,
        CompCode: null, BraCode: null, FinYear: null,
        Roles: Array.Empty<string>(),
        Claims: new Dictionary<string, string>(0, StringComparer.Ordinal),
        Extensions: new Dictionary<string, string>(0, StringComparer.Ordinal),
        IsAuthenticated: true);

    return _accessor.Push(minimalUser);
}
```

Only `UserId` and `UserCode` travel cross-process. Roles, claims, `CompCode`, `BraCode`, and
`FinYear` are not propagated — downstream handlers that need them must re-fetch from the auth
backend. This is a deliberate security boundary: a rogue upstream service cannot escalate
privileges by forging claims in the envelope.

`UserCode` was added alongside `UserId` because application code historically used
`UserCode` (the human-readable login code, e.g. `"ADMIN"`) as the semantic caller identifier
in business operations. Propagating only `UserId` would require every downstream handler to
perform an extra lookup to recover `UserCode`, which is a read-only attribute of the token and
safe to carry in the envelope.

Registration:

```csharp
builder.Services.AddBseFramework()
    .AddBseAuthRpcIntegration();   // registers BseUserRpcEnvelopeScope + BseUserOutgoingEnvelopeDecorator
```

Both are registered as singletons. The method ensures `AddBseAuth()` has been called first.

#### Per-Handler Authorization Gate (`Bse.Framework.Rpc`, ADR-0014)

Handlers are marked declaratively:

```csharp
[BseRpcHandler("students.get")]
[RequiresAuthentication]
public sealed class GetStudentHandler : IRpcHandler<GetStudentRequest, GetStudentResponse>
{ ... }
```

The source generator (`Bse.Framework.SourceGenerators`) detects `[RequiresAuthentication]` on
the handler class at compile time and emits `requiresAuthentication: true` into the generated
`HandlerDescriptor`:

```csharp
public sealed record HandlerDescriptor(
    string Method,
    Type   RequestType,
    Type?  ResponseType,
    Type   HandlerType,
    Func<IServiceProvider, JsonElement, CancellationToken, ValueTask<JsonElement?>> Invoker,
    bool   RequiresAuthentication = false);
```

At runtime, `AuthenticationInvocationFilter` — an `IRpcInvocationFilter` registered inside
`Bse.Framework.Rpc` with no dependency on `Bse.Framework.Auth` — runs as the first step of
the invocation-filter pipeline:

```csharp
public ValueTask<RpcError?> BeforeInvokeAsync(RpcInvocationContext context, CancellationToken ct)
{
    if (context.Descriptor.RequiresAuthentication && context.Envelope.UserId is null)
    {
        return new ValueTask<RpcError?>(new RpcError(
            RpcErrorCodes.Unauthenticated,
            "This method requires an authenticated caller."));
    }
    return new ValueTask<RpcError?>((RpcError?)null);
}
```

The filter runs after the inbound envelope scope has been pushed (so `IBseUserAccessor.Current`
is already populated) but before the handler is resolved from DI. A rejected call never
allocates a DI scope.

The check uses `envelope.UserId is null` rather than `accessor.Current.IsAuthenticated` so that
the filter remains independent of the Auth package and testable without it.

### Data Flow

```
 Browser / API client
        │  JWT (Bearer)
        ▼
 BSE.Common UseAuthentication
 BSE.Common UseAuthorization
        │  ClaimsPrincipal
        ▼
 BseAuthUserMiddleware
        │  IBseUserAccessor.Push(BseUser{...all claims...})
        ▼
 Application code / Controller
        │  RPC call via IRpcClient
        ▼
 BseUserOutgoingEnvelopeDecorator
        │  envelope with { UserId=..., UserCode=... }
        ▼
 Transport (Redis Streams / HTTP)
        │  TransportMessage.UserId + .UserCode
        ▼
 Downstream Service — RpcDispatcher
        │  BseUserRpcEnvelopeScope.Push(minimalUser)
        │  IBseUserAccessor.Current = BseUser{UserId, UserCode, IsAuthenticated=true}
        ▼
 AuthenticationInvocationFilter
        │  if RequiresAuthentication && UserId is null → RpcError(-32006)
        ▼
 Handler.HandleAsync(request, ct)
        │  accessor.Current.UserCode   ← available without any extra lookup
        ▼
 Response
```

### Configuration

```csharp
// HTTP service (with JWT)
builder.Services.AddBseFramework()
    .AddBseAuthJwt(configuration)          // JWT + security primitives (default)
    .AddBseAuthRpcIntegration();           // propagation decorators

// Worker / consumer (RPC only, no HTTP)
builder.Services.AddBseFramework()
    .AddBseAuth()                          // accessor only
    .AddBseAuthRpcIntegration();

// Custom JWT options
builder.Services.AddBseFramework()
    .AddBseAuthJwt(configuration, jwt =>
    {
        jwt.ConfigureAuth(options => { options.RequireHttpsMetadata = false; });
        jwt.UseSecurity();
    });
```

The `JWT` configuration section (key, issuer, audience) and the `BSE:Security` section
(encryption parameters, hashing) are read by BSE.Common, not by this package. See BSE.Common
documentation for the full schema.

### Error Handling

| Condition | Exception | `ErrorCode` | HTTP | RPC |
|---|---|---|---|---|
| No credentials / expired / bad signature | `BseAuthenticationException` | `AuthenticationRequired` | 401 | -32006 |
| Authenticated but lacks permission | `BseAuthorizationException` | `Forbidden` | 403 | -32007 |

`BseAuthenticationException` and `BseAuthorizationException` are defined in
`Bse.Framework.Core.Exceptions` and extend `BseException`. Neither carries sensitive
information (token values, key material) in the message — only a human-readable reason.

The built-in `AuthenticationInvocationFilter` returns a `RpcError(RpcErrorCodes.Unauthenticated,
...)` directly rather than throwing, so the dispatcher surfaces the error as a well-formed
JSON-RPC error response without an exception allocation.

### Security Considerations

**Minimal identity over the wire.** Envelope propagation carries only `UserId` and `UserCode`.
Roles, claims, `CompCode`, `BraCode`, and `FinYear` are intentionally excluded. This limits the
blast radius of a rogue upstream service: it cannot forge a high-privilege identity in the
envelope, because the downstream handler re-fetches authoritative roles from the auth backend
when it needs them. This aligns with the NIST SP 800-63B principle of assurance-level-appropriate
credential binding.

**No-overwrite guard.** The outgoing decorator skips stamping when `envelope.UserId is not null`.
Background jobs can synthesize a service-identity user and stamp it explicitly without risk of
it being overwritten by the accessor slot.

**Unauthenticated vs. Forbidden.** The `-32006`/`-32007` distinction is explicit and maps to
HTTP 401/403 semantics: `-32006` means "we don't know who you are"; `-32007` means "we know
who you are but you can't do this". Clients must not treat them interchangeably.

**AsyncLocal isolation.** `AsyncLocal<T>` propagates into child contexts but not into sibling
tasks spawned after the parent's context is set. A `Task.Run` body inside a request sees the
correct user; a fire-and-forget task started before authentication completes sees `BseUser.Empty`.
This is the intended behaviour — ambient identity should not leak across logical boundaries.

**Downstream re-fetch requirement.** Services receiving a propagated identity receive a `BseUser`
with empty `Roles`, `Claims`, and `Extensions`. Any code that gates access on roles must re-fetch
the full user from the auth backend. Structural enforcement: the reconstructed `BseUser` has
empty collections, so a naive `user.Roles.Contains("admin")` check reliably returns `false`.

### Observability

`BseLogScopes` (in `Bse.Framework.Core.Logging`) defines the canonical structured-log keys:

```csharp
public const string UserIdKey = "UserId";
```

The RPC dispatcher calls `BseLogScopes.Request(traceId, spanId, correlationId, tenantId, userId)`
and begins a log scope for every dispatch, enriching every log line emitted by the handler with
`UserId` and `UserCode`. No additional configuration is required.

### Testing Strategy

Three test projects cover the auth stack:

- `Bse.Framework.Auth.Tests` — unit tests for `AsyncLocalBseUserAccessor`: slot isolation across
  parallel tasks, restore-on-dispose, double-dispose safety, and `BseUser.Empty` identity.
- `Bse.Framework.Auth.Jwt.Tests` — unit tests for `BseAuthUserMiddleware`: each claim mapping
  path, non-numeric `comp_code` → `null`, `ext_*` prefix stripping, unauthenticated principal
  no-op, and `uid`/`NameIdentifier` fallback order.
- `Bse.Framework.Auth.Rpc.Tests` — unit tests for `BseUserRpcEnvelopeScope` and
  `BseUserOutgoingEnvelopeDecorator`: null-envelope no-op, authenticated stamping, no-overwrite
  guard, and minimal-user reconstruction.

End-to-end coverage is provided by `TenantAndUserRpcPropagationTests` in
`Bse.Framework.Testing.Tests`, which exercises a two-service in-memory rig: Service A
authenticates a user, makes an RPC call, and Service B's handler asserts that
`IBseUserAccessor.Current` contains the expected `UserId` and `UserCode`.

## Migration Path

The primary migration target is the legacy DES-token pattern:

| Legacy pattern | Framework replacement |
|---|---|
| `SecuritySystem.Encrypt(GUID, "Business-Systems")` | BSE.Common `ITokenGenerator` (JWT) via `AddBseAuthJwt` |
| `CheckUser(Token, UserCode)` in every controller action | `[RequiresAuthentication]` on the RPC handler + `IBseUserAccessor.Current` |
| Manual `CompCode` extraction from session table | `IBseUserAccessor.Current.CompCode` (mapped from `comp_code` JWT claim) |
| `UserCode ?? UserId` fallback string in every service | Explicit `UserId` / `UserCode` pair on `IBseUser`; no null-coalescing required |
| Hand-rolled propagation through method parameters | `BseUserOutgoingEnvelopeDecorator` stamps automatically; `BseUserRpcEnvelopeScope` restores automatically |

Steps for an existing HTTP service:

1. Replace `AddBseAuth(configuration)` (BSE.Common extension) with
   `.AddBseFramework().AddBseAuthJwt(configuration)`.
2. Replace `app.UseBseAuth()` with `app.UseBseAuthJwt()`.
3. Inject `IBseUserAccessor` in place of direct `HttpContext.User` access.
4. Add `[RequiresAuthentication]` to handlers that previously called `CheckUser()`.
5. If calling downstream services via RPC, add `.AddBseAuthRpcIntegration()` to DI.

## Open Questions

**Policy-based authorization.** `[RequiresAuthentication]` is the coarse gate — it verifies
that a caller is known but does not check what they are allowed to do. A `[RequiresPolicy]`
attribute (or `[RequiresRole]`) that plugs into the same invocation-filter pipeline is designed
but not yet built. When it is, `AuthenticationInvocationFilter` will be joined by an
`AuthorizationInvocationFilter` that evaluates the policy against `IBseUserAccessor.Current`.
Handlers that need fine-grained access control must implement their own checks for now.

**Role propagation.** The deliberate decision not to propagate roles cross-process means services
with frequent inter-service calls may see elevated latency from repeated auth-backend lookups.
A read-through cache keyed on `UserId` with a short TTL (aligned to token lifetime) is the
expected mitigation, but no framework-provided cache exists yet.

**Token-lifetime alignment.** The inbound scope reconstructs a user with `IsAuthenticated=true`
for the duration of the handler. There is no check that the original JWT has not expired between
the envelope being stamped and the handler running. For same-datacenter calls this window is
negligible; for queued or deferred RPC calls it may be significant. Envelope deadline
enforcement (`RpcErrorCodes.DeadlineExceeded`) partially mitigates this but does not verify
token validity independently.

## References

- ADR-0004: Hybrid Authentication — Opaque Tokens for Users + JWT for Services
- ADR-0008: Source Generator Automation (`[RequiresAuthentication]` compile-time wiring)
- RFC-0001: BSE Framework Overview
- RFC-0002: RPC and Distributed Computing
- RFC-0006: Multi-Tenancy (parallel envelope propagation pattern)
- NIST SP 800-63B-4 (July 2025): https://csrc.nist.gov/pubs/sp/800/63/b/4/final
- OAuth 2.0 (RFC 6749) / OIDC Core 1.0
- ASP.NET Core Identity: `Microsoft.AspNetCore.Identity.Core`
- AsyncLocal&lt;T&gt; propagation semantics: https://docs.microsoft.com/en-us/dotnet/api/system.threading.asynclocal-1
- OWASP ASVS 5.0
