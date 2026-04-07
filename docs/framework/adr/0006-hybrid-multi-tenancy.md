# ADR-0006: Hybrid Multi-Tenancy with Per-Tenant Isolation Strategy

- **Status:** Accepted
- **Date:** 2026-04-06
- **Tags:** multi-tenancy, isolation, data-residency

## Context

The existing BSE apps have multi-tenancy via `CompCode` and `BranchCode` parameters threaded through every method, with year-based database routing built into `BaseController.BuildConnectionString()`. Some tenants have their own database (large/regulated customers), while others share a database (small customers). Tenant isolation is enforced manually via `WHERE CompCode = @CompCode` clauses — easy to forget, easy to bypass. We need a framework that supports both isolation strategies, makes tenant context ambient, and makes isolation impossible to bypass.

## Decision

Implement **hybrid multi-tenancy** with per-tenant isolation strategy decided by tenant tier:
- **Database-per-tenant** for Enterprise tier and regulated customers (strongest isolation)
- **Schema-per-tenant** for Pro tier (PostgreSQL, moderate isolation)
- **Shared database** with row-level isolation for Free tier

Defense in depth via **four enforcement layers**: EF Core query filters, SaveChanges interceptor, Roslyn analyzer, and **PostgreSQL Row-Level Security (RLS)**.

## Options Considered

### Option A: Database-Per-Tenant Only
- **Pros:** Strongest isolation, easiest migration of existing data, simple mental model
- **Cons:** Connection pool exhaustion at scale (~50 tenants/host), expensive for small tenants, hard to operate at 1000+ tenants

### Option B: Schema-Per-Tenant Only
- **Pros:** Single connection pool, moderate isolation, simpler ops than per-DB
- **Cons:** PostgreSQL-specific, schema migrations complex, less isolation

### Option C: Shared Database with TenantId Column
- **Pros:** Simplest infrastructure, scales to many tenants, single migration
- **Cons:** Weakest isolation, query filter bugs leak data, no physical separation

### Option D: Hybrid (Per-Tenant Strategy)
- **Pros:** Right tool per tenant — Enterprise gets isolation, Free tier gets cost efficiency, supports growth (Free → Enterprise migration)
- **Cons:** More complex framework, requires per-tenant routing logic

## Rationale

The existing BSE apps already do this informally (some tenants have own DB, others share). Hybrid formalizes the pattern. Per-tenant decision is stored in `TenantInfo.IsolationStrategy`. The framework routes connections automatically. Migration between strategies is supported (Free tenant grows → migrate to Database isolation).

The defense-in-depth model is critical because **Dapper bypasses EF Core query filters entirely**. RLS at the database layer protects against:
- Application bugs that bypass filters
- Direct Dapper queries
- DBA queries during incidents
- Future code paths added without tenant awareness

## Consequences

### Positive
- Tenants get the isolation they need (and pay for)
- Migration path between strategies
- Defense in depth — RLS protects even if application code has bugs
- Strong story for SOC 2 / HIPAA auditors
- Tenant context flows through RPC, background jobs, and DI automatically
- Tampering prevention via SaveChanges interceptor

### Negative
- Connection pool math is brutal for database-per-tenant (~50 tenants/host limit)
- Beyond 50 tenants per host: requires PgBouncer or Supavisor in transaction pooling mode
- RLS adds 1-3% query overhead
- More complex framework code (per-tenant routing, RLS setup)
- Requires careful pool budget management

### Neutral
- Cell-based deployment for >2000 tenants (deployment stamps pattern)
- Per-tenant rate limiting via tier-based Redis Streams
- Cross-region data residency via region-pinned cells

## Operational Limits

| Tenant Count | Recommended Strategy |
|---|---|
| 1-50 | Database-per-tenant |
| 50-200 | Schema-per-tenant + PgBouncer |
| 200-2000 | Shared DB + RLS |
| 2000+ | Cell-based deployment |

## References

- ADR-0003: EF Core + Dapper Hybrid
- RFC-0006: Multi-Tenancy
- AWS PostgreSQL RLS for Multi-Tenant
- Finbuckle.MultiTenant
- ABP Framework multi-tenancy
