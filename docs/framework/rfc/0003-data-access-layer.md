# RFC-0003: Data Access Layer (EF Core + Dapper)

- **Status:** Implemented
- **Date:** 2026-07-05
- **Authors:** BSE Framework Team
- **Related ADRs:** ADR-0003, ADR-0006, ADR-0010
- **Related RFCs:** RFC-0001, RFC-0006

## Abstract

`Bse.Framework` provides a CQRS-style data access layer distributed across three NuGet packages: `Bse.Framework.Data` (provider-agnostic abstractions), `Bse.Framework.Data.EntityFramework` (EF Core 9 write-side implementation), and `Bse.Framework.Data.Dapper` (Dapper read-side implementation). The design encapsulates `IQueryable` inside a sealed evaluator, enforces multi-tenant and soft-delete filters via composable `SaveChangesInterceptor`s and model conventions, and maps all data-layer exceptions to BSE-domain types. Pagination is offset-only (`PagedRequest`/`PagedResult<T>`); keyset pagination is a tracked open question.

## Motivation

The legacy BSE applications (Stud2, SafePack2, Orange2) share these structural data-access problems:

- **SQL injection** via `db.Database.SqlQuery<T>("... WHERE id = " + input)` string concatenation throughout.
- **Leaky `IQueryable`** exposed through hand-rolled `GenericRepository<T>`, allowing ad-hoc filtering that evades tenant and audit checks.
- **Manual service registration** — 240+ repository registrations in a monolithic DI bootstrapper.
- **Inconsistent pagination** — none in Stud2, `OFFSET/FETCH` in SafePack2, `ROW_NUMBER()` in Orange2.
- **No optimistic concurrency** — lost-update races on concurrent edits go undetected.
- **No audit trail** — `CreatedAt`, `ModifiedAt`, `CreatedBy`, `ModifiedBy` are populated inconsistently or not at all.
- **No soft-delete enforcement** — "deleted" rows are included in results unless every query is hand-filtered.

## Goals

- Encapsulate `IQueryable` so consumers cannot construct ad-hoc LINQ that bypasses global filters.
- Provide composable entity marker interfaces covering identity, auditing, soft-delete, concurrency, and tenancy.
- Enforce multi-tenant isolation and soft-delete filtering automatically via EF Core conventions and interceptors.
- Map EF infrastructure exceptions (`DbUpdateConcurrencyException`) to BSE domain exceptions (`BseConcurrencyException`).
- Provide a Dapper read-side that depends only on `System.Data.IDbConnection` (no EF package coupling).
- Emit OpenTelemetry spans and a query-duration histogram from a single instrumentation interceptor.
- Support opt-in EF Core migrations via a fail-fast hosted service; leave schema management to Flyway or `dotnet ef` by default.

## Non-Goals

- Keyset/cursor pagination — tracked as an open question; only offset pagination ships.
- Source-generated Dapper query interfaces (`[DapperQueries]`, `[Query]` attributes) — not implemented.
- Transactional outbox — depends on `Bse.Framework.Rpc`; not in this layer.
- NoSQL or non-relational providers.
- Cross-database distributed transactions.

## Design

### Overview

The three packages form a strict dependency chain:

```
Bse.Framework.Data
   ↑
Bse.Framework.Data.EntityFramework    Bse.Framework.Data.Dapper
```

`Bse.Framework.Data.Dapper` has **no dependency** on the EF package — it imports only `Bse.Framework.Data` (for `PagedResult<T>`) and the `Dapper` NuGet (plain Dapper, not Dapper.AOT). This separation keeps the read-side lightweight and lets services omit EF entirely for read-only workloads.

### Abstractions — `Bse.Framework.Data`

#### Entity Marker Interfaces

```csharp
// Marker for every persistable entity.
public interface IEntity { }

// Entity with a strongly-typed primary key.
public interface IEntity<out TKey> : IEntity
{
    TKey Id { get; }
}

// Populated automatically by AuditingSaveChangesInterceptor.
// Note: ModifiedAt/ModifiedBy (not UpdatedAt/UpdatedBy).
public interface IAuditable
{
    DateTime  CreatedAt  { get; set; }
    string    CreatedBy  { get; set; }
    DateTime? ModifiedAt { get; set; }
    string?   ModifiedBy { get; set; }
}

// Rows hidden by a global EF filter when IsDeleted == true.
public interface ISoftDelete
{
    bool      IsDeleted { get; set; }
    DateTime? DeletedAt { get; set; }
}

// Postgres xmin optimistic-concurrency token.
// EF maps this with .IsConcurrencyToken(); conflicts become BseConcurrencyException.
public interface IConcurrencyAware
{
    uint Xmin { get; set; }   // Postgres xmin system column (uint, not byte[])
}

// Scoped to a tenant; triggers multi-tenant query filter and interceptor stamping.
public interface IMultiTenant
{
    string TenantId { get; }
}

// Domain events accumulated during the entity lifecycle.
// Dispatch infrastructure (via Bse.Framework.Rpc) ships separately.
public interface IHasDomainEvents
{
    IReadOnlyList<IDomainEvent> DomainEvents { get; }
    void ClearDomainEvents();
}
```

> Prior art: Ardalis.Specification marker convention; ABP Framework `IAuditedObject`/`ISoftDelete`/`IMultiTenant`. The Postgres-specific `uint Xmin` replaces the SQL Server `byte[] RowVersion` token; the field name reflects the Postgres system column directly.

#### Specification Pattern

`Specification<T>` is a **concrete, fluent builder** — not an abstract base class and not the `ISpecification<T>` interface used by Ardalis. Callers construct and configure instances directly; `SpecificationEvaluator` (EF-package-internal) translates them to `IQueryable`. `IQueryable` is never exposed outside that evaluator.

```csharp
public class Specification<T>
{
    // Filter, includes, ordering, hints — all set via fluent methods.
    public Expression<Func<T, bool>>?            Criteria    { get; private set; }
    public IList<Expression<Func<T, object>>>    Includes    { get; }
    public Expression<Func<T, object>>?          OrderBy     { get; private set; }
    public bool    IsDescending  { get; private set; }
    public bool    IsNoTracking  { get; private set; }
    public bool    IsSplitQuery  { get; private set; }
    public string? QueryTag      { get; private set; }
    public int?    Skip          { get; private set; }
    public int?    Take          { get; private set; }

    public Specification<T> Where(Expression<Func<T, bool>> criteria);
    public Specification<T> Include(Expression<Func<T, object>> include);
    public Specification<T> OrderByAscending(Expression<Func<T, object>> orderBy);
    public Specification<T> OrderByDescending(Expression<Func<T, object>> orderBy);
    public Specification<T> AsNoTracking();
    public Specification<T> AsSplitQuery();
    public Specification<T> WithQueryTag(string tag);

    // Offset pagination — page is 1-based. Sets Skip + Take.
    public Specification<T> Page(int page, int pageSize);
}

// Server-side projection: selector runs in the DB (SQL SELECT), entity never materialises.
public class Specification<T, TResult> : Specification<T>
{
    public Specification(Expression<Func<T, TResult>> selector);
    public Expression<Func<T, TResult>> Selector { get; }
}
```

Usage:

```csharp
var spec = new Specification<Invoice>()
    .Where(i => i.TenantId == tenantId && i.Status == InvoiceStatus.Open)
    .Include(i => i.Lines)
    .OrderByDescending(i => i.IssuedAt)
    .AsNoTracking()
    .WithQueryTag(nameof(OpenInvoicesSpec))
    .Page(request.Page, request.PageSize);

var page = await uow.Repository<Invoice>().PageAsync(spec, ct);
```

#### `IRepository<T>`

The repository is specification-driven. `IQueryable<T>` is never part of the public contract.

```csharp
public interface IRepository<T> where T : class, IEntity
{
    // Key lookup — uses FindAsync (checks change tracker first) when tracked=true.
    Task<T?> GetByIdAsync(object id, bool tracked = true,
        CancellationToken cancellationToken = default);

    Task<T?>              FirstOrDefaultAsync(Specification<T> spec,
        CancellationToken cancellationToken = default);
    Task<IReadOnlyList<T>> ListAsync(Specification<T>? spec = null,
        CancellationToken cancellationToken = default);
    Task<IReadOnlyList<TResult>> ListAsync<TResult>(Specification<T, TResult> spec,
        CancellationToken cancellationToken = default);

    // Offset-paginated list. Requires spec.Page(...) to have been called.
    Task<PagedResult<T>> PageAsync(Specification<T> spec,
        CancellationToken cancellationToken = default);

    Task<int>  CountAsync(Specification<T>? spec = null,
        CancellationToken cancellationToken = default);
    Task<bool> AnyAsync(Specification<T> spec,
        CancellationToken cancellationToken = default);

    Task<T>  AddAsync(T entity,
        CancellationToken cancellationToken = default);
    Task     AddRangeAsync(IEnumerable<T> entities,
        CancellationToken cancellationToken = default);
    T        Update(T entity);
    void     Remove(T entity);   // Soft-delete rewrite in interceptor when ISoftDelete
}
```

#### `IUnitOfWork`

```csharp
public interface IUnitOfWork : IAsyncDisposable
{
    // Lazily creates and caches EfRepository<T> per entity type (ConcurrentDictionary).
    IRepository<T> Repository<T>() where T : class, IEntity;

    // Commits all pending changes; returns rows affected.
    Task<int> SaveChangesAsync(CancellationToken cancellationToken = default);
}
```

#### Pagination

The framework ships **offset-only** pagination. Keyset/cursor pagination is a documented open question.

```csharp
// Request — 1-based page.
public sealed record PagedRequest(
    int Page = 1, int PageSize = 20,
    string? SortBy = null, bool Descending = false);

// Response — TotalPages computed as ceil(TotalCount / PageSize).
public sealed record PagedResult<T>(
    IReadOnlyList<T> Items, int TotalCount, int Page, int PageSize)
{
    public int TotalPages => PageSize == 0 ? 0
        : (int)Math.Ceiling((double)TotalCount / PageSize);
}
```

`IRepository<T>.PageAsync` issues two database round-trips: one for the count (criteria only, no Skip/Take) and one for the page (full spec). The total-count query is intentionally a separate query rather than `COUNT(*) OVER()` to keep `SpecificationEvaluator` simple and avoid cartesian-product risk on joined models.

#### Domain Events

```csharp
public interface IDomainEvent
{
    DateTime OccurredAt { get; }   // UTC, set by the entity
}
```

`IHasDomainEvents.DomainEvents` accumulates events during the entity's mutation lifecycle. Dispatch via `SaveChangesInterceptor` is planned and depends on `Bse.Framework.Rpc`; the contract is shipped now so domain models can be written today without revisiting interfaces later.

---

### EF Core Implementation — `Bse.Framework.Data.EntityFramework`

#### `BseDbContext`

The abstract base context wires all framework interceptors and conventions. Subclasses override `OnModelCreating`, must call `base.OnModelCreating(modelBuilder)`, and map their own entities.

Three constructors enable progressive opt-in:

```csharp
public abstract class BseDbContext : DbContext
{
    // No tenant filter, no user-identity stamping.
    protected BseDbContext(DbContextOptions options, ISystemClock clock);

    // Adds IMultiTenant global query filter when tenantAccessor != null.
    protected BseDbContext(DbContextOptions options, ISystemClock clock,
        ITenantContextAccessor? tenantAccessor);

    // Also stamps CreatedBy/ModifiedBy with UserCode ?? UserId when userAccessor != null.
    protected BseDbContext(DbContextOptions options, ISystemClock clock,
        ITenantContextAccessor? tenantAccessor, IBseUserAccessor? userAccessor);
}
```

`OnConfiguring` registers `AuditingSaveChangesInterceptor` (constructed inline with the context's dependencies). `OnModelCreating` applies `SoftDeleteQueryFilterConvention.Apply(modelBuilder)` unconditionally, and `MultiTenantQueryFilterConvention.Apply(modelBuilder, tenantAccessor)` when a tenant accessor is present.

Registration via `AddBseDataEntityFramework<TContext>` also adds `ConcurrencyExceptionMapper` and `DataInstrumentationInterceptor` through the EF options builder — these two are stateless and registered once, while `AuditingSaveChangesInterceptor` is per-context (has request-scoped state).

#### Query Filter Conventions

**`SoftDeleteQueryFilterConvention`** — applied unconditionally to every `ISoftDelete` entity:

```
global filter: e => !((ISoftDelete)e).IsDeleted
```

**`MultiTenantQueryFilterConvention`** — applied when `BseDbContext` is constructed with a non-null `ITenantContextAccessor`:

```
global filter: e => EF.Property<string>(e, "TenantId") == accessor.Current.TenantId
```

The accessor reference is captured in the expression tree, not the tenant value. This means the filter re-evaluates against the actual current tenant at query execution time — important for DI scopes that span multiple tenant contexts (background jobs, admin tooling). When `accessor.Current.TenantId` is `null` (anonymous or system context), the filter becomes `TenantId == null`: because no production row should carry a null `TenantId`, an anonymous context sees zero rows rather than all rows. This is the safe default.

#### `AuditingSaveChangesInterceptor`

Intercepts `SavingChanges` and `SavingChangesAsync` and applies the following mutations to every changed `EntityEntry` before the SQL is sent:

| Entry state | Entity type | Action |
|---|---|---|
| Added | `IAuditable` | Stamp `CreatedAt = now`, `CreatedBy = principal` |
| Modified | `IAuditable` | Stamp `ModifiedAt = now`, `ModifiedBy = principal`; lock `CreatedAt`/`CreatedBy` (`IsModified = false`) |
| Deleted | `ISoftDelete` | Rewrite to `Modified`; set `IsDeleted = true`, `DeletedAt = now` |
| Added | `IMultiTenant` (TenantId empty) | Stamp `TenantId` from `accessor.Current.TenantId`; throw `BseValidationException` if both are null |
| Modified | `IMultiTenant` (TenantId mismatch) | Throw `BseAuthorizationException` — cross-tenant write detected |

Principal resolution: `IBseUserAccessor.Current.UserCode ?? UserId` when authenticated; falls back to `"system"` when `userAccessor` is null or the user is not authenticated.

The cross-tenant check on `Modified` is a defense-in-depth guard: the EF global query filter prevents loading cross-tenant rows in the first place, but a tracked entity from a previous scope or an explicit `IgnoreQueryFilters()` call could bypass the filter. The interceptor catches this and raises `BseAuthorizationException` — not a concurrency conflict, because retrying the same request would produce the same result.

#### `ConcurrencyExceptionMapper`

```csharp
public sealed class ConcurrencyExceptionMapper : SaveChangesInterceptor
{
    // Hooks SaveChangesFailed / SaveChangesFailedAsync.
    // DbUpdateConcurrencyException → BseConcurrencyException(entityType, entityId, innerEx)
}
```

Consumers catch `BseConcurrencyException` without taking a direct EF dependency.

#### `DataInstrumentationInterceptor`

```csharp
public sealed class DataInstrumentationInterceptor : DbCommandInterceptor
{
    public static readonly ActivitySource ActivitySource =
        new("Bse.Data.EntityFramework", "0.1.0");

    // Histogram: seconds, one record per DB command.
    public static readonly Histogram<double> QueryDuration =
        Meter.CreateHistogram<double>(
            "bse.data.query.duration", unit: "s",
            description: "Wall-clock time for a single EF Core DB command.");
}
```

Every reader and non-query command (both sync and async overloads) opens a span tagged `db.system.name=postgresql` and `db.operation.name=Reader|NonQuery`. Command text is **intentionally omitted** from span attributes: SQL text can contain column names or literals that constitute PII, and the cardinality of unique SQL strings would fragment the histogram (see RFC-0005). Wall-clock time is captured via `Stopwatch.GetTimestamp()` / `Stopwatch.GetElapsedTime`, not `DateTime`.

#### `SpecificationEvaluator` (internal)

The only place `IQueryable<T>` is assembled and composed. Never exposed outside the package.

```csharp
internal static class SpecificationEvaluator
{
    // Returns IQueryable<T> from DbSet<T> + Specification<T>.
    // Order applied: NoTracking → SplitQuery → TagWith → Includes → Where → OrderBy → Skip → Take
    public static IQueryable<T>       Apply<T>(IQueryable<T> source, Specification<T> spec)
        where T : class;

    // Projection variant — calls the base overload then appends .Select(spec.Selector).
    public static IQueryable<TResult> Apply<T, TResult>(IQueryable<T> source,
        Specification<T, TResult> spec)
        where T : class;
}
```

#### `EfRepository<T>` and `EfUnitOfWork`

```csharp
// Sealed — not designed for subclassing or mocking; test via InMemory or Testcontainers.
public sealed class EfRepository<T> : IRepository<T> where T : class, IEntity
{
    public EfRepository(DbContext context);
    // All IRepository<T> members delegate to SpecificationEvaluator + DbSet<T>.
    // PageAsync issues two queries: CountAsync (no paging) + ToListAsync (with paging).
}

public sealed class EfUnitOfWork : IUnitOfWork
{
    // ConcurrentDictionary<Type, object> for lazy EfRepository<T> creation.
    public EfUnitOfWork(DbContext context);
    public IRepository<T> Repository<T>() where T : class, IEntity;
    public Task<int> SaveChangesAsync(CancellationToken cancellationToken = default);
    public ValueTask DisposeAsync();
}
```

`EfUnitOfWork` registers `DbContext` as a scoped dependency — the same context instance is used for every `Repository<T>()` call within the request, ensuring change-tracker consistency.

#### Migration Support

`BseDataEfOptions.EnableMigrations` (default `false`) controls whether the framework registers `EfMigrationsHostedService<TContext>`:

```csharp
// Fail-fast: applies pending EF migrations at startup before serving traffic.
// Any MigrateAsync failure propagates, aborting the host startup.
public sealed class EfMigrationsHostedService<TContext> : IHostedService
    where TContext : DbContext;
```

When `EnableMigrations = false` (the default), the framework takes **no opinion** on schema management. Teams choose from: Flyway (preferred, see ADR-0010), `dotnet ef migrations bundle`, or manual SQL scripts. The hosted service is an opt-in escape hatch for smaller services that have no Flyway pipeline.

---

### Dapper Implementation — `Bse.Framework.Data.Dapper`

This package has **no dependency** on `Bse.Framework.Data.EntityFramework`. It uses plain **Dapper** (not Dapper.AOT). The read-side is intentionally separated from the EF write-side so that query-only services (reporting, event projections) can omit EF entirely.

#### Connection Factory

```csharp
public interface IDbConnectionFactory
{
    // Opens (and establishes) a connection. Called once per repository method.
    Task<IDbConnection> OpenAsync(CancellationToken cancellationToken = default);
}

// Provider-agnostic: the caller supplies the connection-creation delegate.
public sealed class DelegateConnectionFactory : IDbConnectionFactory
{
    public DelegateConnectionFactory(Func<CancellationToken, Task<IDbConnection>> factory);
}
```

Example wiring for Npgsql:

```csharp
builder.AddBseDataDapper(_ =>
    new DelegateConnectionFactory(async ct =>
    {
        var conn = new NpgsqlConnection(connectionString);
        await conn.OpenAsync(ct);
        return conn;
    }));

// Or the convenience string overload:
builder.AddBseDataDapper(connectionString, cs => new NpgsqlConnection(cs));
```

The factory is registered as a singleton because it is stateless; `DapperReadRepository` is scoped.

#### `IReadRepository`

Raw-SQL read contract. Does not accept `Specification<T>` — hand-written SQL gives full control over join shape and index usage that LINQ cannot guarantee.

```csharp
public interface IReadRepository
{
    Task<T?> QuerySingleOrDefaultAsync<T>(
        string sql, object? parameters = null,
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<T>> QueryAsync<T>(
        string sql, object? parameters = null,
        CancellationToken cancellationToken = default);

    Task<T?> ExecuteScalarAsync<T>(
        string sql, object? parameters = null,
        CancellationToken cancellationToken = default);

    // sql must contain literal {OFFSET} and {LIMIT} placeholders.
    // These are substituted via string.Replace (not SQL parameters) before execution
    // because some providers reject parameterised LIMIT/OFFSET clauses.
    // SECURITY: only the parameters bag is safe for user input; sql must be a constant.
    Task<PagedResult<T>> QueryPageAsync<T>(
        string sql, string countSql,
        int page, int pageSize,
        object? parameters = null,
        CancellationToken cancellationToken = default);
}
```

`{OFFSET}` and `{LIMIT}` substitution example:

```sql
SELECT invoice_id, total, issued_at
FROM invoices
WHERE tenant_id = @TenantId AND status = @Status
ORDER BY issued_at DESC
LIMIT {LIMIT} OFFSET {OFFSET}
```

The companion `countSql` receives the same `parameters` bag:

```sql
SELECT COUNT(*) FROM invoices
WHERE tenant_id = @TenantId AND status = @Status
```

#### `DapperReadRepository` (internal)

```csharp
// internal sealed partial — not part of the public API.
internal sealed partial class DapperReadRepository : IReadRepository
{
    public DapperReadRepository(IDbConnectionFactory connectionFactory,
        ILogger<DapperReadRepository>? logger = null);
}
```

Each method: opens a fresh connection via `IDbConnectionFactory.OpenAsync`, executes via Dapper, disposes the connection. Results are materialised (`AsList()`) before the connection closes so the caller can iterate without keeping the connection open. `DbException` and `InvalidOperationException` are caught and re-thrown as `BseDataAccessException`; `OperationCanceledException` propagates naturally.

Queries are logged at `Debug` level only (SQL text may contain PII in column or table names). `LoggerMessage` source-generation delegates avoid string allocations on the hot path.

---

### CQRS Split Rationale

| Concern | EF Core (write model) | Dapper (read model) |
|---|---|---|
| Change tracking | Yes — interceptors stamp audit fields | Not applicable |
| Global query filters | Yes — tenant + soft-delete enforced | Bypassed — Postgres RLS enforces isolation (ADR-0006) |
| SQL control | EF-generated | Hand-written, full control |
| Complex joins / aggregations | LINQ becomes awkward | Natural SQL |
| Connection | Scoped DbContext | Per-call connection via factory |
| DI coupling | `IUnitOfWork` (scoped) | `IReadRepository` (scoped) |

**Rule of thumb:** use EF when writing data or when change-tracking simplifies the logic; use Dapper when reading data for display, reporting, or aggregation.

---

### Data Flow

#### Write Path (EF Core)

```
Handler
  → IUnitOfWork.Repository<T>()        (cached EfRepository<T>)
  → IRepository<T>.AddAsync / Update / Remove
  → IUnitOfWork.SaveChangesAsync()
      → AuditingSaveChangesInterceptor.SavingChangesAsync()
          ├─ Stamp CreatedAt/CreatedBy (Added)
          ├─ Stamp ModifiedAt/ModifiedBy (Modified); lock Created* fields
          ├─ Rewrite Deleted → Modified for ISoftDelete
          └─ Stamp TenantId / assert cross-tenant safety for IMultiTenant
      → EF Core generates + sends SQL
      → DataInstrumentationInterceptor — record span + histogram
      → [on failure] ConcurrencyExceptionMapper → BseConcurrencyException
```

#### Read Path — Specification (EF Core)

```
Handler
  → IUnitOfWork.Repository<T>()
  → IRepository<T>.ListAsync(spec) / PageAsync(spec)
      → SpecificationEvaluator.Apply(dbSet, spec)   // builds IQueryable
      → EF Core generates + sends SQL
      → DataInstrumentationInterceptor — record span + histogram
      → materialise to IReadOnlyList<T> / PagedResult<T>
```

#### Read Path — Raw SQL (Dapper)

```
Handler
  → IReadRepository.QueryAsync<TDto>(sql, params)
      → IDbConnectionFactory.OpenAsync()
      → Dapper.QueryAsync<TDto>(CommandDefinition)
      → materialise → dispose connection
      → [on DbException / InvalidOperationException] → BseDataAccessException
```

---

### Configuration

```csharp
// Minimal — EF Core only, no migration service.
builder.AddBseFramework()
    .AddBseDataEntityFramework<AppDbContext>(opts =>
        opts.UseNpgsql(connectionString));

// With opt-in migrate-at-startup.
builder.AddBseFramework()
    .AddBseDataEntityFramework<AppDbContext>(
        opts => opts.UseNpgsql(connectionString),
        ef  => ef.EnableMigrations = true);

// Add Dapper read-side (can be combined with EF or used alone).
builder.AddBseFramework()
    .AddBseDataDapper(connectionString, cs => new NpgsqlConnection(cs));
```

`AddBseDataEntityFramework<TContext>` registers:
- `TContext` (scoped, via `AddDbContext`).
- `DbContext → TContext` alias (scoped, for `EfUnitOfWork`).
- `IUnitOfWork → EfUnitOfWork` (scoped).
- `ConcurrencyExceptionMapper` and `DataInstrumentationInterceptor` (added to `DbContextOptionsBuilder`).

`AddBseDataDapper` registers:
- `IDbConnectionFactory` (singleton).
- `IReadRepository → DapperReadRepository` (scoped, `TryAdd` — idempotent on double-call).

---

### Error Handling

| Source | Exception | BSE type | When |
|---|---|---|---|
| EF `SaveChangesAsync` | `DbUpdateConcurrencyException` | `BseConcurrencyException` | Postgres xmin mismatch |
| Dapper methods | `DbException` or `InvalidOperationException` | `BseDataAccessException` | Driver-level failure |
| `AuditingSaveChangesInterceptor` | — | `BseAuthorizationException` | Cross-tenant update detected |
| `AuditingSaveChangesInterceptor` | — | `BseValidationException` | `IMultiTenant` insert with no TenantId in anonymous context |
| `IRepository<T>.PageAsync` | — | `InvalidOperationException` | Specification has no `Skip`/`Take` (`.Page()` not called) |
| `IReadRepository.QueryPageAsync` | — | `BseValidationException` | `{OFFSET}`/`{LIMIT}` placeholders absent from SQL, or page/pageSize < 1 |

---

### Performance Considerations

- `EfUnitOfWork` caches repositories in `ConcurrentDictionary<Type, object>` — `EfRepository<T>` instances are lightweight wrappers and creation cost is negligible, but the cache avoids repeated allocations within a single request.
- `SpecificationEvaluator` applies `AsNoTracking` and `AsSplitQuery` only when the specification requests them. For heavy read-only EF queries, callers should set `.AsNoTracking()` to avoid change-tracker overhead.
- `DataInstrumentationInterceptor` uses `Stopwatch.GetTimestamp()` + `AsyncLocal` to avoid `DateTime` allocation on the hot path.
- Dapper materialises result sets to `List<T>` before closing the connection; for very large result sets, callers should use `PageAsync` / `QueryPageAsync` rather than `QueryAsync`.
- `PageAsync` issues two queries (count + page). For UIs where a stale total count is acceptable, callers can cache the count externally and use `ListAsync` with a paged spec instead.

### Security Considerations

- `SpecificationEvaluator` is the sole consumer of `IQueryable`; it never exposes the queryable externally, preventing ad-hoc filter bypass.
- `SoftDeleteQueryFilterConvention` and `MultiTenantQueryFilterConvention` apply globally to all entity types that implement the respective interface — new entities automatically inherit the filters without developer action.
- The `AuditingSaveChangesInterceptor` cross-tenant check is a second enforcement layer. The first layer is the EF global query filter; the interceptor defends against `IgnoreQueryFilters()` usage or tracked-entity leakage across request scopes.
- Dapper bypasses EF query filters entirely. Tenant isolation for Dapper queries is enforced at the PostgreSQL layer via Row-Level Security (see ADR-0006). Application code must pass tenant identifiers as SQL parameters (never as string interpolation).
- `DataInstrumentationInterceptor` omits SQL command text from span attributes to prevent PII leakage into telemetry backends (Tempo, Jaeger, etc.).

### Observability

| Signal | Name | Source |
|---|---|---|
| Trace span | `db.reader` / `db.nonquery` | `DataInstrumentationInterceptor` |
| ActivitySource | `Bse.Data.EntityFramework` | `DataInstrumentationInterceptor.ActivitySource` |
| Histogram | `bse.data.query.duration` (seconds) | `DataInstrumentationInterceptor.QueryDuration` |
| Span tags | `db.system.name=postgresql`, `db.operation.name` | `DataInstrumentationInterceptor` |
| Debug logs | query SQL (Debug level only) | `DapperReadRepository` (`LoggerMessage` delegates) |

`Bse.Framework.Telemetry` subscribes to `Bse.Data.EntityFramework` as a default `ActivitySource`, so spans appear in Tempo/Grafana without any consumer configuration.

### Testing Strategy

#### Unit Tests (EF Core)

EF `InMemory` provider is acceptable for testing specification logic and interceptor behaviour where SQLite or Postgres constraints are not required. `NSubstitute` stubs `IRepository<T>` and `IUnitOfWork` at the handler layer.

```csharp
var options = new DbContextOptionsBuilder<AppDbContext>()
    .UseInMemoryDatabase(Guid.NewGuid().ToString())
    .Options;
using var ctx = new AppDbContext(options, new SystemClock());
// ... arrange, act, assert
```

For SQL-correct tests (constraint violations, soft-delete filter, multi-tenant filter), use Testcontainers:

```csharp
// postgres:16-alpine container — shared across the test class via IClassFixture.
_container = new PostgreSqlBuilder()
    .WithImage("postgres:16-alpine")
    .Build();
```

#### Unit Tests (Dapper)

`Microsoft.Data.Sqlite` with an in-memory database stands in for Postgres when testing `IReadRepository` implementations without a container. For SQL syntax that diverges between SQLite and Postgres (window functions, `LIMIT/OFFSET` vs `OFFSET/FETCH`), use Testcontainers with `postgres:16-alpine`.

---

## Migration Path

The existing BSE applications use EF 6 Database-First with EDMX models and raw SQL string concatenation. Migration to this layer is incremental:

| Legacy pattern | Framework replacement |
|---|---|
| `GenericRepository<T>` with `AsQueryable()` | `IRepository<T>` via `IUnitOfWork` — no `IQueryable` exposed |
| `db.Database.SqlQuery<T>("... = " + input)` | `IReadRepository.QueryAsync<T>(sql, new { Param = value })` |
| Static `UnitOfWork` singleton | `IUnitOfWork` scoped per request via DI |
| Manual `WHERE IsDeleted = 0` on every query | `SoftDeleteQueryFilterConvention` — applied globally |
| Manual `WHERE CompCode = @c` on every query | `MultiTenantQueryFilterConvention` + interceptor |
| `byte[] RowVersion` concurrency | `uint Xmin` with `IConcurrencyAware` (Postgres) |
| No audit fields | `IAuditable` + `AuditingSaveChangesInterceptor` |
| OFFSET/ROW_NUMBER ad-hoc pagination | `PagedRequest` / `PagedResult<T>` / `Specification<T>.Page()` |
| 240+ manual DI registrations | Two `AddBse*` calls |

**Recommended migration order per service:**

1. Add `Bse.Framework.Data.EntityFramework` reference; subclass `BseDbContext`.
2. Scaffold existing tables with `dotnet ef dbcontext scaffold` (once); create an empty "baseline" migration.
3. Implement `IAuditable`, `ISoftDelete`, `IMultiTenant` on entities that need them.
4. Replace `GenericRepository<T>` usages with `IUnitOfWork.Repository<T>()`.
5. Add `Bse.Framework.Data.Dapper`; move complex read queries to `IReadRepository`.
6. Remove raw-SQL string-concatenation queries.

---

## Open Questions

1. **Keyset/cursor pagination** — `PagedRequest`/`PagedResult<T>` cover only offset pagination. Large datasets (student lists, transaction histories) exhibit O(n) degradation with deep offsets. A `CursorRequest`/`CursorResult<T>` contract and corresponding `IRepository<T>.CursorAsync` method are the planned solution, but the implementation depends on stabilising the strongly-typed ID convention first.

2. **`IHasDomainEvents` dispatch** — the interceptor infrastructure for post-commit domain event dispatch is held pending `Bse.Framework.Rpc` stabilisation. Entities can implement `IHasDomainEvents` today; events will accumulate but not be dispatched until the hosting interceptor ships.

3. **Dapper instrumentation** — `DapperReadRepository` emits structured logs but no OpenTelemetry spans. A `DbCommandInterceptor`-equivalent for Dapper (via `IDbCommand` wrapping or a custom `CommandDefinition` factory) is under evaluation.

4. **EF `ExecuteUpdate`/`ExecuteDelete`** — bulk operations that bypass the change tracker and thus bypass `AuditingSaveChangesInterceptor` are not exposed on `IRepository<T>`. A deliberate choice: callers who need bulk mutations accept that audit fields will not be stamped automatically and must handle this in application code or a dedicated stored procedure.

---

## References

- **ADR-0003** — EF Core + Dapper Hybrid Data Access (CQRS Split)
- **ADR-0006** — Hybrid Multi-Tenancy (RLS for Dapper isolation)
- **ADR-0010** — Flyway for Schema Migrations
- **RFC-0001** — Bse.Framework Overview
- **RFC-0006** — Multi-Tenancy
- Ardalis.Specification — https://specification.ardalis.com/ (inspiration for the specification pattern; BSE uses a concrete builder class, not the Ardalis abstract base)
- EF Core SaveChanges Interceptors — https://learn.microsoft.com/ef/core/logging-events-diagnostics/interceptors
- EF Core Global Query Filters — https://learn.microsoft.com/ef/core/querying/filters
- Dapper — https://github.com/DapperLib/Dapper (plain Dapper, not Dapper.AOT)
- OpenTelemetry .NET — https://opentelemetry.io/docs/languages/dotnet/
- Martin Fowler, CQRS — https://martinfowler.com/bliki/CQRS.html
