# RFC-0008: Web Hardening and Validation

- **Status:** Implemented
- **Date:** 2026-07-05
- **Authors:** BSE Framework Team
- **Related ADRs:** ADR-0001, ADR-0004
- **Related RFCs:** RFC-0001, RFC-0004

## Abstract

`Bse.Framework.Validation` and `Bse.Framework.Web` are two thin adapter packages that surface BSE.Common's security-validation primitives and HTTP hardening middleware behind stable, framework-shaped facades. Neither package contains validation or security logic of its own — every implementation lives in the vetted `BSE.Common.Security` library. The packages exist to satisfy ADR-0001 (modular packages) and ADR-0004 (reuse of BSE.Common) while keeping application code isolated from the `BSE.Common.Security.*` namespace hierarchy.

## Motivation

Before these packages, individual BSE services referenced `BSE.Common.Security.Validation` and `BSE.Common.Security.Middleware` directly. That coupling created two problems:

1. **BSE.Common version skew.** When BSE.Common consolidated or renamed types (e.g., v0.2.0 merged `TrimAndNormalize`, `StripControlCharacters`, and `Truncate` into a single `InputSanitizer.Clean` entry point), every service had to update its call sites simultaneously.
2. **Scattered per-app configuration.** Security headers and rate limiting policies were configured differently — or omitted entirely — in each application. No per-app scaffolding enforced the baseline OWASP ASVS-aligned header set.

The adapter pattern puts one seam between application code and BSE.Common: application services depend on `Bse.Framework.Validation` and `Bse.Framework.Web` only, and the framework packages absorb future BSE.Common refactors without propagating them outward.

## Goals

- Expose BSE.Common's FluentValidation rules, input sanitizer, and file-upload attributes under the `Bse.Framework.Validation` namespace.
- Expose BSE.Common's `SecurityHeadersMiddleware` and preconfigured rate-limiting policies under the `Bse.Framework.Web` namespace.
- Wire both packages into the standard `IBseFrameworkBuilder` fluent registration chain (`AddBseValidation` / `AddBseWeb`).
- Allow the underlying BSE.Common surface to evolve (renamed types, merged methods, new options) behind a stable public API.
- Provide explicit shims for the two BSE.Common 0.2.0 removals (`StripControlCharacters`, `Truncate`) so existing call sites require no migration.

## Non-Goals

- Defining new validation logic or security algorithms. All logic lives in BSE.Common.
- Exception-to-ProblemDetails mapping. That responsibility belongs to `Bse.Framework.Core` (`BseValidationException` → HTTP 400 / RPC -32602).
- Health checks, endpoint conventions, Minimal API helpers, or controller base classes.
- RPC-layer error mapping (handled in Core middleware).

## Design

### Package Structure

```
Bse.Framework.Validation/
  BseValidationBuilder.cs          ← fluent builder
  BseValidationModule.cs           ← marker module
  DependencyInjection/
    BseFrameworkBuilderExtensions.cs  ← AddBseValidation()
  Rules/
    BseCommonValidationRules.cs    ← re-export of FluentValidation rules
  Sanitization/
    BseInputSanitizer.cs           ← facade + two locally-reimplemented shims
  Attributes/
    BseAllowedExtensionsAttribute.cs
    BseContentTypeAttribute.cs
    BseMaxFileSizeAttribute.cs

Bse.Framework.Web/
  BseWebBuilder.cs                 ← fluent builder (marker only; no service registrations by default)
  BseWebModule.cs                  ← marker module
  DependencyInjection/
    BseFrameworkBuilderExtensions.cs  ← AddBseWeb()
    ApplicationBuilderExtensions.cs  ← UseBseWebHardening()
    BseRateLimitingExtensions.cs     ← AddRateLimiting() / UseRateLimiting()
```

### Bse.Framework.Validation

#### Registration

```csharp
// Startup / Program.cs
builder.Services
    .AddBseFramework()
    .AddBseValidation()          // default: registers ValidationFilterAttribute
    .AddBseWeb();
```

`AddBseValidation` signature:

```csharp
public static IBseFrameworkBuilder AddBseValidation(
    this IBseFrameworkBuilder builder,
    Action<BseValidationBuilder>? configure = null)
```

When `configure` is `null`, the default path calls `BseValidationBuilder.UseValidationFilter()` automatically, which registers BSE.Common's `ValidationFilterAttribute` as a scoped service. That MVC action filter intercepts model-state failures and converts them to the framework's standard error envelope before the controller body executes. If the caller supplies a `configure` callback it takes full control; the default is bypassed.

`BseValidationBuilder.UseValidationFilter`:

```csharp
public BseValidationBuilder UseValidationFilter()
{
    Services.AddScoped<ValidationFilterAttribute>();
    return this;
}
```

`BseValidationModule` is a marker (`IBseModule` with an empty `Configure`) used by the framework's module registry to detect double-registration.

#### FluentValidation Rules

`BseCommonValidationRules` is a zero-logic static facade. Every method is a one-liner that delegates to `BSE.Common.Security.Validation.Rules.CommonValidationRules`:

```csharp
// re-exported as IRuleBuilder<T,string> extension methods
MustBeValidEmail<T>()
MustBeValidPhone<T>()               // international format, e.g. +966XXXXXXXXX
MustBeValidSaudiId<T>()             // 10 digits, starts with 1 or 2
MustBeValidCommercialRegistration<T>()  // 10-digit CR number
MustBeStrongPassword<T>()           // ≥8 chars, upper + lower + digit + special
```

Application validators import `Bse.Framework.Validation.Rules` rather than `BSE.Common.Security.Validation.Rules`. If BSE.Common ever renames its namespace, only this file changes.

#### Input Sanitizer

`BseInputSanitizer` wraps `BSE.Common.Security.Validation.InputSanitizer`. Two methods delegate to BSE.Common; two are reimplemented locally because BSE.Common 0.2.0 removed them:

| Method | Implementation |
|---|---|
| `TrimAndNormalize(string?)` | Delegates to `InputSanitizer.Clean(input, new CleanOptions())` |
| `HtmlEncode(string?)` | Delegates to `InputSanitizer.HtmlEncode` |
| `StripControlCharacters(string?)` | Reimplemented locally (BSE.Common 0.2.0 dropped it) |
| `Truncate(string?, int)` | Reimplemented locally (BSE.Common 0.2.0 dropped it) |

The behavior of `TrimAndNormalize` changed in BSE.Common 0.2.0: the new `Clean` also collapses interior whitespace runs, whereas the old `TrimAndNormalize` only trimmed edges. This difference is documented in the XML summary on the method.

#### File-Upload Attributes

`BseAllowedExtensionsAttribute`, `BseContentTypeAttribute`, and `BseMaxFileSizeAttribute` are thin `sealed` subclasses that inherit from the corresponding `BSE.Common.Security.Validation.Attributes.*` types. All validation logic lives in the base class; the subclasses exist solely to move the namespace consumers reference.

```csharp
// Usage example
[BseAllowedExtensions(".pdf", ".docx")]
[BseContentType("application/pdf")]
[BseMaxFileSize(5 * 1024 * 1024)]   // 5 MB
public IFormFile Document { get; set; }
```

#### Error Surfacing

Validation failures throw `BseValidationException` (defined in `Bse.Framework.Core`). The Core middleware maps it to HTTP 400 ProblemDetails for REST controllers and to JSON-RPC error code -32602 (Invalid params) for RPC handlers. This package has no role in that mapping.

### Bse.Framework.Web

#### Registration

```csharp
builder.Services
    .AddBseFramework()
    .AddBseWeb(web =>
    {
        web.Services.AddRateLimiting();   // opt-in; not wired by default
    });

// Middleware pipeline
app.UseBseWebHardening();   // security headers
app.UseRateLimiting();       // if AddRateLimiting() was called above
```

`AddBseWeb` signature:

```csharp
public static IBseFrameworkBuilder AddBseWeb(
    this IBseFrameworkBuilder builder,
    Action<BseWebBuilder>? configure = null)
```

Unlike `AddBseValidation`, the `null` default for `AddBseWeb` performs **no service registrations** beyond recording `BseWebModule` in the module registry. Rate limiting is opt-in via the `configure` callback. `BseWebModule.Configure` is intentionally empty for the same reason: middleware registration belongs in the `IApplicationBuilder` pipeline, not at service-registration time.

#### Security Headers

```csharp
public static IApplicationBuilder UseBseWebHardening(this IApplicationBuilder app)
```

Delegates to `BSE.Common.Security.DependencyInjection.ServiceCollectionExtensions.UseBseSecurityHeaders`, which installs `SecurityHeadersMiddleware`. That middleware sets the following on every response:

| Header | Value |
|---|---|
| `X-Content-Type-Options` | `nosniff` |
| `X-Frame-Options` | `DENY` |
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains` |
| `Referrer-Policy` | `strict-origin-when-cross-origin` |
| `X-XSS-Protection` | `1; mode=block` |
| `Content-Security-Policy` | BSE.Common default policy |

It also strips `Server` and `X-Powered-By` from every response. This set satisfies OWASP ASVS v4.0 V14.4 (HTTP Security Headers) and the OWASP Secure Headers Project baseline.

#### Rate Limiting

`BseRateLimitingExtensions` re-exports BSE.Common's `RateLimitingExtensions`:

```csharp
// Service registration
public static IServiceCollection AddRateLimiting(this IServiceCollection services)
    => services.AddBseRateLimiting();

// Middleware
public static IApplicationBuilder UseRateLimiting(this IApplicationBuilder app)
    => app.UseBseRateLimiting();
```

BSE.Common's preconfigured policies (all fixed-window, keyed per source IP):

| Policy name | Limit | Window | Queue depth |
|---|---|---|---|
| Global (default) | 100 req | 1 min | — |
| `"login"` | 5 req | 1 min | — |
| `"api"` | 30 req | 1 min | 2 |

The implementation uses ASP.NET Core's `System.Threading.RateLimiting` (introduced in .NET 7) via the `Microsoft.AspNetCore.RateLimiting` middleware. Distribution is local (in-process) in the current BSE.Common release; Redis-backed distributed enforcement is deferred to a future BSE.Common version.

### Dependency Graph

```
Bse.Framework.Validation  ──▶  Bse.Framework.Core
                           ──▶  BSE.Common (Security.Validation.*)
                           ──▶  Microsoft.AspNetCore.App

Bse.Framework.Web         ──▶  Bse.Framework.Core
                           ──▶  BSE.Common (Security.Middleware.*)
                           ──▶  Microsoft.AspNetCore.App
```

Neither package references FluentValidation directly — `IValidator<T>` is consumed transitively through BSE.Common and exposed via the extension methods on `IRuleBuilder<T,string>`.

### Adapter Rationale

ADR-0001 requires that each framework concern live in its own NuGet package so services take only the dependencies they need. ADR-0004 requires that the framework reuse BSE.Common's security implementations rather than reimplementing them. These two constraints together produce the adapter shape:

- `Bse.Framework.Validation` and `Bse.Framework.Web` satisfy ADR-0001 by being separate packages with clearly scoped responsibilities.
- Both packages satisfy ADR-0004 by containing zero security logic; every call either delegates directly to BSE.Common or (for removed BSE.Common primitives) reimplements the identical behavior locally with a documented shim comment.
- Application code depends on framework-shaped types (`BseCommonValidationRules`, `BseInputSanitizer`, `BseAllowedExtensionsAttribute`) rather than `BSE.Common.Security.*` types, so future BSE.Common refactors are absorbed at the framework boundary.

### What Is Not Here

The following concerns are intentionally outside these two packages:

- **Exception → ProblemDetails mapping.** Owned by `Bse.Framework.Core`.
- **RPC error code mapping** (JSON-RPC -32602, -32603). Owned by `Bse.Framework.Core`.
- **Health checks.** Owned by `Bse.Framework.Core`.
- **Endpoint conventions, Minimal API helpers, controller base classes.** Not in scope for this RFC.
- **CORS policy configuration.** Documented in RFC-0004; lives in `Bse.Framework.Auth`.
- **Custom IValidator&lt;T&gt; abstraction.** FluentValidation's own `IValidator<T>` is used directly; no framework wrapper is defined here.

## API / Interfaces

### Bse.Framework.Validation public surface

```csharp
// Registration
IBseFrameworkBuilder AddBseValidation(Action<BseValidationBuilder>? configure = null)

// Builder
sealed class BseValidationBuilder
    IBseFrameworkBuilder Framework { get; }
    IServiceCollection Services { get; }
    BseValidationBuilder UseValidationFilter()

// Rules (FluentValidation extension methods)
static class BseCommonValidationRules
    IRuleBuilderOptions<T, string> MustBeValidEmail<T>(...)
    IRuleBuilderOptions<T, string> MustBeValidPhone<T>(...)
    IRuleBuilderOptions<T, string> MustBeValidSaudiId<T>(...)
    IRuleBuilderOptions<T, string> MustBeValidCommercialRegistration<T>(...)
    IRuleBuilderOptions<T, string> MustBeStrongPassword<T>(...)

// Sanitizer
static class BseInputSanitizer
    string TrimAndNormalize(string? input)
    string HtmlEncode(string? input)
    string StripControlCharacters(string? input)
    string Truncate(string? input, int maxLength)

// File-upload attributes
sealed class BseAllowedExtensionsAttribute(params string[] extensions)
sealed class BseContentTypeAttribute(params string[] allowedContentTypes)
sealed class BseMaxFileSizeAttribute(long maxFileSizeBytes)
```

### Bse.Framework.Web public surface

```csharp
// Registration
IBseFrameworkBuilder AddBseWeb(Action<BseWebBuilder>? configure = null)

// Builder
sealed class BseWebBuilder
    IBseFrameworkBuilder Framework { get; }
    IServiceCollection Services { get; }

// Middleware
IApplicationBuilder UseBseWebHardening(this IApplicationBuilder app)

// Rate limiting
IServiceCollection AddRateLimiting(this IServiceCollection services)
IApplicationBuilder UseRateLimiting(this IApplicationBuilder app)
```

## Security Considerations

**OWASP ASVS V14.4 (HTTP Security Headers).** `UseBseWebHardening` installs the full baseline header set. Applications must call it early in the pipeline — before any response-writing middleware — to guarantee headers appear on every response including error responses.

**Rate limiting.** The preconfigured policies address OWASP ASVS V4.2.2 (brute force) and complement the login-level lockout in `Bse.Framework.Auth`. The `"login"` policy (5 req/min) is intentionally conservative; it should be applied via `[EnableRateLimiting("login")]` on the token endpoint only.

**Input sanitization scope.** `BseInputSanitizer` is a server-side defense-in-depth measure; it is not a substitute for output encoding. Razor and React encode at render time; `HtmlEncode` is provided for contexts where values are assembled into HTML strings outside of a templating engine. `StripControlCharacters` guards downstream systems (e.g., log injectors, LDAP query builders) that are sensitive to null bytes.

**File upload.** `BseAllowedExtensionsAttribute` and `BseContentTypeAttribute` together enforce two independent checks. Extension alone is insufficient (attackers rename files); `Content-Type` alone is insufficient (the browser header is attacker-controlled). Both attributes should be applied together.

**BSE.Common version pinning.** Because these packages delegate security behavior to BSE.Common, upgrading BSE.Common to a new minor or major version requires a review of any changed behavior that surfaces through the facade. The BSE.Common 0.2.0 `TrimAndNormalize` behavior change (now collapses interior whitespace) is an example of a silent semantic shift that the `BseInputSanitizer` XML summary documents explicitly.

## Testing Strategy

Each package ships a registration test that exercises the full DI wiring:

- **Validation:** Builds a service collection, calls `AddBseValidation()`, resolves `ValidationFilterAttribute` from the container, asserts non-null. A coverage test calls each `BseCommonValidationRules` method and each `BseInputSanitizer` method against known inputs to assert expected outputs.
- **Web:** Builds a `WebApplicationFactory`, calls `AddBseWeb(web => web.Services.AddRateLimiting())`, and calls `UseBseWebHardening()` + `UseRateLimiting()` in the test pipeline. An HTTP probe asserts that `X-Content-Type-Options`, `X-Frame-Options`, and `Strict-Transport-Security` are present on every response.

## Migration Path

| Previous pattern | Framework replacement |
|---|---|
| Direct `BSE.Common.Security.Validation.Rules.CommonValidationRules.*` | `BseCommonValidationRules.*` from `Bse.Framework.Validation.Rules` |
| Direct `BSE.Common.Security.Validation.InputSanitizer.*` | `BseInputSanitizer.*` from `Bse.Framework.Validation.Sanitization` |
| Direct `BSE.Common.Security.Validation.Attributes.*Attribute` | `Bse*Attribute` from `Bse.Framework.Validation.Attributes` |
| Per-app `SecurityHeadersMiddleware` wiring | `app.UseBseWebHardening()` |
| Per-app rate limiting configuration | `web.Services.AddRateLimiting()` + `app.UseRateLimiting()` |
| Missing security headers (legacy apps) | `UseBseWebHardening()` added during migration |

## Open Questions

1. **Extended BSE.Common surface.** BSE.Common exposes additional primitives (e.g., `CleanOptions` flags, additional sanitization modes) that are not yet re-exported here. As consuming services discover needs, additional facade methods should be added to `BseInputSanitizer` rather than leaking BSE.Common types outward.
2. **Distributed rate limiting.** The current BSE.Common `RateLimitingExtensions` is in-process. For multi-instance deployments, a Redis-backed sliding-window policy is needed. This will be absorbed transparently when BSE.Common ships it — no application code change required.
3. **CSP nonce injection.** The default CSP header from BSE.Common is static. Services that render Razor views with inline scripts need per-request nonces. A future `UseBseWebHardening(opt => opt.EnableCspNonces())` overload is under consideration.

## References

- ADR-0001: Modular Package Architecture
- ADR-0004: Hybrid Auth (JWT + Opaque) — establishes BSE.Common as the vetted security library
- RFC-0001: Framework Overview — package dependency model
- RFC-0004: Authentication, Authorization, and Security — CORS, ASVS alignment, rate limiting policy rationale
- FluentValidation: https://docs.fluentvalidation.net/
- OWASP ASVS v4.0 V14.4 (HTTP Security Headers): https://owasp.org/www-project-application-security-verification-standard/
- OWASP Secure Headers Project: https://owasp.org/www-project-secure-headers/
- ASP.NET Core Rate Limiting (`System.Threading.RateLimiting`): https://learn.microsoft.com/aspnet/core/performance/rate-limit
- OWASP ASVS V4.2.2 (Brute Force Controls)
