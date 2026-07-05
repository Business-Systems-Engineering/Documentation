# ADR-0010: Opt-In EF Migrations, Flyway by Default

- **Status:** Accepted
- **Date:** 2026-05-15
- **Deciders:** BSE Framework Team
- **Tags:** data, migrations, ef-core, flyway

## Context

The framework's data access layer (RFC-0003) uses EF Core for write commands via `BseDbContext`.
EF Core ships with a built-in migrations system (`Add-Migration` / `Update-Database`) that generates
C# migration classes from model changes. The default question is whether to adopt EF Core migrations
or use a dedicated, SQL-first migration tool.

Forces at play:

- **The legacy BSE apps are database-first.** Stud2, SafePack2, and Orange2 all use EDMX
  scaffolding from existing SQL Server schemas. Their DBAs own the schema and write SQL by hand.
  Forcing them onto code-first EF migrations would be a politics and skills problem, not a tooling
  improvement.
- **EF Core migration files are not DBA-readable.** They are auto-generated C# that calls
  `migrationBuilder.AddColumn(...)` — readable but verbose, prone to hidden semantics, and not a
  format DBAs review comfortably.
- **Migration drift is real.** Production hotfixes applied directly via `psql`/`sqlcmd` silently
  desynchronize the EF migration history table. EF Core has no built-in drift detection.
- **Production deployment.** Applying migrations should happen at deploy time, not at application
  startup, and it should not require the full .NET runtime and application assemblies. A standalone
  migrator container is the industry pattern.
- **Dapper reads the same schema.** `Bse.Framework.Data.Dapper` has no migration story of its own.
  A single SQL-first tool covers both the EF write side and the Dapper read side.
- **Provider portability.** RFC-0003 targets both SQL Server and PostgreSQL. SQL-first migrations
  are portable with dialect-specific files; EF Core migrations require provider-specific generation
  flags.

Despite the above, there are valid cases for EF-managed migrations: early-stage greenfield services
with frequent schema churn, developer environments where spinning up Flyway adds friction, and teams
with no DBA involvement. Refusing to support EF migrations at all would be dogmatic.

## Decision

The framework takes **no default opinion on schema management**. `BseDataEfOptions.EnableMigrations`
defaults to `false`. When it is `false`, no migration logic is registered and the application starts
regardless of the schema state.

When `EnableMigrations` is set to `true`, the framework registers
`EfMigrationsHostedService<TContext>` — a hosted service that calls `MigrateAsync` on the
configured `DbContext` during `StartAsync`. The service runs once before the host begins serving
traffic. If `MigrateAsync` throws (unreachable database, failed migration script), the exception
propagates and the host fails to start. Schema correctness is treated as a startup contract; silent
degradation would produce data-corruption risk at runtime.

```csharp
// Opt into EF-managed migrations (e.g. greenfield or developer environment)
builder.AddBseDataEntityFramework<MyDbContext>(
    opts => opts.UseNpgsql(connStr),
    ef   => ef.EnableMigrations = true);

// Default — no migration logic registered; use Flyway / manual SQL / dotnet ef CLI
builder.AddBseDataEntityFramework<MyDbContext>(
    opts => opts.UseNpgsql(connStr));
```

For teams that opt out (the default), the recommended migration tool is **Flyway**. Schema files
live in `db/migrations/` per-app/per-service, named `V{version}__{description}.sql`. Flyway runs:

- **Locally** as a one-shot container in `docker-compose` before app containers boot.
- **In CI** as `flyway validate` (drift check) + `flyway info` (visibility).
- **In production** as a one-shot job in the deploy pipeline (Kubernetes Job, ECS task, etc.),
  independent of the application container.

## Options Considered

### Option A: EF migrations always-on
- **Pros:** Built into the SDK, no extra tooling, model-first generation, integrates with
  `dotnet ef` CLI.
- **Cons:** C# migration files are not DBA-friendly. No drift detection. Requires application
  assemblies at deploy time to apply schema changes. Does not cover the Dapper read side.
  Migration history table is opaque to SQL tooling.

### Option B: Flyway only — EF migrations removed
- **Pros:** Plain SQL files; DBA-readable and diff-able. Strong drift detection (`flyway validate`).
  Standalone container — no app runtime dependency. Large community, battle-tested at scale. Works
  for SQL Server, PostgreSQL, MySQL, Oracle.
- **Cons:** Removes a migration path that works well for some teams. Adds Java runtime to CI/deploy.
  Forces every team to learn Flyway's naming convention.

### Option C: Opt-in EF migrations, Flyway by default [chosen]
- **Pros:** Teams with DBA ownership or existing SQL tooling get Flyway's plain-SQL, drift-detected
  flow. Greenfield services or teams with no DBA can opt into `EnableMigrations = true` for
  migrate-at-startup convenience. The framework enforces fail-fast semantics in both paths — there
  is no silent drift. The abstraction is in `BseDataEfOptions`; the mechanism is
  `EfMigrationsHostedService<TContext>`, which is a thin, testable wrapper around `MigrateAsync`.
- **Cons:** Framework documentation must explain two paths. Developers must make an explicit choice
  rather than having a single blessed workflow.

## Rationale

Schema and code separation matters at this scale. SQL-first migrations are the long-term stable
artifact; C# entity classes are derivative. Flyway gives DBA-readable, reviewable migrations,
real drift detection, and independence from the application deploy. But the framework should not
prevent teams that genuinely benefit from EF-managed migrations from using them. `EnableMigrations`
as an opt-in is the smallest surface that serves both cases without opinion.

## Consequences

### Positive
- DBAs own and review schema in their native medium (SQL) by default.
- Drift detection lands automatically in CI when Flyway is used.
- Production deploys do not need the .NET runtime to apply schema changes (Flyway path).
- The same tool covers both the EF write side and the Dapper read side.
- Teams that opt into `EnableMigrations` get fail-fast startup rather than silent degradation.

### Negative
- Two documented paths; developers must make an explicit choice.
- Flyway path: Java runtime in the CI/deploy container (acceptable; isolated to one container).
- EF path: the full `MigrateAsync` at startup is slower than a Flyway standalone job;
  database must be reachable before the process starts.

### Neutral
- Flyway Community Edition (Apache 2.0) is sufficient; no Teams/Enterprise features are needed.
- `dotnet ef dbcontext scaffold` remains the recommended path for keeping entity classes in sync
  with SQL-first schema changes — as a code-generator, not as a migration applier.
- The framework itself ships no migrations; it has no schema of its own.

## References

- RFC-0003: Data Access Layer
- ADR-0003: EF Core + Dapper Hybrid
- Flyway documentation: <https://flywaydb.org/documentation/>
- `EfMigrationsHostedService<TContext>` — `Bse.Framework.Data.EntityFramework`
- `BseDataEfOptions.EnableMigrations` — `Bse.Framework.Data.EntityFramework`
