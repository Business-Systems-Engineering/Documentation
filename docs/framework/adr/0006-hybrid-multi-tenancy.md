# ADR-0006: Ambient Tenant Context + EF Query-Filter Isolation

- **Status:** Accepted
- **Date:** 2026-04-06
- **Deciders:** BSE Framework Team
- **Tags:** multi-tenancy, isolation, ef-core, security

## Context

The existing BSE apps thread `CompCode` and `BranchCode` through every method signature, with
year-based database routing built into `BaseController.BuildConnectionString()`. Tenant isolation
is enforced manually via `WHERE CompCode = @CompCode` clauses — easy to forget and easy to bypass.
Dapper queries in particular have no enforcement layer at all.

The framework needed a tenant model that:

- Makes tenant identity ambient (no parameter threading).
- Propagates automatically across HTTP requests, RPC envelope hops, and background jobs.
- Enforces isolation at the persistence layer without requiring every query to carry a filter.
- Guards against cross-tenant writes even when query filters are bypassed.

## Decision

Tenants are a `string?` slug carried in an **ambient `ITenantContext`** backed by `AsyncLocal<T>`,
resolved per HTTP request (header / host / JWT claim) or per RPC message (envelope `TenantId`),
and accessed via `ITenantContextAccessor`. Isolation is enforced by two layers in `BseDbContext`:

1. **EF global query filter** (`MultiTenantQueryFilterConvention`): applies
   `e.TenantId == accessor.Current.TenantId` to every `IMultiTenant` entity at model-build time.
   The filter captures the accessor reference — not the tenant value — so each query evaluates the
   tenant that is current at execution time. When the current tenant is `null` (anonymous context),
   the filter becomes `TenantId == null`, which returns zero rows because no production row has a
   null `TenantId`.

2. **Cross-tenant-write guard** (`AuditingSaveChangesInterceptor`): at `SavingChanges`, every
   modified `IMultiTenant` entity whose `TenantId` does not match the current context throws a
   `BseAuthorizationException`. This fires even when query filters were bypassed via
   `IgnoreQueryFilters()` or a tracked entity leaked from a prior DI scope.

RPC propagation is handled by `TenantRpcEnvelopeScope` (`Bse.Framework.MultiTenancy.Rpc`), which
reads `TransportMessage.TenantId` from the inbound envelope and calls `accessor.Push(context)`
before the dispatcher routes to the handler.

```csharp
// AsyncLocal ambient store — propagates through async continuations
public sealed class AsyncLocalTenantContextAccessor : ITenantContextAccessor
{
    private static readonly AsyncLocal<ITenantContext?> _current = new();

    public ITenantContext Current => _current.Value ?? TenantContext.Empty;

    public IDisposable Push(ITenantContext context)
    {
        var previous = _current.Value;
        _current.Value = context;
        return new RestoreScope(previous);
    }
}

// EF global query filter — re-evaluated per query, not at model-build time
// (excerpt from MultiTenantQueryFilterConvention)
modelBuilder.Entity(entityType.ClrType)
    .HasQueryFilter(e => EF.Property<string>(e, "TenantId") == accessor.Current.TenantId);
```

HTTP resolvers registered in `Bse.Framework.MultiTenancy.AspNetCore`:
- `HeaderTenantResolver` — reads a configured request header.
- `HostTenantResolver` — extracts tenant from the `Host` value.
- `ClaimTenantResolver` — reads a claim from the authenticated JWT principal.

The `TenantResolverChain` walks registered resolvers in DI order and returns the first non-null
result; if all resolvers miss, `TenantContext.Empty` is returned and enforcement is the
middleware's responsibility.

This design is **NOT** physical database-per-tenant, **NOT** schema-per-tenant, and **NOT**
Finbuckle-style per-tenant `DbContextOptions` switching. It is shared-database with ambient
context and EF query-filter enforcement.

## Options Considered

### Option A: Database-per-tenant
- **Pros:** Strongest isolation; easiest migration of existing data; simple mental model.
- **Cons:** Connection pool exhaustion at scale (~50 tenants per host); expensive for small
  tenants; hard to operate at hundreds of tenants.

### Option B: Schema-per-tenant
- **Pros:** Single connection pool; moderate isolation; simpler ops than per-database.
- **Cons:** PostgreSQL-specific; schema migrations are complex; weaker isolation than per-DB.

### Option C: Shared database + ambient context + EF query filter (chosen)
- **Pros:** Scales to many tenants with a single pool; isolation is automatic for EF queries;
  cross-tenant write guard provides defense in depth; tenant flows through async continuations
  without parameter threading; works uniformly across HTTP and RPC.
- **Cons:** Dapper queries bypass EF filters — callers must add `WHERE TenantId = @tid` manually
  or rely on PostgreSQL RLS; weaker physical isolation than per-DB options.

## Rationale

The BSE deployment target is a small-to-medium number of tenants per host sharing a PostgreSQL
instance. Physical isolation at the database or schema level would require PgBouncer or dedicated
instances at any meaningful scale. The ambient-context + query-filter model enforces isolation
automatically for all EF Core queries and audits every write path. The cross-tenant write guard
in the interceptor closes the gap left by `IgnoreQueryFilters()` abuse. For the Dapper read path,
callers add explicit `WHERE TenantId = @tid` because `IReadRepository` intentionally accepts raw
SQL — PostgreSQL RLS can serve as an additional backstop.

## Consequences

### Positive
- Tenant identity is ambient: no parameter threading through service and handler signatures.
- `AsyncLocal` propagation flows through `Task.Run`, `await`, and DI scopes automatically.
- EF query filter is applied globally with zero per-query boilerplate.
- Cross-tenant write guard (`AuditingSaveChangesInterceptor`) provides defense in depth
  independently of query filters.
- RPC tenant propagation via `TenantRpcEnvelopeScope` is transparent to handler authors.
- Resolvers (header, host, claim) are composable via the `TenantResolverChain`.

### Negative
- Dapper queries bypass EF query filters — tenant filter must be added manually to raw SQL.
- Anonymous contexts (`TenantContext.Empty`) see zero rows for `IMultiTenant` entities, which can
  surprise developers who omit resolver configuration in tests.
- Cross-tenant insert without a current tenant throws `BseValidationException` at `SaveChanges`
  time, not at handler entry — validation happens later than ideal.

### Neutral
- `ITenantContext.TenantId` is `string?`; null represents an anonymous or system-level context.
- The resolver chain falls back to `TenantContext.Empty` when no resolver matches, allowing
  unauthenticated / public endpoints to work without special-casing.
- `IMultiTenant` (marker interface) lives in `Bse.Framework.Data`; the query filter and
  interceptor live in `Bse.Framework.Data.EntityFramework`.

## References

- RFC-0006: Multi-Tenancy
- ADR-0003: EF Core + Dapper Hybrid
- [`Bse.Framework.MultiTenancy/Accessor/AsyncLocalTenantContextAccessor.cs`]
- [`Bse.Framework.Data.EntityFramework/Conventions/MultiTenantQueryFilterConvention.cs`]
- [`Bse.Framework.Data.EntityFramework/Interceptors/AuditingSaveChangesInterceptor.cs`]
- [`Bse.Framework.MultiTenancy.Rpc/TenantRpcEnvelopeScope.cs`]
