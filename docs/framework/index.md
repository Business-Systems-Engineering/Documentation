# Bse.Framework Design Documentation

This directory contains the architectural design documentation for **Bse.Framework**, a modular .NET 8/9 framework for building distributed multi-tenant web APIs and microservices, replacing the duplicated patterns across Stud2, SafePack2, and Orange2.

## Documentation Structure

| Type | Purpose |
|---|---|
| **ADR** (Architecture Decision Record) | Captures a single decision with context, options considered, and rationale |
| **RFC** (Request for Comments) | Detailed design for a subsystem |

## Quick Navigation

### Start Here
- [RFC-0001: Framework Overview](rfc/0001-framework-overview.md) — High-level architecture and package list

### Architecture Decisions (ADRs)

| # | Title | Status |
|---|---|---|
| [0001](adr/0001-modular-package-architecture.md) | Modular NuGet Package Architecture | Accepted |
| [0002](adr/0002-json-rpc-over-redis-streams.md) | JSON-RPC 2.0 Over Multiple Transports | Accepted |
| [0003](adr/0003-ef-core-plus-dapper-hybrid.md) | EF Core + Dapper Hybrid (CQRS Split) | Accepted |
| [0004](adr/0004-hybrid-auth-jwt-plus-opaque.md) | Hybrid Authentication (JWT + Opaque Tokens) | Accepted |
| [0005](adr/0005-opentelemetry-grafana-stack.md) | OpenTelemetry → Grafana Stack | Accepted |
| [0006](adr/0006-hybrid-multi-tenancy.md) | Hybrid Multi-Tenancy with RLS | Accepted |
| [0007](adr/0007-calendar-provider-abstraction.md) | Pluggable ICalendarProvider | Accepted |
| [0008](adr/0008-source-generator-automation.md) | Roslyn Source Generator Automation | Accepted |
| [0009](adr/0009-transport-abstraction-pattern.md) | Transport Abstraction with ISP | Accepted |

### Subsystem Designs (RFCs)

| # | Title | Status |
|---|---|---|
| [0001](rfc/0001-framework-overview.md) | Framework Overview | Approved |
| [0002](rfc/0002-rpc-distributed-computing.md) | RPC and Distributed Computing | Approved |
| [0003](rfc/0003-data-access-layer.md) | Data Access Layer | Approved |
| [0004](rfc/0004-auth-and-security.md) | Authentication, Authorization, and Security | Approved |
| [0005](rfc/0005-telemetry-and-observability.md) | Telemetry and Observability | Approved |
| [0006](rfc/0006-multi-tenancy.md) | Multi-Tenancy | Approved |
| [0007](rfc/0007-localization.md) | Localization | Approved |

## Framework at a Glance

### What It Replaces

The framework consolidates patterns currently duplicated across three BSE applications:

| Concern | Stud2 | SafePack2 | Orange2 | Framework |
|---|---|---|---|---|
| Framework | .NET FW 4.6.1 | .NET FW 4.6.1 | .NET FW 4.6.1 | .NET 8/9 |
| API | Web API 5.2.7 | Web API 5.2.7 | Web API 5.2.7 | ASP.NET Core |
| ORM | EF6 DB-First | EF6 DB-First | EF6 DB-First | EF Core + Dapper |
| DI | Unity 5.9.3 | Unity 5.9.3 | Unity 5.9.3 | Microsoft.Extensions.DependencyInjection |
| Auth | DES tokens | DES tokens | DES tokens | OpenIddict + Identity.Core |
| Logging | DB only | Prometheus only | None | OpenTelemetry → Grafana stack |
| Pagination | None | OFFSET/FETCH | ROW_NUMBER() | Offset + Keyset (auto via attributes) |

### 16 Packages

```
Bse.Framework.Core                            ← DI, config, logging, base types
Bse.Framework.MultiTenancy                    ← Tenant resolution, ITenantContext
Bse.Framework.Rpc                             ← JSON-RPC 2.0 protocol + abstractions
Bse.Framework.Rpc.RedisStreams                ← Redis Streams transport
Bse.Framework.Rpc.Http                        ← HTTP transport
Bse.Framework.Data                            ← Repository + query abstractions
Bse.Framework.Data.EntityFramework            ← EF Core implementation
Bse.Framework.Data.Dapper                     ← Dapper.AOT implementation
Bse.Framework.Auth                            ← Auth abstractions
Bse.Framework.Auth.Jwt                        ← OpenIddict-based auth
Bse.Framework.Telemetry                       ← OpenTelemetry config
Bse.Framework.Localization                    ← ICalendarProvider abstraction
Bse.Framework.Localization.Hijri              ← Hijri calendar plugin
Bse.Framework.SourceGenerators                ← Roslyn analyzers
Bse.Framework.SourceGenerators.Attributes     ← Marker attributes
Bse.Framework.Testing                         ← Test fixtures + helpers
```

### Key Design Principles

1. **Modular** — Pick only the packages you need
2. **Abstractions vs Implementations** — Microsoft.Extensions.* pattern
3. **Source Generators Over Reflection** — Compile-time, no runtime overhead
4. **Defense in Depth** — Multi-tenant isolation in 4 layers
5. **Industry Standards** — OAuth2/OIDC, OpenTelemetry, NIST 800-63B-4, OWASP ASVS 5.0
6. **Migration-Friendly** — Adopt one package at a time
7. **Docker-First** — Containerized deployment is the default

### Critical Design Decisions

These are the highest-impact decisions made during the design process:

1. **JSON-RPC 2.0 over multiple transports** instead of gRPC — protocol consistency, ecosystem familiarity
2. **EF Core + Dapper CQRS split** instead of single ORM — matches existing patterns, eliminates SQL injection
3. **Source generators** instead of reflection — eliminates 240+ manual registrations, compile-time safety
4. **OpenIddict** instead of custom auth — OAuth2/OIDC compliance for free
5. **PostgreSQL Row-Level Security** as 4th tenant isolation layer — closes the Dapper-bypasses-EF-filters gap
6. **Per-tenant Options pattern** (Finbuckle-style) — any IOptions<T> becomes tenant-aware
7. **Two-tier OpenTelemetry Collector** for tail sampling — single collector silently drops fragmented traces

## Documentation Conventions

### ADRs

Each ADR documents:
- **Context** — What is the issue?
- **Decision** — What did we decide?
- **Options Considered** — What alternatives did we evaluate?
- **Rationale** — Why did we choose this?
- **Consequences** — Positive, negative, neutral impacts
- **References** — Related documents and external links

### RFCs

Each RFC documents:
- **Abstract** — One-paragraph summary
- **Motivation** — Why we're doing this, current state, problems
- **Goals / Non-Goals** — What we will and won't address
- **Design** — Detailed component and interface design
- **Migration Path** — How existing code/systems migrate
- **Configuration** — How users configure the subsystem
- **Performance / Security / Observability / Testing** — Cross-cutting concerns
- **References** — Related documents and external links

## Implementation Status

The framework is currently in **design phase**. All ADRs and RFCs have been approved. The next step is to invoke the writing-plans skill to create a step-by-step implementation plan.

## Review Process

Each RFC underwent industry best-practices review against:
- ABP Framework
- MassTransit
- Wolverine
- Rebus
- NServiceBus
- Dapr
- Finbuckle.MultiTenant
- Microsoft.AspNetCore.Identity.Core
- OpenIddict
- OpenTelemetry .NET SDK
- Dapper.AOT
- Ardalis.Specification
- AWS/Azure SaaS architecture guidance
- NIST SP 800-63B-4
- OWASP ASVS 5.0
- OWASP Top 10:2025

## Contributing

When updating the design:
1. ADRs are immutable once accepted. Create a new ADR that supersedes the old one.
2. RFCs can be updated for clarification. Substantial changes warrant a new RFC.
3. Use the templates in `adr/template.md` and `rfc/template.md`.
4. Cross-link related ADRs and RFCs.

## References to Source Material

The framework design draws on these existing systems:

### BSE Internal
- **Stud2** — University management system (.NET FW 4.6.1)
- **SafePack2** — Inventory/ERP system (.NET FW 4.6.1)
- **Orange2** — Accounting/ERP system (.NET FW 4.6.1)
- **notifyd** — Go notification service (existing reference)
