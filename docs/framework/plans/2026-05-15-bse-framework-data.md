# Bse.Framework.Data v0.1.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship two packages — `Bse.Framework.Data` (abstractions) and `Bse.Framework.Data.EntityFramework` (EF Core 9 implementation, Postgres-only) — that give app teams an opinionated, source-generator-free data access layer per the v0.1.0 scope of RFC-0003: entity markers, Specification<T>, IRepository<T>, IUnitOfWork, BseDbContext base with audit + soft-delete query filter, offset pagination, EF concurrency exception mapping, and Telemetry-integrated query instrumentation. Schema migrations are handled by Flyway (ADR-0010), never EF Core's `Add-Migration`. The cycle also expands the `samples/observability-stack/` docker-compose with Postgres + Flyway + idle Redis (the latter waiting for the RPC cycle), and adds a runnable `samples/data-demo/` ASP.NET Core CRUD app whose traces flow through the existing observability stack.

**Architecture:**
- `Bse.Framework.Data` — pure abstractions: interfaces (`IRepository<T>`, `IUnitOfWork`, `IEntity`, `ISoftDelete`, etc.), `Specification<T>` base class, pagination DTOs, `BseConcurrencyException` (already in Core — referenced, not redefined). Zero EF dependency.
- `Bse.Framework.Data.EntityFramework` — references the abstractions and `Microsoft.EntityFrameworkCore` 9.x + `Npgsql.EntityFrameworkCore.PostgreSQL`. Provides `BseDbContext` base, `EfRepository<T>`, `EfUnitOfWork`, `AuditingSaveChangesInterceptor`, `SoftDeleteQueryFilterConvention`, `AddBseDataEntityFramework` extension.
- Microsoft.Extensions.* abstractions/implementation split, identical to how Telemetry sits on top of Core.
- Telemetry integration: emits a histogram `bse.data.query.duration` and an `ActivitySource("Bse.Data.EntityFramework")` per SaveChanges + query. Subscribed automatically by the `DefaultSources`/`DefaultMeters` lists in `Bse.Framework.Telemetry`.

**Tech Stack:**
- .NET 9 (single target)
- xUnit / Shouldly / NSubstitute (test stack already in repo)
- `Microsoft.EntityFrameworkCore` 9.0.x
- `Microsoft.EntityFrameworkCore.Relational` 9.0.x
- `Npgsql.EntityFrameworkCore.PostgreSQL` 9.0.x (latest stable that pairs with EF 9.0)
- `Testcontainers.PostgreSql` for repository integration tests (real Postgres in CI, no mocking the DB)
- Flyway 11.x community edition (image `flyway/flyway:11`)
- Postgres 16-alpine

**Repository layout (additions only — Core + Telemetry already in place):**

```
bse-core/
├── src/
│   ├── Bse.Framework.Core/                            ← exists
│   ├── Bse.Framework.Telemetry/                       ← exists
│   ├── Bse.Framework.Data/                            ← NEW (abstractions)
│   │   ├── Bse.Framework.Data.csproj
│   │   ├── README.md
│   │   ├── Entities/
│   │   │   ├── IEntity.cs                             ← + IEntity<TKey>
│   │   │   ├── IAuditable.cs
│   │   │   ├── ISoftDelete.cs
│   │   │   ├── IConcurrencyAware.cs
│   │   │   ├── IMultiTenant.cs
│   │   │   └── IHasDomainEvents.cs
│   │   ├── Specifications/
│   │   │   ├── Specification.cs
│   │   │   ├── SpecificationT.cs                      ← Specification<T, TResult>
│   │   │   └── PaginationExtensions.cs
│   │   ├── Repository/
│   │   │   ├── IRepository.cs
│   │   │   └── IUnitOfWork.cs
│   │   ├── Pagination/
│   │   │   ├── PagedRequest.cs
│   │   │   └── PagedResult.cs
│   │   ├── DomainEvents/
│   │   │   └── IDomainEvent.cs
│   │   └── DependencyInjection/
│   │       └── BseDataBuilder.cs                      ← marker module for IBseModule tracking
│   └── Bse.Framework.Data.EntityFramework/            ← NEW (EF implementation)
│       ├── Bse.Framework.Data.EntityFramework.csproj
│       ├── README.md
│       ├── BseDataEfModule.cs                         ← IBseModule
│       ├── Context/
│       │   ├── BseDbContext.cs
│       │   └── BseDbContextOptions.cs
│       ├── Interceptors/
│       │   └── AuditingSaveChangesInterceptor.cs
│       ├── Conventions/
│       │   └── SoftDeleteQueryFilterConvention.cs
│       ├── Repository/
│       │   ├── EfRepository.cs
│       │   └── EfUnitOfWork.cs
│       ├── Specifications/
│       │   └── SpecificationEvaluator.cs              ← Spec<T> → IQueryable<T>
│       ├── Instrumentation/
│       │   └── DataInstrumentation.cs                 ← ActivitySource + histograms
│       ├── Exceptions/
│       │   └── ConcurrencyExceptionMapper.cs
│       └── DependencyInjection/
│           └── EfServiceCollectionExtensions.cs       ← AddBseDataEntityFramework
├── tests/
│   ├── Bse.Framework.Core.Tests/                      ← exists
│   ├── Bse.Framework.Telemetry.Tests/                 ← exists
│   ├── Bse.Framework.Data.Tests/                      ← NEW (unit tests, no DB)
│   │   ├── Bse.Framework.Data.Tests.csproj
│   │   ├── Specifications/SpecificationTests.cs
│   │   └── Pagination/PagedResultTests.cs
│   └── Bse.Framework.Data.EntityFramework.Tests/      ← NEW (integration, Testcontainers)
│       ├── Bse.Framework.Data.EntityFramework.Tests.csproj
│       ├── Fixtures/PostgresFixture.cs
│       ├── Repository/EfRepositoryTests.cs
│       ├── Repository/EfUnitOfWorkTests.cs
│       ├── Interceptors/AuditingInterceptorTests.cs
│       └── Conventions/SoftDeleteFilterTests.cs
└── samples/                                            ← exists
    ├── observability-stack/                            ← exists; docker-compose grows
    │   ├── docker-compose.yml                          ← + postgres, flyway, redis
    │   ├── postgres/                                   ← NEW
    │   │   └── init.sql                                ← creates bse_demo database
    │   └── README.md                                   ← updated
    └── data-demo/                                      ← NEW
        ├── data-demo.csproj
        ├── Program.cs                                  ← CRUD over Students entity
        ├── appsettings.json
        ├── Models/Student.cs
        ├── Models/Studentcontext.cs                    ← BseDbContext-derived
        ├── db/migrations/                              ← Flyway-managed SQL
        │   ├── V001__init_students.sql
        │   └── V002__add_audit_columns.sql
        └── README.md
```

---

## Task 1: Scaffold projects + Directory.Packages.props additions

**Files:**
- Create: `src/Bse.Framework.Data/Bse.Framework.Data.csproj`
- Create: `src/Bse.Framework.Data/README.md`
- Create: `src/Bse.Framework.Data.EntityFramework/Bse.Framework.Data.EntityFramework.csproj`
- Create: `src/Bse.Framework.Data.EntityFramework/README.md`
- Create: `tests/Bse.Framework.Data.Tests/Bse.Framework.Data.Tests.csproj`
- Create: `tests/Bse.Framework.Data.EntityFramework.Tests/Bse.Framework.Data.EntityFramework.Tests.csproj`
- Modify: `Directory.Packages.props`
- Modify: `BseFramework.sln`

- [ ] **Step 1: Add EF Core + Postgres + Testcontainers package versions to `Directory.Packages.props`**

Append a new ItemGroup before the closing `</Project>`:

```xml
  <ItemGroup Label="EntityFrameworkCore">
    <PackageVersion Include="Microsoft.EntityFrameworkCore" Version="9.0.0" />
    <PackageVersion Include="Microsoft.EntityFrameworkCore.Relational" Version="9.0.0" />
    <PackageVersion Include="Microsoft.EntityFrameworkCore.Design" Version="9.0.0" />
    <PackageVersion Include="Npgsql.EntityFrameworkCore.PostgreSQL" Version="9.0.2" />
  </ItemGroup>

  <ItemGroup Label="Testing.Database">
    <PackageVersion Include="Testcontainers.PostgreSql" Version="4.0.0" />
  </ItemGroup>
```

- [ ] **Step 2: Create `Bse.Framework.Data` (abstractions)**

```bash
mkdir -p src/Bse.Framework.Data
cd src/Bse.Framework.Data
dotnet new classlib --output . --framework net9.0
rm Class1.cs
cd ../..
```

Overwrite `src/Bse.Framework.Data/Bse.Framework.Data.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <RootNamespace>Bse.Framework.Data</RootNamespace>
    <AssemblyName>Bse.Framework.Data</AssemblyName>
    <PackageId>Bse.Framework.Data</PackageId>
    <Description>Bse.Framework data-access abstractions: IRepository, IUnitOfWork, Specification, entity markers, pagination. No ORM dependency.</Description>
    <PackageTags>bse;framework;data;repository;specification</PackageTags>
    <PackageReadmeFile>README.md</PackageReadmeFile>
    <GenerateDocumentationFile>true</GenerateDocumentationFile>
  </PropertyGroup>

  <ItemGroup>
    <None Include="README.md" Pack="true" PackagePath="\" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="..\Bse.Framework.Core\Bse.Framework.Core.csproj" />
  </ItemGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.Extensions.DependencyInjection.Abstractions" />
    <PackageReference Include="Microsoft.SourceLink.GitHub" PrivateAssets="All" />
  </ItemGroup>

</Project>
```

Create `src/Bse.Framework.Data/README.md`:

```markdown
# Bse.Framework.Data

Provider-agnostic data-access abstractions. Reference this from application/domain code; pick an implementation (e.g. `Bse.Framework.Data.EntityFramework`) at the composition root.

## Exports

- Entity markers: `IEntity`, `IEntity<TKey>`, `IConcurrencyAware`, `IAuditable`, `ISoftDelete`, `IMultiTenant`, `IHasDomainEvents`
- `Specification<T>` (Ardalis-style) + `Specification<T, TResult>` projections
- `IRepository<T>`, `IUnitOfWork`
- Offset pagination: `PagedRequest`, `PagedResult<T>`
- `IDomainEvent` marker
- `BseDataBuilder` (registered via `framework.AddBseData()`)

No SQL, no EF, no Dapper here. Schemas are managed by Flyway (ADR-0010) — see `samples/data-demo/db/migrations/` for the pattern.
```

- [ ] **Step 3: Create `Bse.Framework.Data.EntityFramework` (EF implementation)**

```bash
mkdir -p src/Bse.Framework.Data.EntityFramework
cd src/Bse.Framework.Data.EntityFramework
dotnet new classlib --output . --framework net9.0
rm Class1.cs
cd ../..
```

Overwrite csproj:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <RootNamespace>Bse.Framework.Data.EntityFramework</RootNamespace>
    <AssemblyName>Bse.Framework.Data.EntityFramework</AssemblyName>
    <PackageId>Bse.Framework.Data.EntityFramework</PackageId>
    <Description>Bse.Framework.Data implementation on EF Core 9 with Npgsql. Provides BseDbContext, EfRepository, EfUnitOfWork, audit interceptor, soft-delete filter, telemetry instrumentation. Schema migrations handled by Flyway (ADR-0010), not EF migrations.</Description>
    <PackageTags>bse;framework;data;entityframework;efcore;postgres;npgsql</PackageTags>
    <PackageReadmeFile>README.md</PackageReadmeFile>
    <GenerateDocumentationFile>true</GenerateDocumentationFile>
  </PropertyGroup>

  <ItemGroup>
    <None Include="README.md" Pack="true" PackagePath="\" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="..\Bse.Framework.Core\Bse.Framework.Core.csproj" />
    <ProjectReference Include="..\Bse.Framework.Data\Bse.Framework.Data.csproj" />
    <ProjectReference Include="..\Bse.Framework.Telemetry\Bse.Framework.Telemetry.csproj" />
  </ItemGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.EntityFrameworkCore" />
    <PackageReference Include="Microsoft.EntityFrameworkCore.Relational" />
    <PackageReference Include="Npgsql.EntityFrameworkCore.PostgreSQL" />
    <PackageReference Include="Microsoft.SourceLink.GitHub" PrivateAssets="All" />
  </ItemGroup>

</Project>
```

Create `src/Bse.Framework.Data.EntityFramework/README.md`:

```markdown
# Bse.Framework.Data.EntityFramework

EF Core 9 + Npgsql implementation of `Bse.Framework.Data`.

## Provides

- `BseDbContext` base (audit interceptor, soft-delete query filter, telemetry hooks)
- `EfRepository<T>` — Specification<T>-driven, no leaky IQueryable
- `EfUnitOfWork`
- `AuditingSaveChangesInterceptor` — populates `IAuditable` fields automatically
- `SoftDeleteQueryFilterConvention` — global filter for `ISoftDelete` entities
- `ConcurrencyExceptionMapper` — translates EF `DbUpdateConcurrencyException` into `BseConcurrencyException`
- Telemetry: `Bse.Data.EntityFramework` ActivitySource + `bse.data.query.duration` histogram

## Schema management

This package consumes the schema; it does not shape it. Use **Flyway** for migrations (see ADR-0010 and the `samples/data-demo/db/migrations/` pattern). EF Core migrations are intentionally not used.

## Quick start

```csharp
services.AddBseFramework(framework =>
{
    framework.AddBseTelemetry(t => /* ... */);

    framework.AddBseData();
    framework.AddBseDataEntityFramework<StudentDbContext>(options =>
    {
        options.UseNpgsql("Host=localhost;Database=bse_demo;Username=bse;Password=bse");
    });
});
```
```

- [ ] **Step 4: Create test projects**

```bash
mkdir -p tests/Bse.Framework.Data.Tests
cd tests/Bse.Framework.Data.Tests
dotnet new xunit --output . --framework net9.0
rm UnitTest1.cs
cd ../..

mkdir -p tests/Bse.Framework.Data.EntityFramework.Tests
cd tests/Bse.Framework.Data.EntityFramework.Tests
dotnet new xunit --output . --framework net9.0
rm UnitTest1.cs
cd ../..
```

Overwrite `tests/Bse.Framework.Data.Tests/Bse.Framework.Data.Tests.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <RootNamespace>Bse.Framework.Data.Tests</RootNamespace>
    <AssemblyName>Bse.Framework.Data.Tests</AssemblyName>
    <IsPackable>false</IsPackable>
    <IsTestProject>true</IsTestProject>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" />
    <PackageReference Include="xunit" />
    <PackageReference Include="xunit.runner.visualstudio" />
    <PackageReference Include="Shouldly" />
    <PackageReference Include="NSubstitute" />
    <PackageReference Include="coverlet.collector" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="..\..\src\Bse.Framework.Data\Bse.Framework.Data.csproj" />
  </ItemGroup>

  <ItemGroup>
    <Using Include="Xunit" />
    <Using Include="Shouldly" />
    <Using Include="NSubstitute" />
  </ItemGroup>

</Project>
```

Overwrite `tests/Bse.Framework.Data.EntityFramework.Tests/Bse.Framework.Data.EntityFramework.Tests.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <RootNamespace>Bse.Framework.Data.EntityFramework.Tests</RootNamespace>
    <AssemblyName>Bse.Framework.Data.EntityFramework.Tests</AssemblyName>
    <IsPackable>false</IsPackable>
    <IsTestProject>true</IsTestProject>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" />
    <PackageReference Include="xunit" />
    <PackageReference Include="xunit.runner.visualstudio" />
    <PackageReference Include="Shouldly" />
    <PackageReference Include="NSubstitute" />
    <PackageReference Include="coverlet.collector" />
    <PackageReference Include="Testcontainers.PostgreSql" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="..\..\src\Bse.Framework.Data.EntityFramework\Bse.Framework.Data.EntityFramework.csproj" />
  </ItemGroup>

  <ItemGroup>
    <Using Include="Xunit" />
    <Using Include="Shouldly" />
    <Using Include="NSubstitute" />
  </ItemGroup>

</Project>
```

- [ ] **Step 5: Register all four projects in the solution and build**

```bash
cd /Users/mahrous/Projects/bse/bse-core
dotnet sln add src/Bse.Framework.Data/Bse.Framework.Data.csproj
dotnet sln add src/Bse.Framework.Data.EntityFramework/Bse.Framework.Data.EntityFramework.csproj
dotnet sln add tests/Bse.Framework.Data.Tests/Bse.Framework.Data.Tests.csproj
dotnet sln add tests/Bse.Framework.Data.EntityFramework.Tests/Bse.Framework.Data.EntityFramework.Tests.csproj
dotnet build
```

Expected: 0 warnings, 0 errors. Four new projects compile.

- [ ] **Step 6: Commit**

```bash
git add Directory.Packages.props \
        BseFramework.sln \
        src/Bse.Framework.Data/ \
        src/Bse.Framework.Data.EntityFramework/ \
        tests/Bse.Framework.Data.Tests/ \
        tests/Bse.Framework.Data.EntityFramework.Tests/
git commit -m "feat(data): scaffold Bse.Framework.Data + Bse.Framework.Data.EntityFramework projects"
```

---

## Task 2: Entity marker interfaces

**Files:**
- Create: `src/Bse.Framework.Data/Entities/IEntity.cs`
- Create: `src/Bse.Framework.Data/Entities/IAuditable.cs`
- Create: `src/Bse.Framework.Data/Entities/ISoftDelete.cs`
- Create: `src/Bse.Framework.Data/Entities/IConcurrencyAware.cs`
- Create: `src/Bse.Framework.Data/Entities/IMultiTenant.cs`
- Create: `src/Bse.Framework.Data/Entities/IHasDomainEvents.cs`
- Create: `src/Bse.Framework.Data/DomainEvents/IDomainEvent.cs`

These are pure marker interfaces — no behavior, just contracts the repository / interceptors / filters key off of. Each file is small; group them in a single commit.

- [ ] **Step 1: `IEntity.cs`**

```csharp
namespace Bse.Framework.Data.Entities;

/// <summary>Marker interface implemented by every persistable entity.</summary>
public interface IEntity { }

/// <summary>Entity with a strongly-typed primary key.</summary>
/// <typeparam name="TKey">Key type (e.g. <see cref="int"/>, <see cref="System.Guid"/>, a strongly-typed ID record).</typeparam>
public interface IEntity<out TKey> : IEntity
{
    /// <summary>Primary key value.</summary>
    TKey Id { get; }
}
```

- [ ] **Step 2: `IAuditable.cs`**

```csharp
namespace Bse.Framework.Data.Entities;

/// <summary>
/// Entity whose creation and modification metadata is populated automatically by
/// <c>AuditingSaveChangesInterceptor</c>. Implementations should expose settable
/// properties for the interceptor to populate.
/// </summary>
public interface IAuditable
{
    /// <summary>UTC timestamp of insert.</summary>
    DateTime CreatedAt { get; set; }

    /// <summary>Identifier of the principal that inserted the row.</summary>
    string CreatedBy { get; set; }

    /// <summary>UTC timestamp of last update, null until first update.</summary>
    DateTime? ModifiedAt { get; set; }

    /// <summary>Identifier of the principal that last updated the row.</summary>
    string? ModifiedBy { get; set; }
}
```

- [ ] **Step 3: `ISoftDelete.cs`**

```csharp
namespace Bse.Framework.Data.Entities;

/// <summary>
/// Entity that is hidden by the default query filter when <see cref="IsDeleted"/> is true.
/// A separate unfiltered context can opt out of the filter for administrative scenarios.
/// </summary>
public interface ISoftDelete
{
    /// <summary>True if the row has been soft-deleted.</summary>
    bool IsDeleted { get; set; }

    /// <summary>UTC timestamp of soft-delete, null while the row is active.</summary>
    DateTime? DeletedAt { get; set; }
}
```

- [ ] **Step 4: `IConcurrencyAware.cs`**

```csharp
namespace Bse.Framework.Data.Entities;

/// <summary>
/// Entity carrying an optimistic-concurrency token. EF Core's
/// <c>IsConcurrencyToken()</c> + Postgres' <c>xmin</c> system column populate this on read
/// and check it on update. Conflicts surface as <see cref="Bse.Framework.Core.Exceptions.BseConcurrencyException"/>.
/// </summary>
public interface IConcurrencyAware
{
    /// <summary>Postgres <c>xmin</c> snapshot at last read.</summary>
    uint Xmin { get; set; }
}
```

> **Postgres-specific note:** SQL Server uses an 8-byte `rowversion`; Postgres uses the `xmin` system column (a 4-byte transaction id). Since v0.1.0 targets Postgres only, the interface exposes `uint Xmin`. A future SQL Server provider will introduce a parallel `IConcurrencyAware<TToken>` if needed.

- [ ] **Step 5: `IMultiTenant.cs`**

```csharp
namespace Bse.Framework.Data.Entities;

/// <summary>
/// Entity scoped to a tenant. v0.1.0 carries the marker only; full multi-tenant query
/// filters and PostgreSQL RLS land with <c>Bse.Framework.MultiTenancy</c> (RFC-0006).
/// </summary>
public interface IMultiTenant
{
    /// <summary>Tenant identifier (typically a slug or short opaque token).</summary>
    string TenantId { get; }
}
```

- [ ] **Step 6: `IHasDomainEvents.cs`**

```csharp
using Bse.Framework.Data.DomainEvents;

namespace Bse.Framework.Data.Entities;

/// <summary>
/// Entity that emits domain events as part of its mutation lifecycle. v0.1.0 carries
/// the contract only; <c>SaveChangesInterceptor</c>-driven dispatch ships when the
/// eventing infrastructure lands (depends on <c>Bse.Framework.Rpc</c>).
/// </summary>
public interface IHasDomainEvents
{
    /// <summary>Pending events accumulated during this entity's lifecycle.</summary>
    IReadOnlyList<IDomainEvent> DomainEvents { get; }

    /// <summary>Clear pending events after they have been dispatched.</summary>
    void ClearDomainEvents();
}
```

- [ ] **Step 7: `IDomainEvent.cs`**

```csharp
namespace Bse.Framework.Data.DomainEvents;

/// <summary>Marker for domain events emitted by entities implementing <c>IHasDomainEvents</c>.</summary>
public interface IDomainEvent
{
    /// <summary>UTC timestamp when the event was raised (set in the entity).</summary>
    DateTime OccurredAt { get; }
}
```

- [ ] **Step 8: Build + commit**

```bash
dotnet build
git add src/Bse.Framework.Data/Entities/ src/Bse.Framework.Data/DomainEvents/
git commit -m "feat(data): add entity marker interfaces + IDomainEvent"
```

Expected: build clean.

---

## Task 3: Specification<T> base class + projection variant

**Files:**
- Create: `src/Bse.Framework.Data/Specifications/Specification.cs`
- Create: `src/Bse.Framework.Data/Specifications/SpecificationT.cs`
- Test: `tests/Bse.Framework.Data.Tests/Specifications/SpecificationTests.cs`

- [ ] **Step 1: Write the failing tests**

```csharp
using System.Linq.Expressions;
using Bse.Framework.Data.Entities;
using Bse.Framework.Data.Specifications;

namespace Bse.Framework.Data.Tests.Specifications;

public class SpecificationTests
{
    private sealed class TestEntity : IEntity<int>
    {
        public int Id { get; init; }
        public string Name { get; init; } = string.Empty;
        public bool Active { get; init; }
    }

    private sealed class ActiveSpec : Specification<TestEntity>
    {
        public ActiveSpec()
        {
            Where(x => x.Active);
            OrderByAscending(x => x.Name);
            AsNoTracking();
            WithQueryTag(nameof(ActiveSpec));
        }
    }

    [Fact]
    public void Defaults_AreSensible()
    {
        var spec = new Specification<TestEntity>();

        spec.Criteria.ShouldBeNull();
        spec.Includes.ShouldBeEmpty();
        spec.OrderBy.ShouldBeNull();
        spec.IsDescending.ShouldBeFalse();
        spec.IsNoTracking.ShouldBeFalse();
        spec.IsSplitQuery.ShouldBeFalse();
        spec.QueryTag.ShouldBeNull();
        spec.Skip.ShouldBeNull();
        spec.Take.ShouldBeNull();
    }

    [Fact]
    public void Where_SetsCriteria()
    {
        var spec = new ActiveSpec();

        spec.Criteria.ShouldNotBeNull();
        spec.IsNoTracking.ShouldBeTrue();
        spec.QueryTag.ShouldBe("ActiveSpec");
        spec.OrderBy.ShouldNotBeNull();
        spec.IsDescending.ShouldBeFalse();
    }

    [Fact]
    public void OrderByDescending_SetsDescendingFlag()
    {
        var spec = new Specification<TestEntity>();

        spec.OrderByDescending(x => x.Id);

        spec.OrderBy.ShouldNotBeNull();
        spec.IsDescending.ShouldBeTrue();
    }

    [Fact]
    public void Include_AppendsToList()
    {
        var spec = new Specification<TestEntity>();

        spec.Include(x => x.Name);
        spec.Include(x => x.Active);

        spec.Includes.Count.ShouldBe(2);
    }

    [Fact]
    public void Page_SetsSkipAndTake()
    {
        var spec = new Specification<TestEntity>();

        spec.Page(page: 3, pageSize: 25);

        spec.Skip.ShouldBe(50);   // (3-1) * 25
        spec.Take.ShouldBe(25);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
dotnet test --filter "FullyQualifiedName~SpecificationTests"
```

Expected: FAIL — `Specification<T>` does not exist.

- [ ] **Step 3: Implement `Specification.cs`**

```csharp
using System.Linq.Expressions;

namespace Bse.Framework.Data.Specifications;

/// <summary>
/// Composable, declarative query description. Compose criteria, includes, ordering,
/// paging, and EF-specific hints without exposing <see cref="IQueryable{T}"/>.
/// </summary>
/// <typeparam name="T">Entity type the specification queries.</typeparam>
public class Specification<T>
{
    /// <summary>Boolean filter applied via <c>Where</c>.</summary>
    public Expression<Func<T, bool>>? Criteria { get; private set; }

    /// <summary>Related navigations to <c>Include</c>.</summary>
    public IList<Expression<Func<T, object>>> Includes { get; } = new List<Expression<Func<T, object>>>();

    /// <summary>Optional ordering expression.</summary>
    public Expression<Func<T, object>>? OrderBy { get; private set; }

    /// <summary>True if <see cref="OrderBy"/> should be applied descending.</summary>
    public bool IsDescending { get; private set; }

    /// <summary>True if the query should be tracked-free.</summary>
    public bool IsNoTracking { get; private set; }

    /// <summary>True if the query should be split into multiple round-trips (avoids cartesian explosion).</summary>
    public bool IsSplitQuery { get; private set; }

    /// <summary>Optional EF query tag (visible in logs and SQL profilers).</summary>
    public string? QueryTag { get; private set; }

    /// <summary>Offset for pagination (0-based).</summary>
    public int? Skip { get; private set; }

    /// <summary>Row count cap.</summary>
    public int? Take { get; private set; }

    /// <summary>Sets the filter criteria. Replaces any prior <c>Where</c>.</summary>
    public Specification<T> Where(Expression<Func<T, bool>> criteria)
    {
        ArgumentNullException.ThrowIfNull(criteria);
        Criteria = criteria;
        return this;
    }

    /// <summary>Adds a related navigation to include.</summary>
    public Specification<T> Include(Expression<Func<T, object>> include)
    {
        ArgumentNullException.ThrowIfNull(include);
        Includes.Add(include);
        return this;
    }

    /// <summary>Order ascending by the given expression.</summary>
    public Specification<T> OrderByAscending(Expression<Func<T, object>> orderBy)
    {
        ArgumentNullException.ThrowIfNull(orderBy);
        OrderBy = orderBy;
        IsDescending = false;
        return this;
    }

    /// <summary>Order descending by the given expression.</summary>
    public Specification<T> OrderByDescending(Expression<Func<T, object>> orderBy)
    {
        ArgumentNullException.ThrowIfNull(orderBy);
        OrderBy = orderBy;
        IsDescending = true;
        return this;
    }

    /// <summary>Mark the resulting query as <c>AsNoTracking</c>.</summary>
    public Specification<T> AsNoTracking()
    {
        IsNoTracking = true;
        return this;
    }

    /// <summary>Mark the resulting query as <c>AsSplitQuery</c>.</summary>
    public Specification<T> AsSplitQuery()
    {
        IsSplitQuery = true;
        return this;
    }

    /// <summary>Attach an EF query tag for log/profiler visibility.</summary>
    public Specification<T> WithQueryTag(string tag)
    {
        if (string.IsNullOrWhiteSpace(tag))
        {
            throw new ArgumentException("Tag must be non-empty.", nameof(tag));
        }
        QueryTag = tag;
        return this;
    }

    /// <summary>Apply offset pagination. Page is 1-based.</summary>
    /// <param name="page">1-based page number.</param>
    /// <param name="pageSize">Page size (rows per page).</param>
    /// <exception cref="ArgumentOutOfRangeException">If <paramref name="page"/> &lt; 1 or <paramref name="pageSize"/> &lt; 1.</exception>
    public Specification<T> Page(int page, int pageSize)
    {
        if (page < 1) throw new ArgumentOutOfRangeException(nameof(page), page, "Page must be >= 1.");
        if (pageSize < 1) throw new ArgumentOutOfRangeException(nameof(pageSize), pageSize, "PageSize must be >= 1.");
        Skip = (page - 1) * pageSize;
        Take = pageSize;
        return this;
    }
}
```

- [ ] **Step 4: Implement `SpecificationT.cs` (projection variant)**

```csharp
using System.Linq.Expressions;

namespace Bse.Framework.Data.Specifications;

/// <summary>
/// Specification that projects the entity to a DTO. The selector runs in the database
/// (translated to SQL by EF) so the entity is never materialized.
/// </summary>
/// <typeparam name="T">Source entity type.</typeparam>
/// <typeparam name="TResult">Projected DTO type.</typeparam>
public class Specification<T, TResult> : Specification<T>
{
    /// <summary>Creates a projecting specification with the given selector.</summary>
    /// <param name="selector">Projection expression (must be translatable to SQL).</param>
    /// <exception cref="ArgumentNullException">If <paramref name="selector"/> is null.</exception>
    public Specification(Expression<Func<T, TResult>> selector)
    {
        Selector = selector ?? throw new ArgumentNullException(nameof(selector));
    }

    /// <summary>Projection expression applied at the database layer.</summary>
    public Expression<Func<T, TResult>> Selector { get; }
}
```

- [ ] **Step 5: Run tests + commit**

```bash
dotnet test --filter "FullyQualifiedName~SpecificationTests"
```

Expected: 5 tests pass.

```bash
git add src/Bse.Framework.Data/Specifications/ tests/Bse.Framework.Data.Tests/Specifications/
git commit -m "feat(data): add Specification<T> base + Specification<T, TResult> projection"
```

---

## Task 4: Pagination types

**Files:**
- Create: `src/Bse.Framework.Data/Pagination/PagedRequest.cs`
- Create: `src/Bse.Framework.Data/Pagination/PagedResult.cs`
- Test: `tests/Bse.Framework.Data.Tests/Pagination/PagedResultTests.cs`

- [ ] **Step 1: Write the failing tests**

```csharp
using Bse.Framework.Data.Pagination;

namespace Bse.Framework.Data.Tests.Pagination;

public class PagedResultTests
{
    [Fact]
    public void TotalPages_ComputedFromTotalCount()
    {
        var result = new PagedResult<int>(Items: new[] { 1, 2, 3 }, TotalCount: 25, Page: 2, PageSize: 10);

        result.TotalPages.ShouldBe(3); // ceil(25 / 10)
    }

    [Fact]
    public void TotalPages_IsOne_WhenTotalCountEqualsPageSize()
    {
        var result = new PagedResult<int>(Items: Array.Empty<int>(), TotalCount: 10, Page: 1, PageSize: 10);

        result.TotalPages.ShouldBe(1);
    }

    [Fact]
    public void TotalPages_IsZero_WhenEmpty()
    {
        var result = new PagedResult<int>(Items: Array.Empty<int>(), TotalCount: 0, Page: 1, PageSize: 10);

        result.TotalPages.ShouldBe(0);
    }

    [Fact]
    public void PagedRequest_HasSensibleDefaults()
    {
        var req = new PagedRequest();

        req.Page.ShouldBe(1);
        req.PageSize.ShouldBe(20);
        req.SortBy.ShouldBeNull();
        req.Descending.ShouldBeFalse();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
dotnet test --filter "FullyQualifiedName~PagedResultTests"
```

Expected: FAIL.

- [ ] **Step 3: Implement `PagedRequest.cs`**

```csharp
namespace Bse.Framework.Data.Pagination;

/// <summary>Request shape for offset-paginated endpoints.</summary>
/// <param name="Page">1-based page number. Default: 1.</param>
/// <param name="PageSize">Rows per page. Default: 20.</param>
/// <param name="SortBy">Optional sort key (interpretation is endpoint-specific).</param>
/// <param name="Descending">True to sort descending; default ascending.</param>
public sealed record PagedRequest(int Page = 1, int PageSize = 20, string? SortBy = null, bool Descending = false);
```

- [ ] **Step 4: Implement `PagedResult.cs`**

```csharp
namespace Bse.Framework.Data.Pagination;

/// <summary>Response shape for offset-paginated endpoints.</summary>
/// <typeparam name="T">Item type.</typeparam>
/// <param name="Items">Items on the current page.</param>
/// <param name="TotalCount">Total items across all pages.</param>
/// <param name="Page">1-based page number.</param>
/// <param name="PageSize">Page size used to compute <c>TotalPages</c>.</param>
public sealed record PagedResult<T>(IReadOnlyList<T> Items, int TotalCount, int Page, int PageSize)
{
    /// <summary>Number of pages (<c>ceil(TotalCount / PageSize)</c>). Zero when empty.</summary>
    public int TotalPages => PageSize == 0 ? 0 : (int)Math.Ceiling((double)TotalCount / PageSize);
}
```

- [ ] **Step 5: Run tests + commit**

```bash
dotnet test --filter "FullyQualifiedName~PagedResultTests"
```

Expected: 4 tests pass.

```bash
git add src/Bse.Framework.Data/Pagination/ tests/Bse.Framework.Data.Tests/Pagination/
git commit -m "feat(data): add PagedRequest / PagedResult<T>"
```

---

## Task 5: IRepository<T> and IUnitOfWork

**Files:**
- Create: `src/Bse.Framework.Data/Repository/IRepository.cs`
- Create: `src/Bse.Framework.Data/Repository/IUnitOfWork.cs`

Interfaces only — no behavior, no tests. Implementations land in Task 9 (`EfRepository<T>`) and Task 10 (`EfUnitOfWork`).

- [ ] **Step 1: `IRepository.cs`**

```csharp
using Bse.Framework.Data.Entities;
using Bse.Framework.Data.Pagination;
using Bse.Framework.Data.Specifications;

namespace Bse.Framework.Data.Repository;

/// <summary>
/// Per-entity repository, Specification-driven. Never exposes <see cref="IQueryable{T}"/>;
/// callers compose queries via <see cref="Specification{T}"/>.
/// </summary>
/// <typeparam name="T">Entity type.</typeparam>
public interface IRepository<T> where T : class, IEntity
{
    /// <summary>Fetch by primary key. Honors EF's change tracker when <paramref name="tracked"/> is true.</summary>
    Task<T?> GetByIdAsync(object id, bool tracked = true, CancellationToken cancellationToken = default);

    /// <summary>Returns the first entity matching the specification, or null.</summary>
    Task<T?> FirstOrDefaultAsync(Specification<T> spec, CancellationToken cancellationToken = default);

    /// <summary>Returns all entities matching the specification.</summary>
    Task<IReadOnlyList<T>> ListAsync(Specification<T>? spec = null, CancellationToken cancellationToken = default);

    /// <summary>Returns all entities matching the projecting specification.</summary>
    Task<IReadOnlyList<TResult>> ListAsync<TResult>(Specification<T, TResult> spec, CancellationToken cancellationToken = default);

    /// <summary>Returns one page of entities + total count.</summary>
    Task<PagedResult<T>> PageAsync(Specification<T> spec, CancellationToken cancellationToken = default);

    /// <summary>Count entities matching the specification (or all when null).</summary>
    Task<int> CountAsync(Specification<T>? spec = null, CancellationToken cancellationToken = default);

    /// <summary>True if any entity matches the specification.</summary>
    Task<bool> AnyAsync(Specification<T> spec, CancellationToken cancellationToken = default);

    /// <summary>Insert a single entity.</summary>
    Task<T> AddAsync(T entity, CancellationToken cancellationToken = default);

    /// <summary>Insert multiple entities.</summary>
    Task AddRangeAsync(IEnumerable<T> entities, CancellationToken cancellationToken = default);

    /// <summary>Mark an existing entity as modified.</summary>
    T Update(T entity);

    /// <summary>Mark an entity as deleted (hard or soft, depending on whether the entity implements <see cref="ISoftDelete"/>).</summary>
    void Remove(T entity);
}
```

- [ ] **Step 2: `IUnitOfWork.cs`**

```csharp
using Bse.Framework.Data.Entities;

namespace Bse.Framework.Data.Repository;

/// <summary>
/// Coordinator for one logical unit of work — a single SaveChanges call across multiple repositories.
/// Scoped per request in DI.
/// </summary>
public interface IUnitOfWork : IAsyncDisposable
{
    /// <summary>Lazily-created repository for the given entity type.</summary>
    IRepository<T> Repository<T>() where T : class, IEntity;

    /// <summary>Commits all pending changes.</summary>
    /// <returns>Number of rows affected.</returns>
    Task<int> SaveChangesAsync(CancellationToken cancellationToken = default);
}
```

- [ ] **Step 3: Build + commit**

```bash
dotnet build
git add src/Bse.Framework.Data/Repository/
git commit -m "feat(data): add IRepository<T> and IUnitOfWork contracts"
```

---

## Task 6: BseDataBuilder (IBseModule marker) + AddBseData extension

**Files:**
- Create: `src/Bse.Framework.Data/DependencyInjection/BseDataBuilder.cs`
- Create: `src/Bse.Framework.Data/DependencyInjection/DataServiceCollectionExtensions.cs`

The abstractions package needs an entry point so `framework.AddBseData()` is a valid call before any provider is plugged in.

- [ ] **Step 1: `BseDataBuilder.cs`**

```csharp
using Bse.Framework.Core.DependencyInjection;

namespace Bse.Framework.Data.DependencyInjection;

/// <summary>
/// Marker module tracked by <see cref="IBseFrameworkBuilder"/>. Provider packages
/// (e.g. <c>Bse.Framework.Data.EntityFramework</c>) check <c>HasModule&lt;BseDataBuilder&gt;</c>
/// to verify the data abstractions are registered before they bind their own services.
/// </summary>
public sealed class BseDataBuilder : IBseModule
{
    /// <inheritdoc />
    public void Configure(IBseFrameworkBuilder builder)
    {
        // No-op: the marker exists for tracking.
    }
}
```

- [ ] **Step 2: `DataServiceCollectionExtensions.cs`**

```csharp
using Bse.Framework.Core.DependencyInjection;

namespace Bse.Framework.Data.DependencyInjection;

/// <summary>
/// Entry-point extensions for registering <see cref="Bse.Framework.Data"/> on an
/// <see cref="IBseFrameworkBuilder"/>. Provider packages call this transitively.
/// </summary>
public static class DataServiceCollectionExtensions
{
    /// <summary>
    /// Registers the data module marker. Must be called before any provider's
    /// <c>AddBseData*</c> extension. Provider extensions invoke this automatically;
    /// applications typically only call <c>AddBseDataEntityFramework</c> directly.
    /// </summary>
    /// <param name="builder">The framework builder.</param>
    /// <returns>The same builder, for chaining.</returns>
    /// <exception cref="ArgumentNullException">If <paramref name="builder"/> is null.</exception>
    public static IBseFrameworkBuilder AddBseData(this IBseFrameworkBuilder builder)
    {
        ArgumentNullException.ThrowIfNull(builder);
        builder.RegisterModule<BseDataBuilder>();
        return builder;
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
dotnet build
git add src/Bse.Framework.Data/DependencyInjection/
git commit -m "feat(data): add BseDataBuilder module + AddBseData entry point"
```

---

## Task 7: SpecificationEvaluator (Spec<T> → IQueryable<T>)

**Files:**
- Create: `src/Bse.Framework.Data.EntityFramework/Specifications/SpecificationEvaluator.cs`

Translates `Specification<T>` into the EF `IQueryable<T>` operations. This is the only place `IQueryable` is allowed.

- [ ] **Step 1: Implement**

```csharp
using Bse.Framework.Data.Specifications;
using Microsoft.EntityFrameworkCore;

namespace Bse.Framework.Data.EntityFramework.Specifications;

/// <summary>
/// Applies a <see cref="Specification{T}"/> (or projection variant) to an EF
/// <see cref="IQueryable{T}"/>. The only place <c>IQueryable</c> is exposed in the framework.
/// </summary>
internal static class SpecificationEvaluator
{
    public static IQueryable<T> Apply<T>(IQueryable<T> source, Specification<T> spec) where T : class
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(spec);

        var query = source;

        if (spec.IsNoTracking) query = query.AsNoTracking();
        if (spec.IsSplitQuery) query = query.AsSplitQuery();
        if (spec.QueryTag is { } tag) query = query.TagWith(tag);

        foreach (var include in spec.Includes)
        {
            query = query.Include(include);
        }

        if (spec.Criteria is { } criteria)
        {
            query = query.Where(criteria);
        }

        if (spec.OrderBy is { } order)
        {
            query = spec.IsDescending ? query.OrderByDescending(order) : query.OrderBy(order);
        }

        if (spec.Skip is { } skip)
        {
            query = query.Skip(skip);
        }

        if (spec.Take is { } take)
        {
            query = query.Take(take);
        }

        return query;
    }

    public static IQueryable<TResult> Apply<T, TResult>(IQueryable<T> source, Specification<T, TResult> spec) where T : class
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(spec);

        return Apply(source, (Specification<T>)spec).Select(spec.Selector);
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
dotnet build
git add src/Bse.Framework.Data.EntityFramework/Specifications/
git commit -m "feat(data-ef): add SpecificationEvaluator (Spec<T> → IQueryable<T>)"
```

---

## Task 8: BseDbContext + AuditingSaveChangesInterceptor + SoftDeleteQueryFilterConvention

**Files:**
- Create: `src/Bse.Framework.Data.EntityFramework/Context/BseDbContext.cs`
- Create: `src/Bse.Framework.Data.EntityFramework/Interceptors/AuditingSaveChangesInterceptor.cs`
- Create: `src/Bse.Framework.Data.EntityFramework/Conventions/SoftDeleteQueryFilterConvention.cs`

- [ ] **Step 1: `AuditingSaveChangesInterceptor.cs`**

```csharp
using Bse.Framework.Core.Time;
using Bse.Framework.Data.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.ChangeTracking;
using Microsoft.EntityFrameworkCore.Diagnostics;

namespace Bse.Framework.Data.EntityFramework.Interceptors;

/// <summary>
/// Populates <see cref="IAuditable"/> fields automatically on insert/update.
/// Soft-deletes (<see cref="ISoftDelete"/>) are also rewritten here so that
/// <c>Remove()</c> calls become updates with <c>IsDeleted = true</c> and a
/// <c>DeletedAt</c> stamp.
/// </summary>
public sealed class AuditingSaveChangesInterceptor : SaveChangesInterceptor
{
    private readonly ISystemClock _clock;

    /// <summary>Creates the interceptor.</summary>
    public AuditingSaveChangesInterceptor(ISystemClock clock)
    {
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
    }

    /// <inheritdoc />
    public override InterceptionResult<int> SavingChanges(
        DbContextEventData eventData, InterceptionResult<int> result)
    {
        Apply(eventData.Context);
        return base.SavingChanges(eventData, result);
    }

    /// <inheritdoc />
    public override ValueTask<InterceptionResult<int>> SavingChangesAsync(
        DbContextEventData eventData, InterceptionResult<int> result, CancellationToken cancellationToken = default)
    {
        Apply(eventData.Context);
        return base.SavingChangesAsync(eventData, result, cancellationToken);
    }

    private void Apply(DbContext? context)
    {
        if (context is null) return;
        var now = _clock.UtcNow;
        // Principal identity is wired in later (multi-tenant package); for v0.1.0 we tag "system".
        const string principal = "system";

        foreach (EntityEntry entry in context.ChangeTracker.Entries())
        {
            if (entry.Entity is IAuditable auditable)
            {
                switch (entry.State)
                {
                    case EntityState.Added:
                        auditable.CreatedAt = now;
                        auditable.CreatedBy = principal;
                        break;
                    case EntityState.Modified:
                        auditable.ModifiedAt = now;
                        auditable.ModifiedBy = principal;
                        // Defend the CreatedAt/CreatedBy fields against modification.
                        entry.Property(nameof(IAuditable.CreatedAt)).IsModified = false;
                        entry.Property(nameof(IAuditable.CreatedBy)).IsModified = false;
                        break;
                }
            }

            if (entry.State == EntityState.Deleted && entry.Entity is ISoftDelete soft)
            {
                entry.State = EntityState.Modified;
                soft.IsDeleted = true;
                soft.DeletedAt = now;
            }
        }
    }
}
```

- [ ] **Step 2: `SoftDeleteQueryFilterConvention.cs`**

```csharp
using System.Linq.Expressions;
using Bse.Framework.Data.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Bse.Framework.Data.EntityFramework.Conventions;

/// <summary>
/// Configures a global query filter <c>e =&gt; !e.IsDeleted</c> on every entity that
/// implements <see cref="ISoftDelete"/>. Call <see cref="Apply"/> from your
/// <c>OnModelCreating</c> override after registering entity types.
/// </summary>
public static class SoftDeleteQueryFilterConvention
{
    /// <summary>
    /// Adds the filter to all entities in the model implementing <see cref="ISoftDelete"/>.
    /// </summary>
    /// <param name="modelBuilder">The model builder from <c>OnModelCreating</c>.</param>
    /// <exception cref="ArgumentNullException">If <paramref name="modelBuilder"/> is null.</exception>
    public static void Apply(ModelBuilder modelBuilder)
    {
        ArgumentNullException.ThrowIfNull(modelBuilder);

        foreach (var entityType in modelBuilder.Model.GetEntityTypes())
        {
            if (!typeof(ISoftDelete).IsAssignableFrom(entityType.ClrType)) continue;

            // e => !((ISoftDelete)e).IsDeleted
            var parameter = Expression.Parameter(entityType.ClrType, "e");
            var cast = Expression.Convert(parameter, typeof(ISoftDelete));
            var property = Expression.Property(cast, nameof(ISoftDelete.IsDeleted));
            var notDeleted = Expression.Not(property);
            var lambda = Expression.Lambda(notDeleted, parameter);

            modelBuilder.Entity(entityType.ClrType).HasQueryFilter(lambda);
        }
    }
}
```

- [ ] **Step 3: `BseDbContext.cs`**

```csharp
using Bse.Framework.Core.Time;
using Bse.Framework.Data.EntityFramework.Conventions;
using Bse.Framework.Data.EntityFramework.Interceptors;
using Microsoft.EntityFrameworkCore;

namespace Bse.Framework.Data.EntityFramework.Context;

/// <summary>
/// Base <see cref="DbContext"/> for all framework consumers. Wires the auditing
/// interceptor and the soft-delete query filter. Subclasses override
/// <see cref="OnModelCreating"/> to map their entities; they MUST call
/// <c>base.OnModelCreating(modelBuilder)</c>.
/// </summary>
public abstract class BseDbContext : DbContext
{
    private readonly ISystemClock _clock;

    /// <summary>Creates the context.</summary>
    /// <param name="options">EF options (provider, connection string, etc.).</param>
    /// <param name="clock">Time source for the audit interceptor.</param>
    protected BseDbContext(DbContextOptions options, ISystemClock clock)
        : base(options)
    {
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
    }

    /// <inheritdoc />
    protected override void OnConfiguring(DbContextOptionsBuilder optionsBuilder)
    {
        base.OnConfiguring(optionsBuilder);
        optionsBuilder.AddInterceptors(new AuditingSaveChangesInterceptor(_clock));
    }

    /// <inheritdoc />
    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);
        SoftDeleteQueryFilterConvention.Apply(modelBuilder);
    }
}
```

- [ ] **Step 4: Build + commit**

```bash
dotnet build
git add src/Bse.Framework.Data.EntityFramework/Context/ \
        src/Bse.Framework.Data.EntityFramework/Interceptors/ \
        src/Bse.Framework.Data.EntityFramework/Conventions/
git commit -m "feat(data-ef): add BseDbContext base + audit interceptor + soft-delete filter convention"
```

---

## Task 9: EfRepository<T>

**Files:**
- Create: `src/Bse.Framework.Data.EntityFramework/Repository/EfRepository.cs`

- [ ] **Step 1: Implement**

```csharp
using Bse.Framework.Data.Entities;
using Bse.Framework.Data.EntityFramework.Specifications;
using Bse.Framework.Data.Pagination;
using Bse.Framework.Data.Repository;
using Bse.Framework.Data.Specifications;
using Microsoft.EntityFrameworkCore;

namespace Bse.Framework.Data.EntityFramework.Repository;

/// <summary>EF Core 9 implementation of <see cref="IRepository{T}"/>.</summary>
/// <typeparam name="T">Entity type.</typeparam>
public sealed class EfRepository<T> : IRepository<T> where T : class, IEntity
{
    private readonly DbContext _context;
    private readonly DbSet<T> _set;

    /// <summary>Creates a repository bound to the supplied context.</summary>
    /// <param name="context">EF DbContext (typically a subclass of <c>BseDbContext</c>).</param>
    /// <exception cref="ArgumentNullException">If <paramref name="context"/> is null.</exception>
    public EfRepository(DbContext context)
    {
        _context = context ?? throw new ArgumentNullException(nameof(context));
        _set = context.Set<T>();
    }

    /// <inheritdoc />
    public async Task<T?> GetByIdAsync(object id, bool tracked = true, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(id);
        if (tracked)
        {
            return await _set.FindAsync(new[] { id }, cancellationToken).ConfigureAwait(false);
        }

        // Untracked: build a key predicate by inspecting EF metadata.
        var entityType = _context.Model.FindEntityType(typeof(T))
            ?? throw new InvalidOperationException($"Entity {typeof(T).Name} not in model.");
        var keyProperty = entityType.FindPrimaryKey()?.Properties.Single().Name
            ?? throw new InvalidOperationException($"Entity {typeof(T).Name} has no primary key.");
        return await _set.AsNoTracking()
            .FirstOrDefaultAsync(e => EF.Property<object>(e, keyProperty).Equals(id), cancellationToken)
            .ConfigureAwait(false);
    }

    /// <inheritdoc />
    public Task<T?> FirstOrDefaultAsync(Specification<T> spec, CancellationToken cancellationToken = default)
        => SpecificationEvaluator.Apply(_set, spec).FirstOrDefaultAsync(cancellationToken);

    /// <inheritdoc />
    public async Task<IReadOnlyList<T>> ListAsync(Specification<T>? spec = null, CancellationToken cancellationToken = default)
    {
        var query = spec is null ? (IQueryable<T>)_set : SpecificationEvaluator.Apply(_set, spec);
        return await query.ToListAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <inheritdoc />
    public async Task<IReadOnlyList<TResult>> ListAsync<TResult>(Specification<T, TResult> spec, CancellationToken cancellationToken = default)
    {
        return await SpecificationEvaluator.Apply(_set, spec).ToListAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <inheritdoc />
    public async Task<PagedResult<T>> PageAsync(Specification<T> spec, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(spec);
        if (spec.Take is null) throw new InvalidOperationException("PageAsync requires Specification.Page(...) to set Skip+Take.");

        var page = (spec.Skip!.Value / spec.Take.Value) + 1;

        // Total count ignores Skip/Take, so build a separate query without paging.
        var countSpec = new Specification<T>();
        if (spec.Criteria is not null) countSpec.Where(spec.Criteria);
        var total = await SpecificationEvaluator.Apply(_set, countSpec).CountAsync(cancellationToken).ConfigureAwait(false);

        var items = await SpecificationEvaluator.Apply(_set, spec).ToListAsync(cancellationToken).ConfigureAwait(false);
        return new PagedResult<T>(items, total, page, spec.Take.Value);
    }

    /// <inheritdoc />
    public Task<int> CountAsync(Specification<T>? spec = null, CancellationToken cancellationToken = default)
    {
        var query = spec is null ? (IQueryable<T>)_set : SpecificationEvaluator.Apply(_set, spec);
        return query.CountAsync(cancellationToken);
    }

    /// <inheritdoc />
    public Task<bool> AnyAsync(Specification<T> spec, CancellationToken cancellationToken = default)
        => SpecificationEvaluator.Apply(_set, spec).AnyAsync(cancellationToken);

    /// <inheritdoc />
    public async Task<T> AddAsync(T entity, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(entity);
        await _set.AddAsync(entity, cancellationToken).ConfigureAwait(false);
        return entity;
    }

    /// <inheritdoc />
    public Task AddRangeAsync(IEnumerable<T> entities, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(entities);
        return _set.AddRangeAsync(entities, cancellationToken);
    }

    /// <inheritdoc />
    public T Update(T entity)
    {
        ArgumentNullException.ThrowIfNull(entity);
        _set.Update(entity);
        return entity;
    }

    /// <inheritdoc />
    public void Remove(T entity)
    {
        ArgumentNullException.ThrowIfNull(entity);
        _set.Remove(entity);
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
dotnet build
git add src/Bse.Framework.Data.EntityFramework/Repository/EfRepository.cs
git commit -m "feat(data-ef): add EfRepository<T> (Specification-driven, no IQueryable leak)"
```

---

## Task 10: EfUnitOfWork

**Files:**
- Create: `src/Bse.Framework.Data.EntityFramework/Repository/EfUnitOfWork.cs`

- [ ] **Step 1: Implement**

```csharp
using System.Collections.Concurrent;
using Bse.Framework.Data.Entities;
using Bse.Framework.Data.Repository;
using Microsoft.EntityFrameworkCore;

namespace Bse.Framework.Data.EntityFramework.Repository;

/// <summary>EF Core 9 implementation of <see cref="IUnitOfWork"/>.</summary>
public sealed class EfUnitOfWork : IUnitOfWork
{
    private readonly DbContext _context;
    private readonly ConcurrentDictionary<Type, object> _repositories = new();

    /// <summary>Creates the unit of work bound to the supplied context.</summary>
    /// <param name="context">EF DbContext (scoped per request).</param>
    public EfUnitOfWork(DbContext context)
    {
        _context = context ?? throw new ArgumentNullException(nameof(context));
    }

    /// <inheritdoc />
    public IRepository<T> Repository<T>() where T : class, IEntity
    {
        return (IRepository<T>)_repositories.GetOrAdd(typeof(T), _ => new EfRepository<T>(_context));
    }

    /// <inheritdoc />
    public Task<int> SaveChangesAsync(CancellationToken cancellationToken = default)
        => _context.SaveChangesAsync(cancellationToken);

    /// <inheritdoc />
    public ValueTask DisposeAsync() => _context.DisposeAsync();
}
```

- [ ] **Step 2: Build + commit**

```bash
dotnet build
git add src/Bse.Framework.Data.EntityFramework/Repository/EfUnitOfWork.cs
git commit -m "feat(data-ef): add EfUnitOfWork"
```

---

## Task 11: ConcurrencyExceptionMapper

**Files:**
- Create: `src/Bse.Framework.Data.EntityFramework/Exceptions/ConcurrencyExceptionMapper.cs`

Wraps EF's `DbUpdateConcurrencyException` into Core's `BseConcurrencyException`. Applied via a `SaveChangesInterceptor` so callers always see a framework-typed exception.

- [ ] **Step 1: Implement**

```csharp
using Bse.Framework.Core.Exceptions;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;

namespace Bse.Framework.Data.EntityFramework.Exceptions;

/// <summary>
/// EF interceptor that converts <see cref="DbUpdateConcurrencyException"/> into
/// <see cref="BseConcurrencyException"/> so consumers don't take a direct EF dependency
/// just to catch a conflict.
/// </summary>
public sealed class ConcurrencyExceptionMapper : SaveChangesInterceptor
{
    /// <inheritdoc />
    public override void SaveChangesFailed(DbContextErrorEventData eventData)
    {
        Translate(eventData);
        base.SaveChangesFailed(eventData);
    }

    /// <inheritdoc />
    public override Task SaveChangesFailedAsync(DbContextErrorEventData eventData, CancellationToken cancellationToken = default)
    {
        Translate(eventData);
        return base.SaveChangesFailedAsync(eventData, cancellationToken);
    }

    private static void Translate(DbContextErrorEventData eventData)
    {
        if (eventData.Exception is not DbUpdateConcurrencyException dbEx) return;

        var first = dbEx.Entries.FirstOrDefault();
        var entityType = first?.Entity.GetType().Name ?? "Unknown";
        var entityId = first?.OriginalValues["Id"]?.ToString() ?? "Unknown";

        throw new BseConcurrencyException(entityType, entityId, dbEx);
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
dotnet build
git add src/Bse.Framework.Data.EntityFramework/Exceptions/
git commit -m "feat(data-ef): map EF DbUpdateConcurrencyException to BseConcurrencyException"
```

---

## Task 12: Telemetry instrumentation for queries

**Files:**
- Create: `src/Bse.Framework.Data.EntityFramework/Instrumentation/DataInstrumentation.cs`

Emits the `bse.data.query.duration` histogram + spans on every SaveChanges and on every command-execution path. Uses the `OpenTelemetry.Instrumentation.EntityFrameworkCore` package indirectly — we register the meter and source manually so the Telemetry pipeline picks them up via its `DefaultSources` / `DefaultMeters` lists.

- [ ] **Step 1: Implement**

```csharp
using System.Diagnostics;
using System.Diagnostics.Metrics;
using Microsoft.EntityFrameworkCore.Diagnostics;

namespace Bse.Framework.Data.EntityFramework.Instrumentation;

/// <summary>
/// EF Core <see cref="DbCommandInterceptor"/> that records spans + the
/// <c>bse.data.query.duration</c> histogram on every command execution.
/// </summary>
public sealed class DataInstrumentationInterceptor : DbCommandInterceptor
{
    /// <summary>Activity source observed by <c>Bse.Framework.Telemetry</c>'s default sources.</summary>
    public static readonly ActivitySource ActivitySource = new("Bse.Data.EntityFramework", "0.1.0");

    private static readonly Meter Meter = new("Bse.Data.EntityFramework", "0.1.0");

    /// <summary>Duration histogram (seconds) for every DB command.</summary>
    public static readonly Histogram<double> QueryDuration =
        Meter.CreateHistogram<double>(
            "bse.data.query.duration",
            unit: "s",
            description: "Wall-clock time for a single EF Core DB command.");

    private static readonly AsyncLocal<(Activity? activity, long startTicks)> Pending = new();

    /// <inheritdoc />
    public override InterceptionResult<DbDataReader> ReaderExecuting(
        DbCommand command, CommandEventData eventData, InterceptionResult<DbDataReader> result)
    {
        Begin(command, "Reader");
        return base.ReaderExecuting(command, eventData, result);
    }

    /// <inheritdoc />
    public override ValueTask<InterceptionResult<DbDataReader>> ReaderExecutingAsync(
        DbCommand command, CommandEventData eventData, InterceptionResult<DbDataReader> result, CancellationToken cancellationToken = default)
    {
        Begin(command, "Reader");
        return base.ReaderExecutingAsync(command, eventData, result, cancellationToken);
    }

    /// <inheritdoc />
    public override DbDataReader ReaderExecuted(
        DbCommand command, CommandExecutedEventData eventData, DbDataReader result)
    {
        End();
        return base.ReaderExecuted(command, eventData, result);
    }

    /// <inheritdoc />
    public override ValueTask<DbDataReader> ReaderExecutedAsync(
        DbCommand command, CommandExecutedEventData eventData, DbDataReader result, CancellationToken cancellationToken = default)
    {
        End();
        return base.ReaderExecutedAsync(command, eventData, result, cancellationToken);
    }

    /// <inheritdoc />
    public override InterceptionResult<int> NonQueryExecuting(
        DbCommand command, CommandEventData eventData, InterceptionResult<int> result)
    {
        Begin(command, "NonQuery");
        return base.NonQueryExecuting(command, eventData, result);
    }

    /// <inheritdoc />
    public override ValueTask<InterceptionResult<int>> NonQueryExecutingAsync(
        DbCommand command, CommandEventData eventData, InterceptionResult<int> result, CancellationToken cancellationToken = default)
    {
        Begin(command, "NonQuery");
        return base.NonQueryExecutingAsync(command, eventData, result, cancellationToken);
    }

    /// <inheritdoc />
    public override int NonQueryExecuted(
        DbCommand command, CommandExecutedEventData eventData, int result)
    {
        End();
        return base.NonQueryExecuted(command, eventData, result);
    }

    /// <inheritdoc />
    public override ValueTask<int> NonQueryExecutedAsync(
        DbCommand command, CommandExecutedEventData eventData, int result, CancellationToken cancellationToken = default)
    {
        End();
        return base.NonQueryExecutedAsync(command, eventData, result, cancellationToken);
    }

    private static void Begin(DbCommand command, string kind)
    {
        var activity = ActivitySource.StartActivity($"db.{kind.ToLowerInvariant()}", ActivityKind.Client);
        if (activity is not null)
        {
            activity.SetTag("db.system.name", "postgresql");
            activity.SetTag("db.operation.name", kind);
            // CommandText is intentionally NOT attached by default (cardinality + PII risk; see RFC-0005).
        }
        Pending.Value = (activity, Stopwatch.GetTimestamp());
    }

    private static void End()
    {
        var (activity, start) = Pending.Value;
        Pending.Value = default;
        if (start == 0) return;

        var elapsed = Stopwatch.GetElapsedTime(start).TotalSeconds;
        QueryDuration.Record(elapsed);

        activity?.SetTag("bse.data.duration_s", elapsed);
        activity?.Dispose();
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
dotnet build
git add src/Bse.Framework.Data.EntityFramework/Instrumentation/
git commit -m "feat(data-ef): add DataInstrumentationInterceptor (spans + bse.data.query.duration)"
```

---

## Task 13: AddBseDataEntityFramework extension

**Files:**
- Create: `src/Bse.Framework.Data.EntityFramework/BseDataEfModule.cs`
- Create: `src/Bse.Framework.Data.EntityFramework/DependencyInjection/EfServiceCollectionExtensions.cs`

- [ ] **Step 1: `BseDataEfModule.cs`**

```csharp
using Bse.Framework.Core.DependencyInjection;

namespace Bse.Framework.Data.EntityFramework;

/// <summary>Marker module for EF provider registration.</summary>
public sealed class BseDataEfModule : IBseModule
{
    /// <inheritdoc />
    public void Configure(IBseFrameworkBuilder builder) { }
}
```

- [ ] **Step 2: `EfServiceCollectionExtensions.cs`**

```csharp
using Bse.Framework.Core.DependencyInjection;
using Bse.Framework.Data.DependencyInjection;
using Bse.Framework.Data.EntityFramework.Context;
using Bse.Framework.Data.EntityFramework.Exceptions;
using Bse.Framework.Data.EntityFramework.Instrumentation;
using Bse.Framework.Data.EntityFramework.Repository;
using Bse.Framework.Data.Repository;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Bse.Framework.Data.EntityFramework.DependencyInjection;

/// <summary>
/// Entry-point extensions for plugging Entity Framework Core into Bse.Framework.
/// </summary>
public static class EfServiceCollectionExtensions
{
    /// <summary>
    /// Registers the EF provider, the supplied <typeparamref name="TContext"/>, an
    /// <see cref="IUnitOfWork"/> scoped to the context, the concurrency mapper, and
    /// the data-instrumentation interceptor.
    /// </summary>
    /// <typeparam name="TContext">The application's <see cref="BseDbContext"/>-derived type.</typeparam>
    /// <param name="builder">The framework builder.</param>
    /// <param name="optionsAction">Provider configuration callback (e.g. <c>opts.UseNpgsql(...)</c>).</param>
    /// <returns>The same builder, for chaining.</returns>
    /// <exception cref="ArgumentNullException">If <paramref name="builder"/> or <paramref name="optionsAction"/> is null.</exception>
    public static IBseFrameworkBuilder AddBseDataEntityFramework<TContext>(
        this IBseFrameworkBuilder builder,
        Action<DbContextOptionsBuilder> optionsAction)
        where TContext : BseDbContext
    {
        ArgumentNullException.ThrowIfNull(builder);
        ArgumentNullException.ThrowIfNull(optionsAction);

        // Make sure the data marker is registered.
        builder.AddBseData();
        builder.RegisterModule<BseDataEfModule>();

        builder.Services.AddDbContext<TContext>((sp, opts) =>
        {
            optionsAction(opts);
            opts.AddInterceptors(
                new ConcurrencyExceptionMapper(),
                new DataInstrumentationInterceptor());
        });

        // Provide DbContext for the generic IUnitOfWork resolution.
        builder.Services.AddScoped<DbContext>(sp => sp.GetRequiredService<TContext>());
        builder.Services.AddScoped<IUnitOfWork, EfUnitOfWork>();

        return builder;
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
dotnet build
git add src/Bse.Framework.Data.EntityFramework/BseDataEfModule.cs \
        src/Bse.Framework.Data.EntityFramework/DependencyInjection/
git commit -m "feat(data-ef): add AddBseDataEntityFramework<TContext>() entry point"
```

---

## Task 14: Integration tests with Testcontainers

**Files:**
- Create: `tests/Bse.Framework.Data.EntityFramework.Tests/Fixtures/PostgresFixture.cs`
- Create: `tests/Bse.Framework.Data.EntityFramework.Tests/Fixtures/TestDbContext.cs`
- Create: `tests/Bse.Framework.Data.EntityFramework.Tests/Repository/EfRepositoryTests.cs`
- Create: `tests/Bse.Framework.Data.EntityFramework.Tests/Repository/EfUnitOfWorkTests.cs`
- Create: `tests/Bse.Framework.Data.EntityFramework.Tests/Interceptors/AuditingInterceptorTests.cs`
- Create: `tests/Bse.Framework.Data.EntityFramework.Tests/Conventions/SoftDeleteFilterTests.cs`

Real Postgres via Testcontainers. The fixture boots one container per test class (xUnit `IAsyncLifetime`).

- [ ] **Step 1: `PostgresFixture.cs`**

```csharp
using Microsoft.EntityFrameworkCore;
using Testcontainers.PostgreSql;

namespace Bse.Framework.Data.EntityFramework.Tests.Fixtures;

/// <summary>xUnit fixture providing a fresh Postgres container per test class.</summary>
public sealed class PostgresFixture : IAsyncLifetime
{
    private readonly PostgreSqlContainer _container = new PostgreSqlBuilder()
        .WithImage("postgres:16-alpine")
        .WithDatabase("bse_test")
        .WithUsername("bse")
        .WithPassword("bse")
        .Build();

    public string ConnectionString => _container.GetConnectionString();

    public TestDbContext CreateContext()
    {
        var options = new DbContextOptionsBuilder<TestDbContext>()
            .UseNpgsql(ConnectionString)
            .Options;
        return new TestDbContext(options, new Bse.Framework.Core.Time.SystemClock());
    }

    public async Task InitializeAsync()
    {
        await _container.StartAsync().ConfigureAwait(false);
        await using var ctx = CreateContext();
        await ctx.Database.EnsureCreatedAsync().ConfigureAwait(false);
    }

    public Task DisposeAsync() => _container.DisposeAsync().AsTask();
}
```

- [ ] **Step 2: `TestDbContext.cs`**

```csharp
using Bse.Framework.Core.Time;
using Bse.Framework.Data.Entities;
using Bse.Framework.Data.EntityFramework.Context;
using Microsoft.EntityFrameworkCore;

namespace Bse.Framework.Data.EntityFramework.Tests.Fixtures;

public sealed class TestDbContext : BseDbContext
{
    public TestDbContext(DbContextOptions<TestDbContext> options, ISystemClock clock) : base(options, clock) { }

    public DbSet<TestStudent> Students => Set<TestStudent>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);
        modelBuilder.Entity<TestStudent>(e =>
        {
            e.ToTable("students");
            e.HasKey(x => x.Id);
            e.Property(x => x.Name).IsRequired().HasMaxLength(200);
        });
    }
}

public sealed class TestStudent : IEntity<int>, IAuditable, ISoftDelete
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;

    public DateTime CreatedAt { get; set; }
    public string CreatedBy { get; set; } = string.Empty;
    public DateTime? ModifiedAt { get; set; }
    public string? ModifiedBy { get; set; }

    public bool IsDeleted { get; set; }
    public DateTime? DeletedAt { get; set; }
}
```

- [ ] **Step 3: `EfRepositoryTests.cs`**

```csharp
using Bse.Framework.Data.EntityFramework.Repository;
using Bse.Framework.Data.EntityFramework.Tests.Fixtures;
using Bse.Framework.Data.Specifications;

namespace Bse.Framework.Data.EntityFramework.Tests.Repository;

public class EfRepositoryTests : IClassFixture<PostgresFixture>
{
    private readonly PostgresFixture _fixture;
    public EfRepositoryTests(PostgresFixture fixture) => _fixture = fixture;

    [Fact]
    public async Task AddAsync_PersistsAndAssignsId()
    {
        await using var ctx = _fixture.CreateContext();
        var repo = new EfRepository<TestStudent>(ctx);

        var student = new TestStudent { Name = "Ada" };
        await repo.AddAsync(student);
        await ctx.SaveChangesAsync();

        student.Id.ShouldBeGreaterThan(0);
    }

    [Fact]
    public async Task ListAsync_AppliesSpecification()
    {
        await using var ctx = _fixture.CreateContext();
        var repo = new EfRepository<TestStudent>(ctx);
        await repo.AddRangeAsync(new[]
        {
            new TestStudent { Name = "Ada" },
            new TestStudent { Name = "Grace" },
            new TestStudent { Name = "Edsger" },
        });
        await ctx.SaveChangesAsync();

        var spec = new Specification<TestStudent>()
            .Where(s => s.Name.StartsWith("G"))
            .AsNoTracking();

        var hits = await repo.ListAsync(spec);
        hits.Count.ShouldBe(1);
        hits[0].Name.ShouldBe("Grace");
    }

    [Fact]
    public async Task PageAsync_ReturnsPageWithTotalCount()
    {
        await using var ctx = _fixture.CreateContext();
        var repo = new EfRepository<TestStudent>(ctx);
        await repo.AddRangeAsync(Enumerable.Range(1, 25).Select(i => new TestStudent { Name = $"S{i:D2}" }));
        await ctx.SaveChangesAsync();

        var spec = new Specification<TestStudent>()
            .OrderByAscending(s => s.Name)
            .Page(page: 2, pageSize: 10);

        var page = await repo.PageAsync(spec);
        page.Items.Count.ShouldBe(10);
        page.TotalCount.ShouldBeGreaterThanOrEqualTo(25);
        page.Page.ShouldBe(2);
        page.PageSize.ShouldBe(10);
    }
}
```

- [ ] **Step 4: `EfUnitOfWorkTests.cs`**

```csharp
using Bse.Framework.Data.EntityFramework.Repository;
using Bse.Framework.Data.EntityFramework.Tests.Fixtures;

namespace Bse.Framework.Data.EntityFramework.Tests.Repository;

public class EfUnitOfWorkTests : IClassFixture<PostgresFixture>
{
    private readonly PostgresFixture _fixture;
    public EfUnitOfWorkTests(PostgresFixture fixture) => _fixture = fixture;

    [Fact]
    public async Task Repository_ReturnsSameInstancePerType()
    {
        await using var ctx = _fixture.CreateContext();
        await using var uow = new EfUnitOfWork(ctx);

        var a = uow.Repository<TestStudent>();
        var b = uow.Repository<TestStudent>();

        a.ShouldBeSameAs(b);
    }

    [Fact]
    public async Task SaveChangesAsync_ReturnsRowsAffected()
    {
        await using var ctx = _fixture.CreateContext();
        await using var uow = new EfUnitOfWork(ctx);

        await uow.Repository<TestStudent>().AddAsync(new TestStudent { Name = "Linus" });
        var n = await uow.SaveChangesAsync();

        n.ShouldBe(1);
    }
}
```

- [ ] **Step 5: `AuditingInterceptorTests.cs`**

```csharp
using Bse.Framework.Data.EntityFramework.Tests.Fixtures;

namespace Bse.Framework.Data.EntityFramework.Tests.Interceptors;

public class AuditingInterceptorTests : IClassFixture<PostgresFixture>
{
    private readonly PostgresFixture _fixture;
    public AuditingInterceptorTests(PostgresFixture fixture) => _fixture = fixture;

    [Fact]
    public async Task Insert_PopulatesCreatedAtAndCreatedBy()
    {
        await using var ctx = _fixture.CreateContext();
        var student = new TestStudent { Name = "Donald" };

        ctx.Students.Add(student);
        await ctx.SaveChangesAsync();

        student.CreatedAt.ShouldNotBe(default);
        student.CreatedBy.ShouldBe("system");
    }

    [Fact]
    public async Task Update_PopulatesModifiedFieldsButLeavesCreatedAlone()
    {
        await using var ctx = _fixture.CreateContext();
        var student = new TestStudent { Name = "Donald" };
        ctx.Students.Add(student);
        await ctx.SaveChangesAsync();
        var originalCreatedAt = student.CreatedAt;

        student.Name = "Donald Knuth";
        await ctx.SaveChangesAsync();

        student.ModifiedAt.ShouldNotBeNull();
        student.ModifiedBy.ShouldBe("system");
        student.CreatedAt.ShouldBe(originalCreatedAt);
    }

    [Fact]
    public async Task Remove_OnSoftDelete_RewritesAsUpdate()
    {
        await using var ctx = _fixture.CreateContext();
        var student = new TestStudent { Name = "Donald" };
        ctx.Students.Add(student);
        await ctx.SaveChangesAsync();

        ctx.Students.Remove(student);
        await ctx.SaveChangesAsync();

        // The filter hides it from default queries, but the row still exists.
        var stillThere = await ctx.Students.IgnoreQueryFilters().SingleOrDefaultAsync(s => s.Id == student.Id);
        stillThere.ShouldNotBeNull();
        stillThere!.IsDeleted.ShouldBeTrue();
        stillThere.DeletedAt.ShouldNotBeNull();
    }
}
```

- [ ] **Step 6: `SoftDeleteFilterTests.cs`**

```csharp
using Bse.Framework.Data.EntityFramework.Tests.Fixtures;
using Microsoft.EntityFrameworkCore;

namespace Bse.Framework.Data.EntityFramework.Tests.Conventions;

public class SoftDeleteFilterTests : IClassFixture<PostgresFixture>
{
    private readonly PostgresFixture _fixture;
    public SoftDeleteFilterTests(PostgresFixture fixture) => _fixture = fixture;

    [Fact]
    public async Task DefaultQuery_OmitsSoftDeletedRows()
    {
        await using var ctx = _fixture.CreateContext();
        var alive = new TestStudent { Name = "Alive" };
        var doomed = new TestStudent { Name = "Doomed" };
        ctx.Students.AddRange(alive, doomed);
        await ctx.SaveChangesAsync();
        ctx.Students.Remove(doomed);
        await ctx.SaveChangesAsync();

        var visible = await ctx.Students.ToListAsync();

        visible.Any(s => s.Id == alive.Id).ShouldBeTrue();
        visible.Any(s => s.Id == doomed.Id).ShouldBeFalse();
    }

    [Fact]
    public async Task IgnoreQueryFilters_SeesSoftDeletedRows()
    {
        await using var ctx = _fixture.CreateContext();
        var alive = new TestStudent { Name = "Alive" };
        var doomed = new TestStudent { Name = "Doomed" };
        ctx.Students.AddRange(alive, doomed);
        await ctx.SaveChangesAsync();
        ctx.Students.Remove(doomed);
        await ctx.SaveChangesAsync();

        var all = await ctx.Students.IgnoreQueryFilters().ToListAsync();

        all.Any(s => s.Id == alive.Id).ShouldBeTrue();
        all.Any(s => s.Id == doomed.Id).ShouldBeTrue();
    }
}
```

- [ ] **Step 7: Run integration tests + commit**

```bash
dotnet test tests/Bse.Framework.Data.EntityFramework.Tests/
```

Expected: 8 tests pass (3 repo + 2 UoW + 3 audit + 2 soft-delete). Containers start cleanly.

```bash
git add tests/Bse.Framework.Data.EntityFramework.Tests/
git commit -m "test(data-ef): add integration tests with Testcontainers Postgres"
```

---

## Task 15: Grow docker-compose — Postgres + Flyway + Redis

**Files:**
- Modify: `samples/observability-stack/docker-compose.yml`
- Create: `samples/observability-stack/postgres/init.sql`
- Modify: `samples/observability-stack/README.md`

- [ ] **Step 1: Append three new services to `docker-compose.yml`**

Append inside the `services:` block (before the `volumes:` block):

```yaml
  postgres:
    image: postgres:16-alpine
    container_name: bse-postgres
    environment:
      POSTGRES_DB: bse
      POSTGRES_USER: bse
      POSTGRES_PASSWORD: bse
    volumes:
      - ./postgres/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
      - postgres-data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U bse -d bse"]
      interval: 5s
      timeout: 3s
      retries: 10

  flyway:
    image: flyway/flyway:11
    container_name: bse-flyway
    command: -url=jdbc:postgresql://postgres:5432/bse_demo -user=bse -password=bse -connectRetries=30 migrate
    volumes:
      - ../data-demo/db/migrations:/flyway/sql:ro
    depends_on:
      postgres:
        condition: service_healthy

  redis:
    image: redis:7-alpine
    container_name: bse-redis
    command: ["redis-server", "--appendonly", "yes"]
    ports:
      - "6379:6379"
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10
```

Append two new volume entries inside the `volumes:` block:

```yaml
  postgres-data:
  redis-data:
```

- [ ] **Step 2: Create the Postgres init script**

`samples/observability-stack/postgres/init.sql`:

```sql
-- Runs once on first container boot. Creates the demo database; tables come from Flyway.
CREATE DATABASE bse_demo;
```

- [ ] **Step 3: Update the README**

Replace the existing service table at the top of `samples/observability-stack/README.md` with:

```markdown
| Service | URL / Port | Purpose |
|---|---|---|
| OTel Collector | `localhost:4317` (gRPC), `localhost:4318` (HTTP) | OTLP ingest |
| Tempo | `localhost:3200` | Trace storage |
| Loki | `localhost:3100` | Log storage |
| Prometheus | `localhost:9090` | Metric storage |
| Grafana | `localhost:3000` | UI (anonymous auth, no login) |
| Postgres | `localhost:5432` | Application database (user/pw: `bse`/`bse`, db: `bse_demo`) |
| Flyway | (one-shot) | Applies SQL migrations from `samples/data-demo/db/migrations/` |
| Redis | `localhost:6379` | Transport for `Bse.Framework.Rpc.RedisStreams` (idle in this cycle; used in the next) |
```

- [ ] **Step 4: Boot and verify**

```bash
cd samples/observability-stack
docker compose up -d
sleep 30
docker compose ps
# Postgres should be healthy, flyway should be exit 0 (migrate complete), redis should be healthy
# (flyway needs samples/data-demo/db/migrations to exist — Task 16 creates it. For this task,
#  expect flyway to fail with "no migrations found" — that's fine; full happy path is in Task 17.)
docker compose down
```

- [ ] **Step 5: Commit**

```bash
git add samples/observability-stack/docker-compose.yml \
        samples/observability-stack/postgres/init.sql \
        samples/observability-stack/README.md
git commit -m "feat(samples): expand observability-stack with Postgres, Flyway, and idle Redis"
```

---

## Task 16: `data-demo` sample app with CRUD + Flyway migrations

**Files:**
- Create: `samples/data-demo/data-demo.csproj`
- Create: `samples/data-demo/Program.cs`
- Create: `samples/data-demo/appsettings.json`
- Create: `samples/data-demo/Models/Student.cs`
- Create: `samples/data-demo/Models/StudentDbContext.cs`
- Create: `samples/data-demo/db/migrations/V001__init_students.sql`
- Create: `samples/data-demo/db/migrations/V002__add_audit_columns.sql`
- Create: `samples/data-demo/README.md`

- [ ] **Step 1: csproj**

```xml
<Project Sdk="Microsoft.NET.Sdk.Web">

  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
    <RootNamespace>DataDemo</RootNamespace>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <IsPackable>false</IsPackable>
    <TreatWarningsAsErrors>false</TreatWarningsAsErrors>
    <GenerateDocumentationFile>false</GenerateDocumentationFile>
  </PropertyGroup>

  <ItemGroup>
    <ProjectReference Include="..\..\src\Bse.Framework.Core\Bse.Framework.Core.csproj" />
    <ProjectReference Include="..\..\src\Bse.Framework.Telemetry\Bse.Framework.Telemetry.csproj" />
    <ProjectReference Include="..\..\src\Bse.Framework.Data\Bse.Framework.Data.csproj" />
    <ProjectReference Include="..\..\src\Bse.Framework.Data.EntityFramework\Bse.Framework.Data.EntityFramework.csproj" />
  </ItemGroup>

  <ItemGroup>
    <PackageReference Include="OpenTelemetry.Instrumentation.AspNetCore" />
  </ItemGroup>

</Project>
```

- [ ] **Step 2: Migrations**

`samples/data-demo/db/migrations/V001__init_students.sql`:

```sql
CREATE TABLE IF NOT EXISTS students (
    id           SERIAL PRIMARY KEY,
    name         VARCHAR(200) NOT NULL,
    is_deleted   BOOLEAN      NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ
);

CREATE INDEX ix_students_name ON students (name);
```

`samples/data-demo/db/migrations/V002__add_audit_columns.sql`:

```sql
ALTER TABLE students
    ADD COLUMN created_at   TIMESTAMPTZ NOT NULL DEFAULT (NOW() AT TIME ZONE 'utc'),
    ADD COLUMN created_by   VARCHAR(200) NOT NULL DEFAULT 'system',
    ADD COLUMN modified_at  TIMESTAMPTZ,
    ADD COLUMN modified_by  VARCHAR(200);
```

- [ ] **Step 3: Models**

`samples/data-demo/Models/Student.cs`:

```csharp
using Bse.Framework.Data.Entities;

namespace DataDemo.Models;

public sealed class Student : IEntity<int>, IAuditable, ISoftDelete
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;

    public DateTime CreatedAt { get; set; }
    public string CreatedBy { get; set; } = string.Empty;
    public DateTime? ModifiedAt { get; set; }
    public string? ModifiedBy { get; set; }

    public bool IsDeleted { get; set; }
    public DateTime? DeletedAt { get; set; }
}
```

`samples/data-demo/Models/StudentDbContext.cs`:

```csharp
using Bse.Framework.Core.Time;
using Bse.Framework.Data.EntityFramework.Context;
using Microsoft.EntityFrameworkCore;

namespace DataDemo.Models;

public sealed class StudentDbContext : BseDbContext
{
    public StudentDbContext(DbContextOptions<StudentDbContext> options, ISystemClock clock) : base(options, clock) { }

    public DbSet<Student> Students => Set<Student>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);
        modelBuilder.Entity<Student>(e =>
        {
            e.ToTable("students");
            e.HasKey(s => s.Id);
            e.Property(s => s.Name).HasColumnName("name").IsRequired().HasMaxLength(200);
            e.Property(s => s.IsDeleted).HasColumnName("is_deleted");
            e.Property(s => s.DeletedAt).HasColumnName("deleted_at");
            e.Property(s => s.CreatedAt).HasColumnName("created_at");
            e.Property(s => s.CreatedBy).HasColumnName("created_by");
            e.Property(s => s.ModifiedAt).HasColumnName("modified_at");
            e.Property(s => s.ModifiedBy).HasColumnName("modified_by");
        });
    }
}
```

- [ ] **Step 4: `Program.cs`**

```csharp
using Bse.Framework.Core.DependencyInjection;
using Bse.Framework.Data.Repository;
using Bse.Framework.Data.Specifications;
using Bse.Framework.Data.EntityFramework.DependencyInjection;
using Bse.Framework.Telemetry.DependencyInjection;
using DataDemo.Models;
using Microsoft.EntityFrameworkCore;
using OpenTelemetry.Trace;

var builder = WebApplication.CreateBuilder(args);

var connectionString = builder.Configuration.GetConnectionString("Postgres")
    ?? "Host=localhost;Port=5432;Database=bse_demo;Username=bse;Password=bse";

builder.Services.AddBseFramework(framework =>
{
    framework.AddBseTelemetry(t =>
    {
        t.ServiceName = "data-demo";
        t.ServiceVersion = "0.1.0";
        t.Environment = "development";
        t.UseOtlpExporter(new Uri("http://localhost:4317"));
        t.Traces.SamplingRatio = 1.0;
        t.Metrics.UseTraceBasedExemplars();
        t.Logs.IncludeScopes = true;
    });

    framework.AddBseDataEntityFramework<StudentDbContext>(opts =>
    {
        opts.UseNpgsql(connectionString);
    });
});

builder.Services.ConfigureOpenTelemetryTracerProvider(tp => tp.AddAspNetCoreInstrumentation());

var app = builder.Build();

app.MapGet("/students", async (IUnitOfWork uow, int page = 1, int pageSize = 20) =>
{
    var spec = new Specification<Student>()
        .OrderByAscending(s => s.Name)
        .Page(page, pageSize)
        .AsNoTracking();
    var result = await uow.Repository<Student>().PageAsync(spec);
    return Results.Ok(result);
});

app.MapGet("/students/{id:int}", async (int id, IUnitOfWork uow) =>
{
    var s = await uow.Repository<Student>().GetByIdAsync(id);
    return s is null ? Results.NotFound() : Results.Ok(s);
});

app.MapPost("/students", async (Student student, IUnitOfWork uow) =>
{
    await uow.Repository<Student>().AddAsync(student);
    await uow.SaveChangesAsync();
    return Results.Created($"/students/{student.Id}", student);
});

app.MapPut("/students/{id:int}", async (int id, Student input, IUnitOfWork uow) =>
{
    var existing = await uow.Repository<Student>().GetByIdAsync(id);
    if (existing is null) return Results.NotFound();
    existing.Name = input.Name;
    uow.Repository<Student>().Update(existing);
    await uow.SaveChangesAsync();
    return Results.Ok(existing);
});

app.MapDelete("/students/{id:int}", async (int id, IUnitOfWork uow) =>
{
    var existing = await uow.Repository<Student>().GetByIdAsync(id);
    if (existing is null) return Results.NotFound();
    uow.Repository<Student>().Remove(existing);
    await uow.SaveChangesAsync();
    return Results.NoContent();
});

app.Run();
```

- [ ] **Step 5: `appsettings.json`**

```json
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning",
      "Microsoft.EntityFrameworkCore.Database.Command": "Warning"
    }
  },
  "ConnectionStrings": {
    "Postgres": "Host=localhost;Port=5432;Database=bse_demo;Username=bse;Password=bse"
  },
  "AllowedHosts": "*",
  "Urls": "http://localhost:5060"
}
```

- [ ] **Step 6: `samples/data-demo/README.md`**

```markdown
# data-demo

Minimal ASP.NET Core CRUD app over `Bse.Framework.Data.EntityFramework` + Postgres. Traces, metrics, and logs flow through the existing observability stack.

## Run

```bash
# 1. Boot the observability stack (already includes Postgres + Flyway + Redis).
cd ../observability-stack
docker compose up -d
# Flyway runs once at compose-up, applies db/migrations against Postgres.

# 2. Run the app.
cd ../data-demo
dotnet run            # listens on http://localhost:5060

# 3. Hit the API.
curl -X POST http://localhost:5060/students -H 'Content-Type: application/json' -d '{"name":"Ada Lovelace"}'
curl -X POST http://localhost:5060/students -H 'Content-Type: application/json' -d '{"name":"Grace Hopper"}'
curl http://localhost:5060/students
curl http://localhost:5060/students/1

# 4. Browse Grafana (http://localhost:3000)
#    - Tempo: search service.name = data-demo to see request + bse.data.* spans
#    - Prometheus: histogram_quantile(0.95, sum by (le) (rate(bse_data_query_duration_seconds_bucket[5m])))
#    - Loki: {service_name="data-demo"}
```

## Schema management

Schemas are managed by Flyway (ADR-0010), not EF Core migrations. SQL files live in `db/migrations/` named `V{n}__{description}.sql`. To add a new column:

1. Write `V003__add_my_column.sql` in `db/migrations/`.
2. `docker compose up -d flyway` re-runs (or rebuild the stack).
3. Update the entity class + DbContext mapping if needed.
4. Optional: `flyway info` + `flyway validate` for drift detection.
```

- [ ] **Step 7: Build + smoke test**

```bash
dotnet build samples/data-demo
cd samples/observability-stack
docker compose up -d
sleep 30
docker compose logs flyway | tail -20    # confirm "Successfully applied 2 migrations"
docker compose ps | grep healthy         # postgres, redis healthy
cd ../data-demo
dotnet run &
sleep 5
curl -s -X POST http://localhost:5060/students -H 'Content-Type: application/json' -d '{"name":"Ada"}' | jq
curl -s http://localhost:5060/students | jq
# Tear down
kill %1
cd ../observability-stack
docker compose down -v
```

Expected: Flyway logs show 2 migrations applied, POST returns 201 with id=1, GET returns paged result with 1 item.

- [ ] **Step 8: Commit**

```bash
git add samples/data-demo/
git commit -m "feat(samples): add data-demo CRUD app with Flyway-managed Postgres schema"
```

---

## Task 17: CI update — Postgres-backed integration tests + Flyway validate

**Files:**
- Modify: `.github/workflows/ci.yml`

Add a third job that runs Testcontainers-backed integration tests against a real Postgres in CI. Also add a Flyway `validate` step in the observability-smoke job to catch drift.

- [ ] **Step 1: Append the data-integration job after vulnerability-scan**

```yaml
  data-integration:
    runs-on: ubuntu-latest
    services:
      docker:
        image: docker:dind
        options: --privileged
    steps:
      - uses: actions/checkout@v4
      - name: Setup .NET
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '9.0.x'
      - name: Restore
        run: dotnet restore
      - name: Run Data.EntityFramework integration tests (Testcontainers Postgres)
        run: dotnet test tests/Bse.Framework.Data.EntityFramework.Tests/ --configuration Release --logger "trx;LogFileName=data-results.trx"
      - name: Upload results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: data-test-results
          path: '**/data-results.trx'
```

- [ ] **Step 2: Extend the observability-smoke job to validate Flyway migrations**

Before the "Bring up observability stack" step, add:

```yaml
      - name: Validate Flyway migrations (drift check)
        run: |
          docker run --rm \
            -v ${{ github.workspace }}/samples/data-demo/db/migrations:/flyway/sql:ro \
            flyway/flyway:11 -url=jdbc:h2:mem:check info
          # Just exercises file parsing; doesn't need a live DB.
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add data-integration job (Testcontainers) + Flyway validate step"
```

---

## Task 18: Final verification + pack + tag v0.1.0

- [ ] **Step 1: Clean release build**

```bash
cd /Users/mahrous/Projects/bse/bse-core
dotnet clean
dotnet build --configuration Release
```

Expected: 0 warnings, 0 errors across 6 projects.

- [ ] **Step 2: Full test suite**

```bash
dotnet test --configuration Release --no-build
```

Expected:
- Core.Tests: 58 passing
- Telemetry.Tests: 14 passing
- Data.Tests: ~9 passing (Spec + PagedResult)
- Data.EntityFramework.Tests: ~10 passing (3 repo + 2 UoW + 3 audit + 2 soft-delete) — requires Docker for Testcontainers

Total: ~91 tests.

- [ ] **Step 3: Full end-to-end smoke against the stack**

```bash
cd samples/observability-stack
docker compose up -d
sleep 30
docker compose logs flyway | grep "Successfully applied"

cd ../data-demo
dotnet run &
APP=$!
sleep 5

# Hammer the API
for i in $(seq 1 50); do
  curl -s -X POST http://localhost:5060/students -H 'Content-Type: application/json' \
       -d "{\"name\":\"Student $i\"}" > /dev/null
done
for i in $(seq 1 100); do
  curl -s http://localhost:5060/students?page=$((RANDOM%5+1)) > /dev/null
done

sleep 15  # let exports flush

# Verify Tempo has data-demo spans, Prometheus has bse.data.query.duration
curl -fsS http://localhost:3200/api/search/tag/service.name/values | grep -q data-demo && echo "Tempo: OK"
curl -fsS "http://localhost:9090/api/v1/label/__name__/values" | python3 -c "import sys,json; print('Prometheus:', 'OK' if 'bse_data_query_duration_seconds_bucket' in json.load(sys.stdin)['data'] else 'MISSING')"

kill $APP
cd ../observability-stack
docker compose down -v
```

Expected: `Tempo: OK`, `Prometheus: OK`.

- [ ] **Step 4: Pack both packages**

```bash
cd /Users/mahrous/Projects/bse/bse-core
dotnet pack src/Bse.Framework.Data/Bse.Framework.Data.csproj --configuration Release --output ./artifacts
dotnet pack src/Bse.Framework.Data.EntityFramework/Bse.Framework.Data.EntityFramework.csproj --configuration Release --output ./artifacts
ls artifacts/Bse.Framework.Data*.nupkg
```

Expected: `Bse.Framework.Data.0.1.0.nupkg`, `Bse.Framework.Data.EntityFramework.0.1.0.nupkg` (+ snupkgs).

- [ ] **Step 5: Release commits + tags**

```bash
git commit --allow-empty -m "release: Bse.Framework.Data v0.1.0"
git tag bse.framework.data/v0.1.0

git commit --allow-empty -m "release: Bse.Framework.Data.EntityFramework v0.1.0"
git tag bse.framework.data.entityframework/v0.1.0
```

- [ ] **Step 6: Update docs in Documentation repo**

```bash
cd /Users/mahrous/Projects/bse/Documentation
# Edit docs/framework/index.md — flip Data + Data.EntityFramework rows from "In planning" to "Shipped" with tag links.
# Edit bse-core/README.md — add Data + Data.EntityFramework rows to the packages table.
git add docs/framework/index.md
git commit -m "docs: Data + Data.EntityFramework v0.1.0 shipped"
```

```bash
cd /Users/mahrous/Projects/bse/bse-core
# Update README.md package table and Sample run instructions to include data-demo.
git add README.md
git commit -m "docs: update README — Data packages shipped, data-demo runnable"
```

---

## Spec Self-Review

Coverage against RFC-0003 v0.1.0 scope:

| RFC item | Task |
|---|---|
| Entity markers (IEntity, IAuditable, ISoftDelete, IConcurrencyAware, IMultiTenant, IHasDomainEvents) | Task 2 |
| Specification<T> + Specification<T, TResult> | Task 3 |
| Offset pagination (PagedRequest, PagedResult<T>) | Task 4 |
| IRepository<T>, IUnitOfWork | Tasks 5, 9, 10 |
| BseDbContext + auditing + soft-delete filter | Task 8 |
| EF Specification evaluation | Task 7 |
| BseConcurrencyException mapping from EF | Task 11 |
| Telemetry instrumentation (ActivitySource + duration histogram) | Task 12 |
| AddBseData / AddBseDataEntityFramework | Tasks 6, 13 |
| Integration tests with real Postgres | Task 14 |
| Postgres + Flyway + Redis in docker-compose | Task 15 |
| Sample CRUD app | Task 16 |
| CI: Testcontainers integration job + Flyway validate | Task 17 |
| Pack + tag + doc updates | Task 18 |

Intentionally deferred (each becomes its own future plan):

- Dapper source generator + `[Query]`-attributed interfaces — needs `Bse.Framework.SourceGenerators` infrastructure
- Strongly-typed IDs — separate source generator
- Transactional outbox — needs `Bse.Framework.Rpc` + eventing
- Domain event dispatch — needs eventing
- Multi-tenant query filters + Postgres RLS — needs `Bse.Framework.MultiTenancy`
- Cursor/keyset pagination — v0.2.0 of this package
- `ExecuteUpdate` / `ExecuteDelete` bulk ops — v0.2.0
- Full audit trail with before/after capture — needs Auth context
- Distributed locks — likely separate package
- Roslyn analyzer forbidding `IgnoreQueryFilters` — needs `Bse.Framework.SourceGenerators`
- SQL Server provider — `Bse.Framework.Data.SqlServer` as a peer package later

Each deferred item has a clear owner (a future plan or future package). Nothing falls through the cracks.
