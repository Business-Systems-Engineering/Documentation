# ADR-0008: Roslyn Source Generators for Repository and Query Automation

- **Status:** Accepted
- **Date:** 2026-04-06
- **Tags:** source-generators, automation, boilerplate-elimination

## Context

The existing BSE apps require massive amounts of boilerplate:
- **240+ manual service registrations** in `IocConfigurator.cs` (SafePack2)
- **40-90 hand-written repository implementations** per app
- **100+ hand-written `[Query("SQL")]` methods** with parameter binding
- **Manual SQL parameterization** (frequently forgotten → SQL injection)
- **Manual pagination wrapping** (inconsistent across apps)

We need automation that eliminates this boilerplate without runtime reflection overhead and with compile-time safety.

## Decision

Use **Roslyn Source Generators** to automatically generate:
1. **EF Core repositories** for entities marked with `IEntity`
2. **Dapper query implementations** from `[Query]`-attributed interfaces
3. **DI registrations** for all generated repositories and query services
4. **Pagination wrapping** via `[Paginated]` and `[KeysetPaginated]` attributes
5. **Strongly-typed ID** value converters and Dapper type handlers

## Options Considered

### Option A: Runtime Reflection
- **Pros:** Simpler to implement, no build-time complexity
- **Cons:** Runtime overhead, no AOT support, harder to debug, runtime errors instead of compile errors

### Option B: Code Templates / Scaffolding (T4)
- **Pros:** Visible generated code, easy to customize
- **Cons:** Generated code drifts from templates, framework updates require re-scaffolding, doesn't compose with DI

### Option C: Roslyn Source Generators
- **Pros:** Compile-time generation (no runtime overhead), AOT-compatible, errors caught at build time, auto-regenerates on framework updates, IDE integration (IntelliSense), eliminates entire categories of bugs (SQL injection, missing registrations)
- **Cons:** Build-time complexity, generators must target netstandard2.0, debugging generated code requires special tooling, build performance impact if not incremental

## Rationale

Source generators are the modern .NET pattern (Microsoft uses them in System.Text.Json, regex, logging, etc.). They give us the automation of templates without the drift problem. Compile-time enforcement of parameterization makes SQL injection impossible by construction. Build-time DI registration eliminates the 240+ manual registration problem.

The framework will build on **Dapper.AOT** (by Marc Gravell, the Dapper author) for the query side rather than reinventing parameter binding and type mapping.

## Consequences

### Positive
- Eliminates 240+ manual service registrations
- Eliminates 40-90 hand-written repositories per app
- SQL injection impossible by construction (compile error on string concatenation)
- Pagination consistent across the framework via attributes
- Strongly-typed IDs work seamlessly across EF Core, Dapper, JSON
- AOT-compatible
- Compile-time errors instead of runtime surprises

### Negative
- Source generators must target `netstandard2.0` (compiler runs on .NET Framework on Windows)
- Generators must be incremental (`IIncrementalGenerator`) for IDE performance
- Generated code is harder to debug
- Build performance impact must be monitored
- Cross-version compatibility between generator and runtime requires careful versioning

### Neutral
- Generators ship in two packages: `Bse.Framework.SourceGenerators` (analyzer) + `Bse.Framework.SourceGenerators.Attributes` (runtime)
- Generated files use `.g.cs` extension with `#line` directives for debugging
- All generators coordinate via shared `Directory.Build.props` version

## Source Generator Targets

| Generator | Input | Output |
|---|---|---|
| `RepositoryGenerator` | Classes implementing `IEntity` | `EfRepository<T>` + DI registration |
| `QueryGenerator` | Interfaces with `[DapperQueries]` | Dapper.AOT-based implementation + DI registration |
| `PaginationGenerator` | Methods with `[Paginated]` | OFFSET/FETCH-wrapped SQL |
| `KeysetPaginationGenerator` | Methods with `[KeysetPaginated]` | Cursor-based SQL |
| `StronglyTypedIdGenerator` | Records with `[StronglyTypedId]` | EF ValueConverter + Dapper TypeHandler + JSON converter |
| `RemoteServiceProxyGenerator` | Interfaces with `[RemoteService]` | RPC client implementation |
| `RpcMethodRegistrationGenerator` | Methods with `[RpcMethod]` | Dispatcher registration table |

## Analyzer Rules (Compile-Time Enforcement)

| Rule | Severity | Detects |
|---|---|---|
| `BSE0001` | Error | String concatenation in `[Query("...")]` SQL |
| `BSE0002` | Error | `[DapperQueries]` method returning `IEntity` type |
| `BSE0003` | Error | Direct `IDistributedCache` injection in tenant-scoped service |
| `BSE0004` | Error | `IgnoreQueryFilters()` call outside `BseUnfilteredDbContext` |
| `BSE0005` | Warning | `[RpcMethod]` without `[RequirePermission]` (security review needed) |
| `BSE0006` | Error | High-cardinality label on metric (user_id, tenant_id without Mimir) |

## References

- ADR-0003: EF Core + Dapper Hybrid
- RFC-0003: Data Access Layer
- Dapper.AOT: https://aot.dapperlib.dev/
- StronglyTypedId by Andrew Lock
- Roslyn Source Generators documentation
