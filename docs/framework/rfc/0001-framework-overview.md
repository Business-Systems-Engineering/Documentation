# RFC-0001: Bse.Framework Overview

- **Status:** Approved
- **Date:** 2026-04-06
- **Related ADRs:** ADR-0001, ADR-0002, ADR-0003, ADR-0004, ADR-0005, ADR-0006, ADR-0007, ADR-0008, ADR-0009

## Abstract

`Bse.Framework` is a modular .NET 8/9 framework for building distributed multi-tenant web APIs and microservices. It eliminates code duplication across BSE applications (Stud2, SafePack2, Orange2) by providing a set of focused NuGet packages covering RPC/messaging, data access, authentication/authorization, observability, multi-tenancy, and localization. The framework targets Docker deployment, supports both greenfield projects and gradual migration of legacy applications, and follows industry best practices verified against ABP Framework, MassTransit, OpenIddict, ASP.NET Core Identity, OpenTelemetry, and AWS/Azure SaaS architecture guidance.

## Motivation

### Current State

Three BSE applications duplicate massive amounts of code:

| Concern | Stud2 | SafePack2 | Orange2 |
|---|---|---|---|
| Framework | .NET Framework 4.6.1 | .NET Framework 4.6.1 | .NET Framework 4.6.1 |
| API | Web API 5.2.7 | Web API 5.2.7 | Web API 5.2.7 |
| ORM | EF6 Database-First | EF6 Database-First | EF6 Database-First |
| DI | Unity 5.9.3 | Unity 5.9.3 | Unity 5.9.3 |
| Auth | Custom DES token | Custom DES token | Custom DES token |
| Controllers | ~40 | ~88 | ~50 |
| Services | ~40 | ~240 | ~65 |
| Entities | ~110 | ~449 | ~100+ |
| Pagination | None | OFFSET/FETCH | ROW_NUMBER() |
| Logging | DB audit only | Prometheus | None |

### Problems

1. **Massive duplication:** `BaseController`, `BaseResponse`, `GenericRepository`, `UnitOfWork`, `SecuritySystem`, `Tools`, `Shared`, `IocConfigurator`, `APIResolver` — copied across all three apps with subtle drift
2. **SQL injection vulnerabilities:** Raw SQL with string concatenation throughout (`db.Database.SqlQuery<T>("... where x = " + input)`)
3. **Broken cryptography:** DES encryption with hardcoded key `"Business-Systems"` for token generation
4. **Plain text passwords:** Stored in `G_USERS.Password` column
5. **No structured logging:** Stud2 and Orange2 have no logging framework at all
6. **No distributed tracing:** Cannot debug across service boundaries
7. **No async/await:** Everything is synchronous
8. **Minimal validation:** Only `ModelState.IsValid` checks
9. **No rate limiting:** Vulnerable to brute force and abuse
10. **No multi-tenant isolation enforcement:** Manual `WHERE CompCode = @c` clauses, easy to forget

### Goals

The framework eliminates these problems by providing a unified, secure, observable, and tested foundation that:

1. Removes code duplication via shared NuGet packages
2. Makes SQL injection impossible by construction
3. Replaces broken cryptography with industry standards (Argon2id, OpenIddict, JWT with key rotation)
4. Provides structured logging, distributed tracing, and metrics out of the box
5. Enforces multi-tenant isolation at four layers (filter, interceptor, analyzer, RLS)
6. Supports both greenfield and migration scenarios
7. Follows industry best practices verified by external review

## Goals

- **Eliminate code duplication** across BSE applications
- **Migration path** for Stud2/SafePack2/Orange2 (gradual, not big-bang)
- **Distributed computing** support (RPC, events, background jobs, horizontal scaling)
- **Security best practices** (Argon2id, MFA, OAuth2/OIDC, RBAC, audit logging)
- **OpenTelemetry observability** (traces, metrics, logs unified in Grafana stack)
- **Multi-tenancy** with hybrid isolation strategies
- **Source generator automation** (zero manual repository registration)
- **Docker-first deployment** matching team preferences
- **Test-friendly** (Testcontainers, in-memory transport, builder patterns)

## Non-Goals

- Replacing the existing apps in a big-bang rewrite
- Supporting non-.NET clients via gRPC code generation (JSON-RPC 2.0 over HTTP works)
- Providing a UI framework (the React `bse-brilliance-suite` covers that)
- Replacing the `notifyd` Go service (the framework integrates with it for notifications)

## Design

### Package Architecture

The framework consists of 16 packages organized into layers:

```
┌─────────────────────────────────────────────────────────────┐
│                      Application Layer                       │
│           (SafePack3, Stud3, Orange3 services)               │
└──────┬──────────────────────────────────────────┬────────────┘
       │                                          │
┌──────▼──────────────────────┐  ┌────────────────▼────────────┐
│SourceGenerators (compile)    │  │ Localization.Hijri (optional)│
│ + Attributes (runtime)       │  │ Testing (test-time only)     │
└──────┬──────────────────────┘  └────────────────┬────────────┘
       │                                          │
┌──────▼──────────────────────────────────────────▼────────────┐
│                  Implementation Packages                      │
│                                                               │
│  Rpc.RedisStreams    Data.EntityFramework    Auth.Jwt        │
│  Rpc.Http            Data.Dapper                              │
└──────┬──────────────────────────────────────────┬────────────┘
       │                                          │
┌──────▼──────────────────────────────────────────▼────────────┐
│                  Abstraction Packages                         │
│                                                               │
│  Rpc (protocol + interfaces)    Data (IRepository, IQuery)   │
│  Auth (ICurrentUser, RBAC)      Localization (ICalendar)     │
│  Telemetry (OTel config)        MultiTenancy (ITenantContext)│
└──────────────────────────┬───────────────────────────────────┘
                           │
                ┌──────────▼──────────┐
                │  Bse.Framework.Core │
                │  DI, config, logging│
                │  base types, health │
                │  error handling     │
                └─────────────────────┘
```

### Package List

| # | Package | Purpose |
|---|---|---|
| 1 | `Bse.Framework.Core` | DI helpers, configuration, logging, base types, exception handling, health check aggregation, graceful shutdown |
| 2 | `Bse.Framework.MultiTenancy` | Tenant resolution, ITenantContext, per-tenant configuration |
| 3 | `Bse.Framework.Rpc` | JSON-RPC 2.0 protocol, transport abstractions, client/server interfaces |
| 4 | `Bse.Framework.Rpc.RedisStreams` | Redis Streams transport implementation |
| 5 | `Bse.Framework.Rpc.Http` | HTTP transport implementation |
| 6 | `Bse.Framework.Data` | Repository and query abstractions, pagination types |
| 7 | `Bse.Framework.Data.EntityFramework` | EF Core repository implementation |
| 8 | `Bse.Framework.Data.Dapper` | Dapper query implementation (Dapper.AOT-based) |
| 9 | `Bse.Framework.Auth` | Auth abstractions (ICurrentUser, IPermissionChecker, RBAC) |
| 10 | `Bse.Framework.Auth.Jwt` | OpenIddict-based JWT + opaque token authentication |
| 11 | `Bse.Framework.Telemetry` | OpenTelemetry configuration, OTLP exporter setup |
| 12 | `Bse.Framework.Localization` | ICalendarProvider, base localization abstractions |
| 13 | `Bse.Framework.Localization.Hijri` | Hijri calendar implementation |
| 14 | `Bse.Framework.SourceGenerators` | Roslyn generators (netstandard2.0, analyzer package) |
| 15 | `Bse.Framework.SourceGenerators.Attributes` | Marker attributes for generators (runtime dependency) |
| 16 | `Bse.Framework.Testing` | Test fixtures, in-memory transports, fake tenant contexts |

### Solution Structure

```
bse-framework/
├── src/
│   ├── Bse.Framework.Core/
│   ├── Bse.Framework.MultiTenancy/
│   ├── Bse.Framework.Rpc/
│   ├── Bse.Framework.Rpc.RedisStreams/
│   ├── Bse.Framework.Rpc.Http/
│   ├── Bse.Framework.Data/
│   ├── Bse.Framework.Data.EntityFramework/
│   ├── Bse.Framework.Data.Dapper/
│   ├── Bse.Framework.Auth/
│   ├── Bse.Framework.Auth.Jwt/
│   ├── Bse.Framework.Telemetry/
│   ├── Bse.Framework.Localization/
│   ├── Bse.Framework.Localization.Hijri/
│   ├── Bse.Framework.SourceGenerators/
│   └── Bse.Framework.SourceGenerators.Attributes/
├── tests/
│   ├── Bse.Framework.Core.Tests/
│   ├── Bse.Framework.Rpc.Tests/
│   ├── Bse.Framework.Data.Tests/
│   ├── Bse.Framework.Auth.Tests/
│   ├── Bse.Framework.Integration.Tests/
│   └── Bse.Framework.Testing/          ← shared test utilities package
├── samples/
│   ├── Bse.Samples.SimpleApi/
│   ├── Bse.Samples.DistributedServices/
│   └── Bse.Samples.Migration/
├── docker/
│   ├── docker-compose.yml
│   ├── docker-compose.observability.yml
│   └── otel-collector-config.yaml
└── docs/
    ├── adr/
    └── rfc/
```

### Subsystem RFCs

Each major subsystem has its own RFC:

- **RFC-0002:** RPC and Distributed Computing
- **RFC-0003:** Data Access Layer
- **RFC-0004:** Authentication, Authorization, and Security
- **RFC-0005:** Telemetry and Observability
- **RFC-0006:** Multi-Tenancy
- **RFC-0007:** Localization

## Migration Path

The framework supports incremental migration from existing BSE apps:

### Phase 1: Foundation (Months 1-3)
- Build framework packages with comprehensive tests
- Build sample applications demonstrating usage
- Set up CI/CD with package publishing

### Phase 2: Pilot (Months 4-6)
- New BSE applications use the framework from day one
- One existing app (smallest, e.g., Stud2) begins migration
- Auth package replaces DES tokens first (highest security ROI)

### Phase 3: Migration (Months 7-12)
- Stud2 fully migrated, validates patterns
- SafePack2 and Orange2 begin migration
- Legacy apps' BLL services gradually replaced with framework patterns
- EDMX entities replaced via `dotnet ef dbcontext scaffold`

### Phase 4: Consolidation (Year 2)
- All BSE apps on the framework
- Shared services (notifications, identity, file storage) extracted
- Distributed computing patterns enabled (cross-app RPC)

## References

- All ADRs (0001-0009)
- All RFCs (0002-0007)
- Existing apps: Stud2, SafePack2, Orange2
