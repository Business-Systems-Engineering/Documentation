# Bse.Framework Design Documentation

This directory contains the **as-built** architectural documentation for **Bse.Framework**, a modular .NET 9 framework for building distributed, multi-tenant web APIs and microservices. It replaces the duplicated patterns across Stud2, SafePack2, and Orange2 with a single, package-per-concern toolkit hosted in the [`bse-core`](https://github.com/Business-Systems-Engineering/bse-core) monorepo.

> **Status:** The framework is implemented and shipping. This documentation describes the code as it exists in `bse-core/src`, not a forward-looking design. Where a decision has evolved since the original design phase, a superseding ADR records the change.

## Documentation Structure

| Type | Purpose |
|---|---|
| **RFC** (Request for Comments) | Detailed design for a subsystem, kept in step with the shipped code |
| **ADR** (Architecture Decision Record) | A single decision with its context, options, and rationale |

## Quick Navigation

### Start Here
- [RFC-0001: Framework Overview](rfc/0001-framework-overview.md) — architecture, package graph, composition model

### Subsystem Designs (RFCs)

| # | Title | Status |
|---|---|---|
| [0001](rfc/0001-framework-overview.md) | Framework Overview | Implemented |
| [0002](rfc/0002-rpc-distributed-computing.md) | RPC, Source Generation, and the Invocation Pipeline | Implemented |
| [0003](rfc/0003-data-access-layer.md) | Data Access Layer (EF Core + Dapper) | Implemented |
| [0004](rfc/0004-auth-and-security.md) | Authentication, Identity Propagation, and Authorization | Implemented |
| [0005](rfc/0005-telemetry-and-observability.md) | Telemetry and Observability | Implemented |
| [0006](rfc/0006-multi-tenancy.md) | Multi-Tenancy | Implemented |
| [0007](rfc/0007-localization.md) | Localization and Calendars | Implemented |
| [0008](rfc/0008-web-and-validation.md) | Web Hardening and Validation | Implemented |

### Architecture Decisions (ADRs)

| # | Title | Status |
|---|---|---|
| [0001](adr/0001-modular-package-architecture.md) | Modular NuGet Package Architecture | Accepted |
| [0002](adr/0002-json-rpc-over-multiple-transports.md) | JSON-RPC 2.0 Over Multiple Transports | Accepted |
| [0003](adr/0003-ef-core-plus-dapper-hybrid.md) | EF Core + Dapper Hybrid (CQRS Split) | Accepted |
| [0004](adr/0004-auth-via-bse-common-adapter.md) | Authentication via a BSE.Common Adapter | Accepted |
| [0005](adr/0005-opentelemetry-grafana-stack.md) | OpenTelemetry → Grafana Stack | Accepted |
| [0006](adr/0006-hybrid-multi-tenancy.md) | Ambient Tenant Context + EF Query-Filter Isolation | Accepted |
| [0007](adr/0007-calendar-provider-abstraction.md) | Pluggable ICalendarProvider | Accepted |
| [0008](adr/0008-source-generator-automation.md) | Roslyn Source-Generator Handler Registration | Accepted |
| [0009](adr/0009-transport-abstraction-pattern.md) | Segregated Transport Interfaces (ISP) | Accepted |
| [0010](adr/0010-flyway-for-schema-migrations.md) | Opt-In EF Migrations, Flyway by Default | Accepted |
| [0011](adr/0011-rpc-payload-encryption-and-compression.md) | Encrypt and Compress RPC Payloads in Transit | Accepted |
| [0012](adr/0012-aes-gcm-codec-framing-and-key-rotation.md) | AES-256-GCM Codec Framing and Key Rotation | Accepted |
| [0013](adr/0013-cross-process-identity-propagation.md) | Cross-Process Identity Propagation on the Envelope | Accepted |
| [0014](adr/0014-per-handler-authorization-filter-pipeline.md) | Per-Handler Authorization via an Invocation-Filter Pipeline | Accepted |

## Framework at a Glance

### What It Replaces

The framework consolidates patterns previously duplicated across three BSE applications:

| Concern | Stud2 / SafePack2 / Orange2 (legacy) | Bse.Framework |
|---|---|---|
| Runtime | .NET Framework 4.6.1 | .NET 9 |
| API | ASP.NET Web API 5.2.7 | ASP.NET Core (minimal APIs + JSON-RPC) |
| ORM | EF6 DB-First | EF Core (writes) + Dapper (reads) |
| DI | Unity 5.9.3 | Microsoft.Extensions.DependencyInjection |
| Auth | DES tokens | JWT bearer + opaque, via `BSE.Common` adapter |
| Inter-service | direct DB / ad-hoc HTTP | JSON-RPC 2.0 over Redis Streams or HTTP |
| Logging | DB / Prometheus / none | OpenTelemetry → Grafana (Tempo/Loki/Prometheus) |
| Tenancy | implicit CompCode columns | ambient `ITenantContext` + EF query-filter isolation |

### 21 Packages

```
Bse.Framework.Core                            ← DI composition, exceptions, Result<T>, clock, GUIDs, redaction, ProblemDetails, shutdown, health
Bse.Framework.Testing                         ← in-memory RPC transport + two-service test rig

Bse.Framework.Rpc                             ← JSON-RPC 2.0 protocol, encrypted envelope, dispatcher, invocation-filter pipeline
Bse.Framework.Rpc.RedisStreams                ← Redis Streams transport (consumer groups, claim-sweep retry)
Bse.Framework.Rpc.Http                        ← HTTP transport (POST /rpc/{service}, deadline header)
Bse.Framework.SourceGenerators                ← Roslyn generator: handler registration from attributes
Bse.Framework.SourceGenerators.Attributes     ← [BseRpcHandler], [RequiresAuthentication] (netstandard2.0)

Bse.Framework.Data                            ← entity/audit/tenant/concurrency interfaces, specification + repository abstractions, offset pagination
Bse.Framework.Data.EntityFramework            ← EF Core impl: BseDbContext, auditing + concurrency + instrumentation interceptors, query-filter conventions
Bse.Framework.Data.Dapper                     ← Dapper read-side repository for the CQRS query path

Bse.Framework.Auth                            ← IBseUser / IBseUserAccessor identity abstractions (AsyncLocal)
Bse.Framework.Auth.Jwt                        ← JWT/claims → BseUser mapping middleware (adapter over BSE.Common)
Bse.Framework.Auth.Rpc                        ← cross-process identity: outgoing decorator + inbound scope

Bse.Framework.MultiTenancy                    ← ITenantContext(Accessor), resolver chain
Bse.Framework.MultiTenancy.AspNetCore         ← HTTP tenant-resolution middleware (header / host / claim)
Bse.Framework.MultiTenancy.Rpc               ← cross-process tenancy: outgoing decorator + inbound scope

Bse.Framework.Localization                    ← ICalendarProvider abstraction, BseDateOnly, Gregorian default
Bse.Framework.Localization.Hijri              ← Umm al-Qura (Hijri) calendar provider

Bse.Framework.Telemetry                       ← OpenTelemetry traces/metrics/logs, OTLP export, PII redaction
Bse.Framework.Validation                      ← FluentValidation rules + sanitizers (adapter over BSE.Common)
Bse.Framework.Web                             ← security headers + rate limiting (adapter over BSE.Common)
```

### Composition Model

Every service composes the framework through a single DI entry point and a fluent builder:

```csharp
services.AddBseFramework(framework =>
{
    framework.AddBseRpc(rpc =>
    {
        rpc.ServiceName = "students";
        rpc.UseEnvironmentKeys()
           .UseEncryptedBrotliCodec()
           .AddBseRpcGeneratedHandlers();   // emitted by the source generator
        rpc.UseRedisStreams(connectionString).UseRedisStreamsServer();
    });

    framework.AddBseAuth();
    framework.AddBseMultiTenancy(t => t.AddResolver<HeaderTenantResolver>());
    framework.AddBseTelemetry(t => t.UseOtlpExporter(otlpEndpoint));
});

app.UseBseExceptionHandler();   // RFC 9457 Problem Details — must be first
```

Each feature package extends `IBseFrameworkBuilder` with an `AddBseXxx(...)` method, registers a no-op `IBseModule` marker so dependents can assert prerequisites (`HasModule<T>()`), and uses `TryAdd` so applications may pre-register overrides (e.g. a frozen `ISystemClock` in tests).

### Key Design Principles

1. **Modular** — take only the packages you need; abstractions and implementations ship separately (the `Microsoft.Extensions.*` pattern).
2. **Source generators over reflection** — handler registration is generated at compile time; no startup scanning.
3. **Ambient context via AsyncLocal** — identity, tenant, and calendar flow through `AsyncLocal` accessors, stamped onto the RPC envelope at the process boundary and re-pushed on the other side.
4. **Typed error taxonomy** — a flat `BseException` hierarchy maps deterministically to HTTP status codes and JSON-RPC error codes.
5. **Defense in depth** — encrypted RPC payloads, PII-redacted telemetry, EF query-filter tenant isolation, and security-header hardening.
6. **Adapter over `BSE.Common`** — auth, validation, and web-hardening reuse the vetted `BSE.Common.Security` implementations behind framework-shaped facades.
7. **Docker-first, observability-first** — every service emits OTLP traces/metrics/logs to the Grafana stack out of the box.

### Highest-Impact Decisions

1. **JSON-RPC 2.0 over pluggable transports** ([ADR-0002](adr/0002-json-rpc-over-multiple-transports.md), [ADR-0009](adr/0009-transport-abstraction-pattern.md)) rather than gRPC — protocol consistency across Redis Streams and HTTP with segregated `IMessagePublisher`/`IRpcClient`/`IMessageConsumer`/`ITransportHealth` interfaces.
2. **Encrypted, compressed envelopes** ([ADR-0011](adr/0011-rpc-payload-encryption-and-compression.md), [ADR-0012](adr/0012-aes-gcm-codec-framing-and-key-rotation.md)) — AES-256-GCM over Brotli with a versioned frame and key-id-based rotation.
3. **EF Core + Dapper CQRS split** ([ADR-0003](adr/0003-ef-core-plus-dapper-hybrid.md)) — EF for the write model + change tracking + query filters, Dapper for read-side SQL.
4. **Source-generator handler registration** ([ADR-0008](adr/0008-source-generator-automation.md)) — `[BseRpcHandler("method")]` becomes a compile-time registration call, eliminating manual wiring.
5. **Cross-process identity + per-handler authorization** ([ADR-0013](adr/0013-cross-process-identity-propagation.md), [ADR-0014](adr/0014-per-handler-authorization-filter-pipeline.md)) — `UserId`/`UserCode`/`TenantId` travel on the envelope; `[RequiresAuthentication]` is enforced by a reusable invocation-filter pipeline before the handler runs.
6. **Ambient tenancy + query-filter isolation** ([ADR-0006](adr/0006-hybrid-multi-tenancy.md)) — a tenant slug resolved per request/message and enforced by an EF global query filter on `IMultiTenant` entities.

## Documentation Conventions

### RFCs
Each RFC follows: **Abstract → Motivation → Goals / Non-Goals → Design** (Overview, Components, Data Flow, API/Interfaces, Configuration, Error Handling, Performance, Security, Observability, Testing) **→ Migration Path → Open Questions → References**. Template: [`rfc/template.md`](rfc/template.md).

### ADRs
Each ADR follows: **Context → Decision → Options Considered → Rationale → Consequences → References**. Template: [`adr/template.md`](adr/template.md).

### Contributing
1. RFCs track the shipped code — update them when the code changes.
2. ADRs are immutable once accepted; record a change by adding a superseding ADR (e.g. ADR-0004 supersedes the earlier hybrid-auth decision; ADR-0013/0014 extend the RPC design).
3. Cross-link related RFCs and ADRs.

## Implementation Status

Repository: [`Business-Systems-Engineering/bse-core`](https://github.com/Business-Systems-Engineering/bse-core) — monorepo hosting all packages under `src/`, tests under `tests/`, and runnable samples under `samples/`.

All 21 packages are **implemented with unit and integration test suites**. Cross-process integration (identity + tenancy over the RPC envelope) is exercised end-to-end through the in-memory two-service rig in `Bse.Framework.Testing`, and the Redis Streams / HTTP transports are covered by Testcontainers-backed integration tests.

## References to Source Material

The framework design draws on: ABP Framework, MassTransit, Rebus, NServiceBus, Dapr, Finbuckle.MultiTenant, ASP.NET Core Identity, OpenTelemetry .NET, Dapper, Ardalis.Specification, NIST SP 800-63B-4, and OWASP ASVS 5.0 / Top 10:2025.

### BSE Internal
- **Stud2 / SafePack2 / Orange2** — legacy .NET Framework 4.6.1 line-of-business systems being modernized onto this framework.
- **`BSE.Common`** — shared security library providing the vetted JWT/opaque token, validation, and web-hardening implementations that the `Auth.Jwt`, `Validation`, and `Web` packages adapt.
