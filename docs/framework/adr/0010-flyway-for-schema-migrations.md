# ADR-0010: Use Flyway for Schema Migrations

- **Status:** Accepted
- **Date:** 2026-05-15
- **Tags:** data, migrations, schema, devops, postgres

## Context

The framework's data access layer (RFC-0003) uses EF Core for write commands. EF Core ships with a built-in migrations system (`Add-Migration` / `Update-Database`) that generates C# migration classes from model changes. The default question is: do we adopt EF Core migrations or use a dedicated, SQL-first migration tool?

Forces at play:

- **The legacy BSE apps are database-first.** Stud2 / SafePack2 / Orange2 all use EDMX scaffolding from existing SQL Server schemas. Their DBAs own the schema and write SQL by hand. Forcing them onto code-first EF migrations would be a politics + skills problem, not a tooling improvement.
- **EF Core migration files are hard to review.** They're auto-generated C# that calls `migrationBuilder.AddColumn(...)` — readable but verbose, prone to hidden semantics, and not a format DBAs are comfortable with.
- **Migration drift is real.** Production hotfixes applied directly via `psql`/`sqlcmd` silently desynchronize the EF migration history table. EF Core has no built-in drift detection.
- **Cross-tool friction.** We want Dapper queries (RFC-0003) to use the same schema EF reads — and Dapper has no migration story. A single SQL-first tool is cleaner than juggling EF migrations + manual Dapper alignment.
- **Production deployment.** Applying migrations should happen at deploy time, not app startup. A standalone migrator container (independent of the application runtime) is the industry pattern. EF Core's `dotnet ef database update` works but pulls the entire .NET runtime + app assemblies into the deploy job for a schema change.
- **Provider portability.** RFC-0003 wants both SQL Server and PostgreSQL. SQL-first migrations are trivially portable with environment-specific dialects in separate files; EF Core migrations require provider-specific generation flags.

## Decision

Use **[Flyway](https://flywaydb.org/)** as the schema migration tool across all packages and sample apps. EF Core migrations are not used. The framework's `BseDbContext` consumes the schema; it never shapes it.

Schema files live in `db/migrations/` per-app/per-service, named `V{version}__{description}.sql` (Flyway convention). Flyway runs:
- **Locally** as a one-shot container in `docker-compose` against the dev Postgres before app containers boot.
- **In CI** as a `flyway validate` job (drift check) plus a `flyway info` job (visibility).
- **In production** as a one-shot job/step in the deploy pipeline (Kubernetes Job, AWS ECS standalone task, etc.).

EF Core's `dbcontext scaffold` command is the recommended path for keeping entity classes in sync with the SQL schema: run it once after a migration, commit the resulting POCOs. Hand-written entities are also fine — they just need to match the schema, which `flyway validate` enforces in CI.

## Options Considered

### Option A: EF Core Migrations
- **Pros:** Built into the SDK, no extra tooling, model-first generation, integrates with `dotnet ef` CLI.
- **Cons:** C# migration files are not DBA-friendly. No drift detection. Requires application assemblies to apply. Doesn't help Dapper. Migration history table is opaque. Production hot-fix recovery is painful.

### Option B: Flyway (chosen)
- **Pros:** Plain SQL files; DBA-readable and diff-able. Strong drift detection (`flyway validate`). Standalone container — no app runtime dependency. Large community, battle-tested at scale. Works equally for SQL Server, PostgreSQL, MySQL, Oracle. Supports both versioned (`V1__init.sql`) and repeatable (`R__seed.sql`) migrations.
- **Cons:** Java runtime dependency (acceptable as a CI/deploy concern). Naming convention is opinionated. Open-source edition lacks "undo migrations" feature (paid Teams edition has it — we don't need it; forward-only migrations + transactional rollback at the SQL level are sufficient).

### Option C: Sqitch
- **Pros:** Dependency-graph model is more powerful than linear versions. Verify + revert scripts built in. Plain SQL.
- **Cons:** Perl runtime dependency. Smaller community. Dependency-graph adds friction for our app shape (linear schema evolution is normal). Less widespread Docker tooling.

### Option D: dbmate / migrate (Go-based, plain SQL)
- **Pros:** Single-binary install. Plain SQL. Minimal opinions.
- **Cons:** Smaller communities than Flyway. Fewer integrations (Grafana / k8s operators / etc.). No native validate command in dbmate.

## Rationale

**Schema and code separation matters at this scale.** The framework will outlive any given C# codebase iteration. SQL-first migrations are the long-term-stable artifact; the C# entities are derivative. Flyway gets us:

1. **DBA-readable, reviewable migrations** — plain SQL files in git.
2. **Drift detection that actually works** — `flyway validate` fails CI when a hand-edit in prod desynchronizes the migration history.
3. **Provider-agnostic by file naming** — same Flyway invocation handles Postgres or SQL Server with dialect-specific SQL.
4. **Independent of the app deploy** — Flyway runs in its own container before app containers start, in CI as a separate job.

Sqitch is technically more sophisticated but the dependency-graph model is overkill for linear schema evolution and the Perl runtime is a sharp edge. Flyway is the boring, durable choice.

## Consequences

### Positive
- DBAs own and review schema in their native medium (SQL).
- Drift detection lands automatically in CI.
- Production deploys don't need the .NET runtime to apply schema changes.
- Same tool spans EF Core writes and Dapper reads — no second migration story when `Bse.Framework.Data.Dapper` lands.
- Forward-only migration discipline matches the industry norm for transactional databases.

### Negative
- Developers must learn Flyway's `V{n}__{desc}.sql` naming and `flyway info`/`migrate`/`validate` commands.
- No `dotnet ef add-migration` ergonomic from model changes. Workflow becomes: edit SQL → `flyway migrate` → `dotnet ef dbcontext scaffold` (or hand-update entities) → commit both.
- Java runtime in the CI/deploy path (acceptable; isolated to one container).
- Two artifacts to coordinate per schema change (SQL file + entity update) instead of one.

### Neutral
- Flyway Community Edition (Apache 2.0) is sufficient; we don't need Teams/Enterprise features.
- `dotnet ef dbcontext scaffold` remains useful — just as a code-generator, not as a migration applier.
- Strongly-typed IDs (RFC-0003) are unaffected — the source generator still produces value converters; only the *schema creation* path changes.
- Each sample app gets its own `db/migrations/` directory; the framework itself ships no migrations (it has no schema of its own).

## References

- RFC-0003: Data Access Layer (consumes this decision; schema-shaping is out of EF's scope)
- ADR-0003: EF Core + Dapper Hybrid (EF for commands, Dapper for queries — both consume the SQL-first schema)
- Flyway documentation: <https://flywaydb.org/documentation/>
- Sqitch documentation (rejected option): <https://sqitch.org/>
- "Evolutionary Database Design", Ambler & Sadalage — chapter on tool-agnostic migration discipline
