# RFC-0003: Data Access Layer

- **Status:** Approved
- **Date:** 2026-04-06
- **Related ADRs:** ADR-0003, ADR-0006, ADR-0008
- **Related RFCs:** RFC-0001, RFC-0006

## Abstract

The framework provides a CQRS-style data access layer with EF Core for commands (writes) and Dapper for queries (complex reads). Source generators eliminate boilerplate by generating repositories from `IEntity` markers and Dapper implementations from `[Query]`-attributed interfaces. The design enforces parameterization at compile time (eliminating SQL injection), supports the Specification pattern (no leaky `IQueryable` exposure), provides offset and keyset pagination, integrates concurrency control, domain events, and a transactional outbox.

## Motivation

The existing BSE apps suffer from:
- **SQL injection** via `db.Database.SqlQuery<T>("... where x = " + input)`
- **Generic repository anti-pattern** with leaky `AsQueryable()` exposure
- **240+ manual service registrations** in DI
- **Inconsistent pagination** (none/OFFSET/ROW_NUMBER) across apps
- **Static UnitOfWork** with thread-safety issues
- **No async/await** support
- **EDMX Database-First** with auto-generated entities (regenerated frequently, manual changes lost)
- **Plain entity exposure** in API responses (no DTO separation)
- **No concurrency control** (lost updates possible)
- **No transactional outbox** (events can be lost on crash)

## Goals

- Eliminate SQL injection by construction
- Eliminate manual repository writing (source generators)
- Provide CQRS split with clear guidelines
- Support both SQL Server and PostgreSQL
- Multi-tenant data isolation at four layers
- Concurrency control via RowVersion/xmin
- Domain events dispatched after commit
- Transactional outbox for reliable event publishing
- Cursor and offset pagination
- Strongly-typed IDs across EF and Dapper

## Non-Goals

- Supporting non-relational databases (NoSQL via separate package later)
- Cross-database transactions (use outbox + saga pattern)
- ORM-agnostic abstraction over EF Core (it leaks anyway)

## Design

### Entity Markers

```csharp
public interface IEntity { }

public interface IEntity<TKey> : IEntity
{
    TKey Id { get; }
}

public interface IMultiTenant
{
    string TenantId { get; }
}

public interface IConcurrencyAware
{
    byte[] RowVersion { get; }  // SQL Server: rowversion, PostgreSQL: xmin
}

public interface IAuditable
{
    DateTime CreatedAt { get; }
    string CreatedBy { get; }
    DateTime? ModifiedAt { get; }
    string? ModifiedBy { get; }
}

public interface IFullyAudited : IAuditable
{
    // Captures before/after property values to AuditLog table
}

public interface ISoftDelete
{
    bool IsDeleted { get; }
    DateTime? DeletedAt { get; }
}

public interface IHasDomainEvents
{
    IReadOnlyList<IDomainEvent> DomainEvents { get; }
    void ClearDomainEvents();
}
```

### Repository Abstraction

Specification-based, no leaky `IQueryable`:

```csharp
public interface IRepository<T> where T : class, IEntity
{
    // Single-entity reads
    Task<T?> GetByIdAsync(object id, bool tracked = true, CancellationToken ct = default);
    Task<List<T>> GetByIdsAsync(IEnumerable<object> ids, CancellationToken ct = default);
    Task<bool> ExistsAsync(object id, CancellationToken ct = default);

    // Specification-based reads
    Task<T?> GetFirstOrDefaultAsync(ISpecification<T> spec, CancellationToken ct = default);
    Task<List<T>> GetAllAsync(ISpecification<T>? spec = null, CancellationToken ct = default);
    Task<int> CountAsync(ISpecification<T>? spec = null, CancellationToken ct = default);
    Task<bool> AnyAsync(ISpecification<T> spec, CancellationToken ct = default);

    // Writes
    Task<T> InsertAsync(T entity, CancellationToken ct = default);
    Task InsertManyAsync(IEnumerable<T> entities, CancellationToken ct = default);
    Task<T> UpdateAsync(T entity, CancellationToken ct = default);
    Task DeleteAsync(T entity, CancellationToken ct = default);

    // Bulk operations (.NET 7+ ExecuteUpdate/ExecuteDelete)
    // WARNING: bypasses change tracker, audit interceptors, and soft delete
    Task<int> ExecuteUpdateAsync(Expression<Func<T, T>> update, CancellationToken ct = default);
    Task<int> ExecuteDeleteAsync(Expression<Func<T, bool>> predicate, CancellationToken ct = default);
}
```

`GetByIdAsync` uses EF Core's `FindAsync` internally when `tracked=true`, which checks the change tracker first (avoiding DB round-trip for already-tracked entities).

### Specification Pattern (Ardalis-style)

```csharp
public abstract class Specification<T>
{
    public Expression<Func<T, bool>>? Criteria { get; protected set; }
    public List<Expression<Func<T, object>>> Includes { get; } = new();
    public Expression<Func<T, object>>? OrderBy { get; protected set; }
    public bool Descending { get; protected set; }
    public string? QueryTag { get; protected set; }              // Shows in EF logs/SQL profiler
    public bool AsNoTracking { get; protected set; }
    public bool AsSplitQuery { get; protected set; }
    public List<SearchCriterion>? SearchCriterias { get; protected set; }  // SQL LIKE
}

// IgnoreQueryFilters is INTENTIONALLY not exposed.
// Use BseUnfilteredDbContext for soft-delete bypass (which keeps tenant filter).

// Projection variant
public interface ISpecification<T, TResult>
{
    Expression<Func<T, TResult>> Selector { get; }
}
```

Example:
```csharp
public class ActiveStudentsByFacultySpec : Specification<Student>
{
    public ActiveStudentsByFacultySpec(int facultyCode)
    {
        Criteria = s => s.FacultyCode == facultyCode && !s.IsDeleted;
        OrderBy = s => s.StudentName;
        Includes.Add(s => s.Faculty);
        QueryTag = nameof(ActiveStudentsByFacultySpec);
        AsNoTracking = true;
    }
}
```

### Unit of Work

```csharp
public interface IUnitOfWork : IDisposable
{
    IRepository<T> Repository<T>() where T : class, IEntity;
    Task<int> SaveAsync(CancellationToken ct = default);
    Task<IDbTransaction> BeginTransactionAsync(CancellationToken ct = default);
}
```

`SaveAsync` is called automatically by middleware at end of request (ABP pattern), not manually by developers.

### Pagination

#### Offset-Based (Admin Dashboards)

```csharp
public record PagedRequest(int Page = 1, int PageSize = 20, string? SortBy = null, bool Descending = false);
public record PagedResult<T>(List<T> Items, int TotalCount, int Page, int PageSize, int TotalPages);
```

#### Keyset/Cursor-Based (APIs, Infinite Scroll)

```csharp
public record CursorRequest(string? After = null, int First = 20, string? Before = null, int? Last = null);
public record CursorResult<T>(List<T> Items, string? StartCursor, string? EndCursor,
                               bool HasNextPage, bool HasPreviousPage);
```

Keyset pagination is required for large datasets (offset degrades linearly).

### Dapper Query Source Generator

Developers write an interface; the generator creates the implementation:

```csharp
[DapperQueries]
public interface IStudentQueries
{
    [Query("""
        SELECT s.StudentId, s.StudentName, f.FacultyName, b.BatchName
        FROM U_D_Student s
        JOIN U_D_Faculty f ON s.FacultyCode = f.FacultyCode
        JOIN U_D_Batch b ON s.BatchCode = b.BatchCode
        WHERE s.CompCode = @CompCode AND s.StudentId = @StudentId
    """)]
    Task<StudentDetailDto?> GetStudentDetail(int compCode, int studentId);

    [Query("""
        SELECT s.StudentId, s.StudentName, s.FacultyCode
        FROM U_D_Student s
        WHERE s.CompCode = @CompCode AND s.FacultyCode = @FacultyCode
        ORDER BY s.StudentName
    """)]
    [Paginated]
    Task<PagedResult<StudentListDto>> GetStudentsByFaculty(
        int compCode, int facultyCode, PagedRequest paging);

    [Query("""
        SELECT s.StudentId, s.StudentName
        FROM U_D_Student s
        WHERE s.CompCode = @CompCode AND s.StudentId > @AfterId
        ORDER BY s.StudentId
    """)]
    [KeysetPaginated("StudentId")]
    Task<CursorResult<StudentListDto>> ListStudents(int compCode, CursorRequest cursor);

    [Query("EXEC GProc_CreateBranch @CompCode, @BranchName, @BranchType")]
    Task<int> CreateBranch(int compCode, string branchName, string branchType);
}
```

The generator:
1. Validates the SQL at build time (catches missing parameters)
2. Generates parameterized Dapper.AOT calls (impossible to inject SQL)
3. Auto-registers in DI
4. Adds OpenTelemetry Activity per query
5. Routes to read replica connection (configurable)
6. Compile-error if return type implements `IEntity` (read models must be DTOs)

### `[Paginated]` Source Generator Magic

When the generator sees `[Paginated]` on a method returning `PagedResult<T>`, it rewrites the SQL at compile time:
- Wraps original query as a CTE
- Adds `COUNT(*) OVER()` for total count
- Appends `OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY` (SQL Server) or `LIMIT @PageSize OFFSET @Offset` (PostgreSQL)
- Provider-aware via `<BseDbProvider>` MSBuild property

### EF Core Implementation

#### BseDbContext

```csharp
public abstract class BseDbContext : DbContext
{
    private readonly ITenantContext _tenant;
    private readonly ICurrentUser _user;

    // Automatic query filters via reflection over IMultiTenant entities
    // Automatic audit fields via SaveChangesInterceptor
    // Connection string resolved per-tenant
}
```

Two contexts to safely handle filter bypass:
- `BseDbContext` — has BOTH tenant + soft-delete filters (default)
- `BseUnfilteredDbContext` — has ONLY tenant filter, no soft-delete filter (admin "show deleted" queries)

The tenant filter is **never removable** via application code.

#### Pooling with Multi-Tenancy

Uses `AddPooledDbContextFactory<T>` (not `AddDbContext`) for performance. Tenant state injected via scoped wrapper after pool checkout.

#### Connection Resiliency

`EnableRetryOnFailure()` ON by default. User-initiated transactions wrapped in execution strategy.

#### Audit via SaveChangesInterceptor

Composable, can be disabled in seeding/migration scenarios. Captures audit fields automatically.

#### Domain Event Dispatch

Via `SaveChangesInterceptor`, AFTER commit:
1. SaveChanges commits business data
2. Interceptor collects DomainEvents from changed entities
3. Clears events from entities
4. Dispatches via `IMediator` or internal event bus

### Strongly-Typed IDs

Source generator emits coordinated registrations from a single attribute:

```csharp
[StronglyTypedId(typeof(int))]
public readonly partial record struct StudentId(int Value);

// Generator produces:
// 1. EF Core ValueConverter<StudentId, int> (via ConfigureConventions)
// 2. Dapper SqlMapper.TypeHandler<StudentId> (registered at startup)
// 3. System.Text.Json JsonConverter<StudentId>
```

### Concurrency Control

```csharp
public interface IConcurrencyAware
{
    byte[] RowVersion { get; }  // SQL Server: rowversion, PostgreSQL: xmin
}

// SaveAsync wraps DbUpdateConcurrencyException:
public class ConcurrencyConflictException : BseException
{
    public object ConflictingEntity { get; }
    public object DatabaseValues { get; }
    public object ProposedValues { get; }
}
```

`ExecuteUpdate`/`ExecuteDelete` bypass the change tracker. Concurrency must be handled manually via `WHERE RowVersion = @expected`.

### Transactional Outbox

For reliable event publishing in same DB transaction as business operation:

```csharp
public interface IOutbox
{
    void Publish<T>(string topic, T eventData) where T : class;
}

// Usage:
public class EnrollmentHandler
{
    public async Task<EnrollmentResult> Enroll(EnrollRequest req,
        IUnitOfWork uow, IOutbox outbox)
    {
        var student = await uow.Repository<Student>().GetByIdAsync(req.StudentId);
        student.Enroll(req.SemesterId);

        // Event written to outbox table in SAME database transaction
        outbox.Publish("student.enrolled", new StudentEnrolledEvent { ... });

        await uow.SaveAsync();
        // Background worker polls outbox, publishes to Redis Streams, marks as sent
    }
}
```

Implementation features:
- Inbox deduplication (prevent duplicate event processing)
- Delivery ordering (sequence number per stream)
- Cleanup job (archive delivered messages after configurable TTL)
- Poison message handling (DLQ after max retries)
- Outbox table MUST be in same database as entity tables
- Polling interval: configurable (default 1s)

Evaluation: MassTransit outbox preferred if MassTransit-compatible; custom outbox for Redis Streams only.

### Multi-Tenant Data Isolation

Four-layer defense in depth (see RFC-0006):
1. EF Core query filters
2. SaveChangesInterceptor (insert/update tampering prevention)
3. Roslyn analyzer (forbids `IgnoreQueryFilters`)
4. **PostgreSQL Row-Level Security (RLS)** — covers Dapper queries that bypass EF filters

### Caching

NOT in `IRepository` (violates SRP, impossible to invalidate with `ExecuteUpdate`).

Three layers:
1. **EF Core second-level cache** via `EFCoreSecondLevelCacheInterceptor`
2. **Dapper query cache** via `[Cached(seconds)]` attribute
3. **Reference data cache** via `IMemoryCache` for rarely-changing data

### Distributed Locking

Exposed as infrastructure service via `Medallion.Threading`:
```csharp
public interface IDistributedLockProvider
{
    Task<IDistributedLock> AcquireAsync(string key, TimeSpan timeout, CancellationToken ct);
}
```

Implementations: PostgreSQL advisory locks, Redis locks, SQL Server application locks.

NOT embedded in repository. Application services acquire locks explicitly when needed.

### Seed Data

| Type | Mechanism |
|---|---|
| Reference data (static) | EF Core `HasData` (deterministic PKs, migration-tracked) |
| Dynamic data (admin users) | `UseSeeding`/`UseAsyncSeeding` (EF Core 9+, idempotent) |
| Per-tenant data | Custom `ITenantSeeder`, runs at tenant provisioning time |
| Test data | Builder pattern (`StudentBuilder.WithName("Test").Build()`) |

### Migration Strategy

For existing 100-449 table databases:

#### Phase 1: Scaffold once
```bash
dotnet ef dbcontext scaffold "Server=.;Database=SafePack_CRE;..." \
    --context SafePackDbContext \
    --output-dir Entities \
    --data-annotations
```
Create "Initial" migration with **empty Up/Down methods** (tells EF Core "DB matches model" without recreating anything).

#### Phase 2: Incremental adoption
- Only map tables your new code WRITES to in EF Core
- Read-only legacy tables → Dapper queries only
- Forward migrations only contain deltas

#### Phase 3: Drift detection
- SQL Server: SSDT / DACFACs
- PostgreSQL: migra or pgquarrel
- CI pipeline runs comparison, fails on unexpected drift

### Provider Awareness

Source generator emits provider-specific SQL:

| Feature | SQL Server | PostgreSQL |
|---|---|---|
| Pagination | OFFSET/FETCH | LIMIT/OFFSET |
| Filtered index | `WHERE IsDeleted = 0` | `WHERE IsDeleted = false` |
| Bulk insert | SqlBulkCopy | COPY (binary) |
| JSON columns | OPENJSON | jsonb operators |
| Concurrency | rowversion | xmin |
| Temporal tables | Built-in | Not available |

Detection via `.csproj` property:
```xml
<BseDbProvider>SqlServer</BseDbProvider>
```

## Configuration

```csharp
services.AddBseData(data => {
    data.UseSqlServer(primary: "...", readReplica: "...");
    data.EnableRetryOnFailure();
    data.UseSplitQuery();
    data.UseSecondLevelCache(redis: "...");
});

services.AddDapperQueries(dapper => {
    dapper.UseConnectionFactory<TenantConnectionFactory>();
    dapper.UseReadReplica = true;
});
```

## Testing Strategy

**NEVER** use EF Core InMemory provider (no FK constraints, no transactions, masks LINQ translation issues).

Official test stack:
- **Testcontainers.NET** — real PostgreSQL/SQL Server in Docker
- **Respawn** — reset DB between tests in milliseconds
- **xUnit `IClassFixture<DatabaseFixture>`** — share container across test class
- **Test data builders** — `StudentBuilder.WithName("Test").Build()`

Rules:
- One container per test run, not per test
- Each test creates its own tenant (random GUID) for isolation
- `context.Database.MigrateAsync()` runs once at fixture init
- Integration tests in separate project (requires Docker)
- Unit tests = zero infrastructure, pure domain logic

## Performance Considerations

- DbContext pooling enabled by default
- Compiled queries for hot paths (EF Core 9 precompiled queries)
- Split queries for collection includes
- ExecuteUpdate/ExecuteDelete for bulk operations (300-500x faster than load + SaveChanges)
- Dapper for read-heavy hot paths
- Connection pool sizes tuned per tenant strategy

## Security Considerations

- SQL injection impossible by construction (Roslyn analyzer + Dapper.AOT)
- All four tenant isolation layers active
- Audit trail via SaveChangesInterceptor
- Sensitive columns marked `[Sensitive]` are encrypted at rest
- Secrets (connection strings, keys) loaded from Key Vault, not appsettings

## Migration Path

| Current Pattern | Framework Replacement |
|---|---|
| `GenericRepository<T>` (manual) | `IRepository<T>` (source-generated) |
| Static `UnitOfWork` | `IUnitOfWork` scoped per request |
| `db.Database.SqlQuery<T>(rawSql)` with concat | `[Query]` interfaces with parameterized Dapper |
| No/inconsistent pagination | `[Paginated]` and `[KeysetPaginated]` attributes |
| 240+ manual service registrations | Zero — source generators + DI auto-registration |
| `DbEntityValidationException` catch blocks | Validation middleware in RPC pipeline |
| Manual `DbContextTransaction` | `IUnitOfWork.BeginTransactionAsync()` + outbox |
| EDMX Database-First | EF Core Code-First (scaffolded from existing DB) |

## References

- ADR-0003, ADR-0006, ADR-0008
- Ardalis.Specification: https://specification.ardalis.com/
- Dapper.AOT: https://aot.dapperlib.dev/
- StronglyTypedId by Andrew Lock
- EFCoreSecondLevelCacheInterceptor (VahidN)
- Medallion.Threading
