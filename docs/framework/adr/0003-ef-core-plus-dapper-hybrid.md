# ADR-0003: EF Core + Dapper Hybrid (CQRS Split)

- **Status:** Accepted
- **Date:** 2026-04-06
- **Deciders:** BSE Framework Team
- **Tags:** data, orm, cqrs, ef-core, dapper

## Context

The existing BSE apps (Stud2, SafePack2, Orange2) use Entity Framework 6 Database-First with
EDMX models, generic repositories, and a UnitOfWork pattern. They also extensively use raw SQL
via `db.Database.SqlQuery<T>(rawSql)` with string concatenation — creating SQL injection
vulnerabilities throughout. Pagination is inconsistent (none in Stud2, OFFSET/FETCH in SafePack2,
ROW_NUMBER() in Orange2). We need a single data-access strategy that handles both simple CRUD and
complex reporting queries while eliminating SQL injection risks.

The framework needed two complementary capabilities:

- A write path with automatic change tracking, auditing, soft-delete, tenant stamping, and
  optimistic concurrency via the Postgres `xmin` system column (`IConcurrencyAware`).
- A read path with full SQL control and no ORM translation overhead for complex joins, window
  functions, and reporting queries.

## Decision

Adopt a **CQRS-style split**: **EF Core owns the write model** (change tracking,
`AuditingSaveChangesInterceptor`, `MultiTenantQueryFilterConvention` global query filter, Postgres
`xmin` concurrency via `IConcurrencyAware`) and **plain Dapper owns the read path** via
`IReadRepository` raw-SQL methods (`QueryAsync`, `QuerySingleOrDefaultAsync`, `QueryPageAsync`,
`ExecuteScalarAsync`). The Dapper package references `Dapper` directly — not Dapper.AOT — keeping
the runtime dependency minimal.

```csharp
// Write side — EF Core with full interceptor stack
public abstract class BseDbContext : DbContext
{
    protected override void OnConfiguring(DbContextOptionsBuilder optionsBuilder)
        => optionsBuilder.AddInterceptors(
            new AuditingSaveChangesInterceptor(_clock, _tenantAccessor, _userAccessor));

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        SoftDeleteQueryFilterConvention.Apply(modelBuilder);
        if (_tenantAccessor is not null)
            MultiTenantQueryFilterConvention.Apply(modelBuilder, _tenantAccessor);
    }
}

// Read side — plain Dapper, IReadRepository
public interface IReadRepository
{
    Task<IReadOnlyList<T>> QueryAsync<T>(string sql, object? parameters = null,
        CancellationToken cancellationToken = default);
    Task<T?> QuerySingleOrDefaultAsync<T>(string sql, object? parameters = null,
        CancellationToken cancellationToken = default);
    Task<PagedResult<T>> QueryPageAsync<T>(string sql, string countSql,
        int page, int pageSize, object? parameters = null,
        CancellationToken cancellationToken = default);
}
```

`IReadRepository` intentionally accepts raw SQL strings rather than `Specification<T>` objects.
Specifications build `IQueryable` expression trees targeting EF Core's LINQ provider; the Dapper
read side uses hand-written SQL for full control over query shape and index usage.

## Options Considered

### Option A: EF Core Only
- **Pros:** Single ORM, built-in migrations, change tracking, lazy/eager loading, scaffold from
  existing databases.
- **Cons:** Complex reporting queries are painful in LINQ; generated SQL can be suboptimal; team
  already writes raw SQL (fighting the grain); N+1 traps without careful Include discipline.

### Option B: Dapper Only
- **Pros:** Full SQL control, fastest raw performance, closest to current raw SQL approach, simple
  mental model.
- **Cons:** No automatic migrations, no change tracking, every CRUD needs hand-written SQL,
  repetitive boilerplate, no relationship navigation.

### Option C: EF Core Write + Dapper Read Hybrid (chosen)
- **Pros:** EF Core for CRUD with change tracking and auditing; Dapper for complex queries with
  full SQL control; matches existing developer reality; parameterized queries enforced in both;
  best performance profile; natural CQRS split.
- **Cons:** Two data-access patterns to maintain; need clear usage guidelines; slight cognitive
  overhead.

## Rationale

The existing BSE apps already do this informally — simple CRUD through generic repositories,
complex reads through raw SQL. The framework formalizes the split with clear boundaries. EF Core
handles the write side with automatic auditing, tenant stamping, soft-delete rewrite, and
optimistic concurrency. The `AuditingSaveChangesInterceptor` guards against cross-tenant writes by
throwing `BseAuthorizationException` when a modified `IMultiTenant` entity's `TenantId` does not
match the current context — defense in depth that operates independently of query filters.

Dapper's read side keeps SQL transparent and index-friendly. The `{OFFSET}/{LIMIT}` placeholder
convention in `QueryPageAsync` is the only structural constraint; all other SQL is caller-authored.

## Consequences

### Positive
- Matches existing developer mental model (simple CRUD vs. complex reads).
- Eliminates SQL injection by construction — `IReadRepository` accepts only parameterized calls.
- EF auditing interceptor stamps `CreatedAt`, `CreatedBy`, `ModifiedAt`, `ModifiedBy`, and tenant
  automatically on every `SaveChanges`.
- Postgres `xmin` concurrency conflicts surface as `BseConcurrencyException` before the caller
  sees stale data.
- Read-replica routing is natural: Dapper connects via read-only `IDbConnectionFactory`, EF
  connects to the primary.
- CQRS split enables separate scaling of read and write paths.

### Negative
- Two data-access patterns to learn; clear guidelines are mandatory.
- Read models must be separate types from write entities (enforced at discipline level, not compile
  time).
- Strongly-typed IDs need dual registration: EF ValueConverter for the write side, Dapper
  TypeHandler for the read side.

### Neutral
- Dapper bypasses EF Core query filters entirely — callers must add `WHERE TenantId = @tid`
  manually on the read path or rely on PostgreSQL RLS as a backstop.
- The write package is `Bse.Framework.Data.EntityFramework`; the read package is
  `Bse.Framework.Data.Dapper`. Services consume whichever they need.

## References

- RFC-0003: Data Access Layer
- ADR-0010: Flyway for Schema Migrations
- [`Bse.Framework.Data.EntityFramework/Interceptors/AuditingSaveChangesInterceptor.cs`]
- [`Bse.Framework.Data.EntityFramework/Conventions/MultiTenantQueryFilterConvention.cs`]
- [`Bse.Framework.Data.Dapper/IReadRepository.cs`]
