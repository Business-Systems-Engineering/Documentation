# ADR-0001: Modular NuGet Package Architecture

- **Status:** Accepted
- **Date:** 2026-04-06
- **Deciders:** BSE Framework Team
- **Tags:** architecture, packaging, modularity

## Context

Three existing BSE applications — Stud2, SafePack2, and Orange2 — duplicate massive amounts of
infrastructure code: `BaseController`, `BaseResponse`, `GenericRepository`, `UnitOfWork`,
`SecuritySystem`, shared utilities, and `IocConfigurator`. Each app carries 40–240 manual service
registrations and 100–449 entities. Every bug fix or improvement must be applied three times.

The framework must eliminate this duplication while supporting both greenfield services and
gradual, one-module-at-a-time migration of the three legacy apps. A single big-bang rewrite
is not viable given concurrent feature work.

Additional forces:

- **Feature optionality.** A service that needs only auth and RPC should not carry the data or
  localization packages. The framework must be composable, not monolithic.
- **Overridability.** Downstream services must be able to substitute their own implementations
  without forking the framework. `TryAdd*` semantics throughout.
- **Prerequisite safety.** Packages that depend on each other (e.g. `Bse.Framework.Rpc.RedisStreams`
  requires `Bse.Framework.Rpc`) must be able to assert that their prerequisites are registered
  at composition time, not at runtime.

## Decision

Ship the framework as **21 focused NuGet packages** following the `Microsoft.Extensions.*`
pattern — abstractions separate from implementations — composed through a shared
`IBseFrameworkBuilder` + `IBseModule` system.

```csharp
// Entry point — always called first
services.AddBseFramework(builder =>
{
    builder.AddBseRpc(rpc =>
    {
        rpc.ServiceName = "billing-service";
        rpc.UseEncryptedBrotliCodec()
           .UseEnvironmentKeys();
    })
    .AddBseDataEntityFramework<BillingDbContext>(
        opts => opts.UseNpgsql(connStr),
        ef  => ef.EnableMigrations = true)
    .AddBseTelemetry();
});
```

The 21 packages shipped are:

| Package | Role |
|---|---|
| `Bse.Framework.Core` | Primitives, DI builder, exceptions, clock, Result |
| `Bse.Framework.Auth` | Auth abstractions (`IBseUserAccessor`, `IBseUser`) |
| `Bse.Framework.Auth.Jwt` | JWT bearer token validation |
| `Bse.Framework.Auth.Rpc` | Identity propagation over RPC envelopes |
| `Bse.Framework.Data` | Repository + UoW abstractions |
| `Bse.Framework.Data.Dapper` | Dapper query side |
| `Bse.Framework.Data.EntityFramework` | EF Core command side |
| `Bse.Framework.Localization` | `ILocalizationProvider` abstraction |
| `Bse.Framework.Localization.Hijri` | Hijri calendar localization |
| `Bse.Framework.MultiTenancy` | `ITenantContextAccessor` abstraction |
| `Bse.Framework.MultiTenancy.AspNetCore` | HTTP tenant resolution |
| `Bse.Framework.MultiTenancy.Rpc` | Tenant propagation over RPC envelopes |
| `Bse.Framework.Rpc` | JSON-RPC 2.0 protocol, dispatcher, codec |
| `Bse.Framework.Rpc.Http` | HTTP transport implementation |
| `Bse.Framework.Rpc.RedisStreams` | Redis Streams transport implementation |
| `Bse.Framework.SourceGenerators` | Roslyn source generators |
| `Bse.Framework.SourceGenerators.Attributes` | Attributes consumed by generators |
| `Bse.Framework.Telemetry` | OpenTelemetry wiring |
| `Bse.Framework.Testing` | `IdentityCodec`, in-memory transport, test helpers |
| `Bse.Framework.Validation` | `IValidator<T>` abstraction + FluentValidation adapter |
| `Bse.Framework.Web` | ASP.NET Core extensions, middleware |

**`IBseModule`** is a no-op marker interface. Each package registers its own module type with
`IBseFrameworkBuilder.RegisterModule<T>()`. Dependent packages call `HasModule<T>()` to assert
prerequisites at registration time rather than failing silently at runtime.

**`TryAdd*`** is used throughout so downstream services can register their own implementations
before calling framework extension methods and win without forking the package.

## Options Considered

### Option A: Single monolithic `Bse.Framework` package
- **Pros:** One package to version, trivial onboarding, no cross-package coordination.
- **Cons:** Every service pulls the entire dependency tree. Auth-only services get Redis, EF,
  and Brotli on their classpath. Breaking changes in one area force a major bump everywhere.

### Option B: Modular abstraction + implementation packages [chosen]
- **Pros:** Services pay only for what they use. Abstractions can be stabilized independently of
  implementations. `TryAdd*` makes overridability natural. `HasModule<T>()` catches missing
  prerequisites at startup. Source generators land as separate analyzer packages with no runtime
  dependency graph overhead.
- **Cons:** 21 packages to version and publish. Cross-package version coordination requires
  `Directory.Build.props`. More documentation surface.

### Option C: Feature-folder monolith with conditional compilation
- **Pros:** Single assembly, no NuGet graph.
- **Cons:** Conditional compilation flags are fragile and untestable in isolation. Tree-shaking
  on .NET assemblies is not reliable enough to drop unused dependencies at publish time.
  Incremental adoption by legacy apps becomes a forking exercise.

## Rationale

The `Microsoft.Extensions.*` pattern is the established .NET idiom for this problem: abstractions
in one package, implementations in another, consumers depend on abstractions. It enables the
gradual adoption path required for the legacy apps (SafePack2 can adopt `Bse.Framework.Auth` first)
while keeping each implementation independently versionable. Option C's monolith defers the
modularization problem rather than solving it. Option A's single package solves the distribution
problem but not the dependency-footprint problem.

## Consequences

### Positive
- Each service's dependency graph is minimal and explicit.
- `HasModule<T>()` prerequisite checks catch misconfiguration at application startup.
- `TryAdd*` throughout enables downstream override without forking.
- Gradual migration path: a legacy app adopts one package at a time.
- Source generators (`Bse.Framework.SourceGenerators`) eliminate repository/query/registration
  boilerplate without runtime overhead.

### Negative
- 21 packages to keep in version sync; `Directory.Build.props` is the coordination mechanism.
- Source generator packages have packaging constraints (`netstandard2.0`, `analyzers/` folder).
- Onboarding documentation must explain the builder pattern and module markers.

### Neutral
- A future opinionated app-host layer (Aspire-style single entrypoint) can be built on top of
  this package set without changing the packages themselves.
- Each package ships its own `README.md`, integration tests, and CI gate.

## References

- RFC-0001: Framework Overview
- ADR-0009: Transport Abstraction Pattern
- `Microsoft.Extensions.*` split pattern (abstractions vs. implementations)
- ABP Framework (`Volo.Abp.*` modular package structure)
