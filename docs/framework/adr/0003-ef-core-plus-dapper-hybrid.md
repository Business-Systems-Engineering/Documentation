# ADR-0003: EF Core + Dapper Hybrid Data Access (CQRS Split)

- **Status:** Accepted
- **Date:** 2026-04-06
- **Tags:** data-access, cqrs, ef-core, dapper

## Context

The existing BSE apps use Entity Framework 6 Database-First with EDMX models, generic repositories, and a UnitOfWork pattern. They also extensively use raw SQL via `db.Database.SqlQuery<T>(rawSql)` with string concatenation — creating SQL injection vulnerabilities throughout. Pagination is inconsistent (none in Stud2, OFFSET/FETCH in SafePack2, ROW_NUMBER() in Orange2). We need a single data access strategy that handles both simple CRUD and complex reporting queries while eliminating SQL injection risks.

## Decision

Adopt a **CQRS-style split**: **EF Core for commands (writes)** and **Dapper for queries (complex reads)**. Both backed by source generators that eliminate boilerplate and enforce parameterization.

## Options Considered

### Option A: EF Core Code-First Only
- **Pros:** Single ORM, built-in migrations, change tracking, lazy/eager loading, scaffold from existing DBs
- **Cons:** Complex reporting queries painful in LINQ, performance overhead for bulk operations, generated SQL can be suboptimal, team already writes raw SQL (fighting the grain), N+1 query traps

### Option B: EF Core + Dapper Hybrid
- **Pros:** EF Core for CRUD with change tracking and migrations, Dapper for complex queries with full SQL control, matches existing reality (simple CRUD + complex reports), parameterized queries enforced in both, best performance profile, natural CQRS split
- **Cons:** Two data access patterns to maintain, need clear guidelines, slight cognitive overhead

### Option C: Dapper Only
- **Pros:** Full SQL control, fastest raw performance, closest to current raw SQL approach, simple mental model
- **Cons:** No automatic migrations, no change tracking, every CRUD needs hand-written SQL, repetitive boilerplate, loses relationship navigation

## Rationale

The existing BSE apps already do this informally — simple CRUD through `GenericRepository<T>`, complex reads through raw SQL. The framework formalizes this split with clear guidelines. Source generators eliminate the boilerplate problem. Dapper.AOT (by the Dapper author) provides the source-generation foundation for the query side. EF Core handles the write side with automatic migrations, change tracking, and audit interception.

## Consequences

### Positive
- Matches existing developer mental model
- Eliminates SQL injection by construction (no string concatenation possible)
- Source generators eliminate manual repository writing (kills the 240+ service registration problem)
- Best performance profile (EF for writes, Dapper for hot reads)
- Read replica routing natural (Dapper → replica, EF → primary)
- CQRS split enables separate scaling

### Negative
- Two data access patterns to learn
- Need clear guidelines on which to use when
- Source generator complexity (incremental generators required for IDE performance)
- Strongly-typed IDs need dual registration (EF ValueConverter + Dapper TypeHandler)

### Neutral
- Read models must be separate types from write entities (enforced at compile time)
- Dapper bypasses EF Core query filters — solved by PostgreSQL Row-Level Security (see ADR-0006)

## Guidelines: When to Use Which

| Use EF Core When | Use Dapper When |
|---|---|
| Single entity CRUD | Queries joining 3+ tables |
| Simple lookups by ID | Reporting / aggregation |
| Navigation properties needed | Window functions |
| Change tracking required | Bulk read-only queries |
| Schema migrations | Stored procedure calls |
| Multi-entity transactions | Performance-critical paths |
| **Rule of thumb: writing data** | **Rule of thumb: reading data** |

## References

- ADR-0006: Hybrid Multi-Tenancy (RLS for Dapper isolation)
- ADR-0008: Source Generator Automation
- RFC-0003: Data Access Layer
- Dapper.AOT: https://aot.dapperlib.dev/
- Ardalis.Specification: https://specification.ardalis.com/
