# RFC-0006: Multi-Tenancy

- **Status:** Approved
- **Date:** 2026-04-06
- **Related ADRs:** ADR-0006
- **Related RFCs:** RFC-0001, RFC-0003, RFC-0004, RFC-0005

## Abstract

The framework provides hybrid multi-tenancy supporting database-per-tenant, schema-per-tenant, and shared-database isolation strategies, decided per tenant. Tenant context is **ambient** (flows through DI), **automatic** (filters applied by interceptors), and **impossible to bypass** outside of explicit cross-tenant operations. Defense in depth via four layers: EF Core query filters, SaveChanges interceptor, Roslyn analyzer, and PostgreSQL Row-Level Security. Includes per-tenant Options pattern (Finbuckle-style), tenant impersonation distinct from cross-tenant ops, tenant-aware caching, sub-tenant/organization hierarchy, deployment cells for multi-region, GDPR-compliant tenant deletion, and quota enforcement.

## Motivation

The existing BSE apps have multi-tenancy via `CompCode` and `BranchCode` parameters threaded through every method call:
- Easy to forget (security risk)
- Easy to bypass (no enforcement)
- Year-based database routing built into `BaseController.BuildConnectionString()`
- Some tenants have own database, others share — handled inconsistently
- No tenant lifecycle management
- No quotas
- No per-tenant configuration
- No support for the multi-tenant patterns required by SOC 2 / HIPAA / GDPR

## Goals

- Ambient tenant context (no manual parameter passing)
- Hybrid isolation strategies (database / schema / shared) per tenant
- Defense in depth (four enforcement layers)
- Impossible to accidentally leak data across tenants
- Per-tenant configuration via standard Options pattern
- Tenant lifecycle management (provision, activate, suspend, offboard, delete)
- GDPR right-to-erasure (hard delete via crypto-shredding or DB drop)
- Multi-region data residency via deployment cells
- Tenant impersonation for support (distinct from admin cross-tenant ops)
- Quota enforcement
- Migration path from existing `CompCode`-based apps

## Non-Goals

- Replacing Finbuckle.MultiTenant (we adopt its best ideas)
- Building a custom OAuth provider (use OpenIddict)
- Cross-tenant data sharing without explicit consent (federation is future work)

## Design

### Tenant Abstraction

```csharp
public interface ITenantContext
{
    string TenantId { get; }
    string? OrganizationId { get; }   // Sub-tenant (org within tenant)
    string? WorkspaceId { get; }      // Project/team within org
    TenantInfo? CurrentTenant { get; }
    OrganizationInfo? CurrentOrganization { get; }
    WorkspaceInfo? CurrentWorkspace { get; }
    bool IsAvailable { get; }

    // ABP-style scope pattern
    IDisposable Change(string? tenantId);

    // Async execution pattern
    Task<T> ExecuteInTenantAsync<T>(string tenantId, Func<Task<T>> operation);
}

public class TenantInfo
{
    public string Id { get; init; }
    public string Name { get; init; }
    public string? DisplayName { get; init; }
    public TenantStatus Status { get; init; }
    public TenantTier Tier { get; init; }                       // Free/Pro/Enterprise
    public string? Region { get; init; }                        // For data residency
    public string IsolationStrategy { get; init; }              // Database/Schema/Shared
    public string? ConnectionString { get; init; }              // For database-per-tenant
    public IReadOnlyList<string> AllowedOrigins { get; init; }  // For tenant CORS
    public TenantQuota Quota { get; init; }
    public Dictionary<string, object> Properties { get; init; } // Extension point
}

public enum TenantStatus
{
    Provisioning,
    Active,
    Suspended,         // billing issue, read-only
    Offboarding,       // 30-day grace period
    PendingDeletion,   // grace elapsed, scheduled for hard delete
    Deleted            // crypto-shredded or DB-dropped
}

public enum TenantTier { Free, Pro, Enterprise }
```

### Tenant Resolution

Multiple composable resolvers (with cross-check):

```csharp
public interface ITenantResolver
{
    Task<TenantInfo?> ResolveAsync(HttpContext httpContext, CancellationToken ct);
}

// Built-in resolvers:
// - HostTenantResolver        (subdomain: tenant1.bse.com)
// - HeaderTenantResolver      (X-Tenant-Id header)
// - ClaimTenantResolver       (JWT claim — most secure)
// - PathTenantResolver        (/tenants/{id}/api/...)
// - RouteTenantResolver       (route parameter {tenant})
// - CertificateTenantResolver (mTLS Subject/SAN parsing)

services.AddBseMultiTenancy(tenancy => {
    tenancy.RequireTenantConsistency = true;  // CRITICAL — prevents spoofing

    tenancy.Resolvers.Add<ClaimTenantResolver>();      // Authoritative
    tenancy.Resolvers.Add<HostTenantResolver>();       // Verified against claim
    tenancy.Resolvers.Add<HeaderTenantResolver>();     // Verified against claim

    tenancy.RequireTenant = true;
    tenancy.AllowedHosts = ["*.bse.com"];
});
```

#### Cross-Check (Anti-Spoofing)

When `RequireTenantConsistency=true`:
1. `ClaimTenantResolver` runs FIRST (authenticated context)
2. If other resolvers find a tenant, they MUST match
3. Mismatch → `TenantSpoofingException` + audit event
4. Anonymous requests can use header/host

### Tenant Store

```csharp
public interface ITenantStore
{
    Task<TenantInfo?> GetByIdAsync(string tenantId, CancellationToken ct);
    Task<TenantInfo?> GetByHostAsync(string host, CancellationToken ct);
    Task<List<TenantInfo>> GetAllAsync(CancellationToken ct);
    Task<TenantInfo> CreateAsync(TenantInfo tenant, CancellationToken ct);
    Task UpdateAsync(TenantInfo tenant, CancellationToken ct);
    Task DeleteAsync(string tenantId, CancellationToken ct);
}
```

Implementations:
- `DatabaseTenantStore` (default) — tenants in master/catalog DB
- `ConfigurationTenantStore` — tenants in appsettings (small deployments)
- `CacheableTenantStore` — wraps any store with `IMemoryCache` (5min TTL)

Cache invalidation on tenant updates via Redis pub/sub.

### Hybrid Isolation Strategies

```
┌──────────────────┬─────────────────────────────────────┐
│ Database         │ Each tenant has own database        │
│                  │ Strongest isolation                  │
│                  │ For: regulated, large, enterprise    │
├──────────────────┼─────────────────────────────────────┤
│ Schema           │ Single DB, schema per tenant         │
│                  │ Moderate isolation (PostgreSQL)      │
│                  │ For: medium tenants                  │
├──────────────────┼─────────────────────────────────────┤
│ Shared           │ Single DB, TenantId column           │
│                  │ Soft isolation via query filters     │
│                  │ + RLS at database layer              │
│                  │ For: free tier, small tenants        │
└──────────────────┴─────────────────────────────────────┘
```

Per-tenant decision stored in `TenantInfo.IsolationStrategy`. Application code is identical regardless of strategy.

### Operational Limits

Honest reality check based on connection pool math:

| Tenant Count | Recommended Strategy |
|---|---|
| 1-50 | Database-per-tenant OK |
| 50-200 | Schema-per-tenant + PgBouncer |
| 200-2000 | Shared DB + RLS |
| 2000+ | Cell-based deployment (sharded) |

Database-per-tenant strategy:
- Hard limit: ~50 tenants per Postgres host
- Beyond 50: requires PgBouncer/Supavisor in transaction pooling mode
- Even with PgBouncer: minimum one Postgres connection per tenant DB
- Beyond 200 tenants per host: cell-based deployment required

### Database Connection Routing

```csharp
public interface ITenantConnectionResolver
{
    Task<string> GetConnectionStringAsync(string tenantId, CancellationToken ct);
    Task<string> GetReadReplicaAsync(string tenantId, CancellationToken ct);
}
```

Per-request flow:
1. Tenant resolved → `TenantInfo` loaded from store (cached)
2. `ITenantConnectionResolver` returns connection string based on strategy
3. `PooledDbContextFactory` checks out a context, sets connection
4. After request: context returned to pool

#### Connection Pool Safeguards

- Per-tenant pools with `MinPoolSize=0`, `ConnectionIdleLifetime=60s`
- `MaxPoolSize=5-10` per tenant (defensive, not unlimited)
- Framework-wide tenant pool budget with LRU eviction
- Metric: `bse.data.connection_pool.active` per tenant
- Warning: `bse.data.tenant_pools.budget_utilization > 80%`

### Defense in Depth — Four Layers

#### Layer 1: EF Core Query Filters

```csharp
protected override void OnModelCreating(ModelBuilder modelBuilder)
{
    foreach (var entityType in modelBuilder.Model.GetEntityTypes())
    {
        if (typeof(IMultiTenant).IsAssignableFrom(entityType.ClrType))
        {
            // Apply tenant filter via reflection
            var method = typeof(BseDbContext)
                .GetMethod(nameof(SetTenantFilter), BindingFlags.NonPublic | BindingFlags.Instance)!
                .MakeGenericMethod(entityType.ClrType);
            method.Invoke(this, new object[] { modelBuilder });
        }
    }
}

private void SetTenantFilter<T>(ModelBuilder mb) where T : class, IMultiTenant
{
    mb.Entity<T>().HasQueryFilter(e => e.TenantId == _tenant.TenantId);
}
```

Tenant filter is **NEVER removable** via application code. `IgnoreQueryFilters()` is not exposed in `IRepository<T>` or `Specification<T>`.

#### Layer 2: SaveChangesInterceptor

```csharp
public class TenantInsertInterceptor : SaveChangesInterceptor
{
    public override ValueTask<InterceptionResult<int>> SavingChangesAsync(...)
    {
        foreach (var entry in dbContext.ChangeTracker.Entries<IMultiTenant>())
        {
            if (entry.State == EntityState.Added)
            {
                // Auto-assign current tenant — developer never sets it
                entry.Property(nameof(IMultiTenant.TenantId)).CurrentValue = _tenant.TenantId;
            }
            else if (entry.State == EntityState.Modified)
            {
                // SECURITY: prevent tenant ID tampering
                if (entry.OriginalValues[nameof(IMultiTenant.TenantId)] != _tenant.TenantId)
                {
                    throw new CrossTenantViolationException(...);
                }
            }
        }
    }
}
```

#### Layer 3: Roslyn Analyzer

Compile-time enforcement:
- `BSE0004 ERROR`: `IgnoreQueryFilters()` call outside `BseUnfilteredDbContext`
- `BSE0010 ERROR`: Direct `_dbContext.Set<T>()` access in tenant-scoped service (must use `IRepository<T>`)
- `BSE0011 ERROR`: Manual `WHERE TenantId = ...` clause in `[Query]` SQL (use RLS instead)

#### Layer 4: PostgreSQL Row-Level Security (CRITICAL)

Why Layer 4 is critical:
- **Dapper bypasses EF Core query filters entirely**
- DBA queries during incidents bypass application code
- Future code paths added without tenant awareness still safe
- SOC 2 / HIPAA auditors strongly prefer database-level enforcement

Implementation:

```sql
-- One-time migration per multi-tenant table:
ALTER TABLE Students ENABLE ROW LEVEL SECURITY;
ALTER TABLE Students FORCE ROW LEVEL SECURITY;  -- applies even to table owner

CREATE POLICY tenant_isolation ON Students
  USING (TenantId = current_setting('app.current_tenant_id')::text);
```

On every connection acquisition (both EF Core and Dapper):
```sql
SET app.current_tenant_id = @currentTenant;
```

For cross-tenant operations:
```sql
RESET app.current_tenant_id;
-- Connection runs as privileged role (audited)
```

Performance: 1-3% overhead (profiled in Crunchy Data benchmarks).

SQL Server equivalent:
```sql
CREATE SECURITY POLICY TenantPolicy
  ADD FILTER PREDICATE dbo.fn_TenantPredicate(TenantId) ON Students
  WITH (STATE = ON);
```

### Per-Tenant Options Pattern (Finbuckle-Style)

The framework's most distinctive feature — adopted from Finbuckle.MultiTenant:

```csharp
services.AddBseMultiTenancy(tenancy => {
    tenancy.PerTenantOptions<JwtBearerOptions>((options, tenantInfo) => {
        options.Authority = tenantInfo.Properties["IssuerUrl"]?.ToString();
    });

    tenancy.PerTenantOptions<RedisStreamsOptions>((options, tenantInfo) => {
        if (tenantInfo.Tier == TenantTier.Enterprise)
            options.StreamPrefix = $"tenant:{tenantInfo.Id}:";
    });

    tenancy.PerTenantOptions<EmailOptions>((options, tenantInfo) => {
        options.FromAddress = tenantInfo.Properties["FromEmail"]?.ToString();
        options.SmtpServer = tenantInfo.Properties["SmtpServer"]?.ToString();
    });
});
```

Any framework or third-party library that uses `IOptions<T>` automatically becomes tenant-aware.

### Sub-Tenants / Organizations / Workspaces

First-class hierarchy: Tenant → Organization → Workspace (replaces implicit `BranchId`):

```csharp
public interface IOrganizationScoped : IMultiTenant
{
    string OrganizationId { get; }
}

public interface IWorkspaceScoped : IOrganizationScoped
{
    string WorkspaceId { get; }
}
```

Query filters cascade:
```
IMultiTenant       → WHERE TenantId = @t
IOrganizationScoped → WHERE TenantId = @t AND OrganizationId = @o
IWorkspaceScoped    → WHERE TenantId = @t AND OrganizationId = @o AND WorkspaceId = @w
```

Permission model respects hierarchy:
- `Tenant.Admin` → can do anything in tenant
- `Organization.Admin` → can do anything in organization
- `Workspace.Admin` → can do anything in workspace
- `Workspace.Member` → can do limited things in workspace

User can belong to multiple workspaces in multiple organizations. JWT carries: `tenant`, `allowed_organizations[]`, `allowed_workspaces[]`, `current_active`.

### Cross-Tenant Operations (Platform Admin)

```csharp
public interface ICrossTenantContext
{
    Task<T> ExecuteInTenantAsync<T>(string tenantId, Func<Task<T>> operation);
    Task ExecuteAcrossTenantsAsync(Func<TenantInfo, Task> operation, bool parallel = false);
}

public class PlatformAdminService
{
    [RequirePermission("Platform.Admin")]
    public async Task GenerateGlobalReport()
    {
        await _crossTenant.ExecuteAcrossTenantsAsync(async tenant => {
            // Code runs in each tenant's context
            // Filters apply per-tenant
            var students = await _studentRepo.GetAllAsync();
        });
    }
}
```

Audit:
- Every cross-tenant operation logged
- `audit.tenant.cross_tenant_access` event
- Real user, target tenants, operation, duration
- Alert configured for unusual patterns

### Tenant Impersonation (Distinct from Cross-Tenant)

See RFC-0004 for full details. Key distinction:

| Cross-Tenant Ops | Impersonation |
|---|---|
| Identity = admin only | Identity = support engineer + tenant user |
| Automated/scripted | Interactive |
| No customer approval | Customer-approvable |
| Maintenance/reporting | "See what tenant sees" |

### Tenant Context in RPC

Tenant flows through `TransportMessage.Auth` automatically:

```
Service A (tenant-a request):
  ICurrentUser.TenantId = "tenant-a"
  → RPC call to billing service
  → tenant in JWT in TransportMessage.Auth

Service B (billing):
  AuthContextMiddleware extracts tenant
  ITenantContext.TenantId = "tenant-a"
  All queries automatically filtered to tenant-a
```

### Tenant Context in Background Jobs

```csharp
public class ReportGenerationJob : IBackgroundJob
{
    public async Task ExecuteAsync(JobContext ctx)
    {
        // Tenant captured at scheduling time
        await using var scope = await _tenantManager.SetTenantAsync(ctx.TenantId);

        // ITenantContext returns ctx.TenantId
        // All queries scoped to that tenant
        await GenerateReport();
    }
}
```

### Tenant-Scoped Services

```csharp
services.AddBseMultiTenancy(tenancy => {
    tenancy.AddTenantScoped<ITenantConfigService, TenantConfigService>();
});
```

Resolved per-tenant:
- First request for tenant A → instance created, cached
- Subsequent requests for tenant A → same instance
- First request for tenant B → new instance for tenant B
- Cache evicted when tenant suspended/deleted

### Tenant-Aware Caching (CRITICAL)

Mandatory key prefixing — wrapper, not developer discipline:

```csharp
public interface ITenantAwareCache
{
    Task<T?> GetAsync<T>(string key, CancellationToken ct);
    Task SetAsync<T>(string key, T value, TimeSpan ttl, CancellationToken ct);
    Task RemoveAsync(string key, CancellationToken ct);
    Task RemoveAllForTenantAsync(string tenantId, CancellationToken ct);
}
```

Implementation prefixes ALL keys:
```
cache.GetAsync("user:123") → Redis key: "t:tenant-a:user:123"
```

Roslyn analyzer FORBIDS direct `IDistributedCache` injection in tenant-scoped services:
> Compile error: "Use ITenantAwareCache in tenant-scoped services to prevent cache leaks"

Tenant lifecycle integration:
```csharp
public class CacheEvictionHandler : INotificationHandler<TenantSuspendedEvent>
{
    public async Task HandleAsync(TenantSuspendedEvent evt)
    {
        await _cache.RemoveAllForTenantAsync(evt.TenantId);
    }
}
```

Per-tenant cache size limits:
- Free tier: 10MB max per tenant
- Pro tier: 100MB max per tenant
- Enterprise: unlimited

### Tenant Provisioning Pipeline

```csharp
public interface ITenantProvisioner
{
    Task<TenantInfo> ProvisionAsync(ProvisionRequest request, CancellationToken ct);
}

public class TenantProvisioner : ITenantProvisioner
{
    public async Task<TenantInfo> ProvisionAsync(ProvisionRequest req, CancellationToken ct)
    {
        // 1. Validate (tenant ID unique, host not taken, etc.)
        await _validator.ValidateAsync(req);

        // 2. Create tenant record (status = Provisioning)
        var tenant = await _store.CreateAsync(new TenantInfo {
            Status = TenantStatus.Provisioning, ...
        });

        // 3. Provision database (if Database isolation strategy)
        if (tenant.IsolationStrategy == "Database")
        {
            await _dbProvisioner.CreateDatabaseAsync(tenant);
            await _migrator.MigrateAsync(tenant.ConnectionString);
        }

        // 4. Seed initial data (admin user, default roles)
        await _seeder.SeedAsync(tenant);

        // 5. Configure observability (Mimir tenant, Loki tenant)
        await _observabilityProvisioner.RegisterTenantAsync(tenant);

        // 6. Activate
        tenant.Status = TenantStatus.Active;
        await _store.UpdateAsync(tenant);

        // 7. Audit
        await _auditLogger.LogAsync("tenant.provisioned", new { tenant.Id });

        return tenant;
    }
}
```

### Tenant Migration Runner

```csharp
public interface ITenantMigrationRunner
{
    Task<MigrationReport> MigrateAllAsync(MigrationOptions options, CancellationToken ct);
    Task<MigrationReport> MigrateTenantAsync(string tenantId, CancellationToken ct);
    Task<DriftReport> DetectDriftAsync(CancellationToken ct);
}

public class MigrationOptions
{
    public int Parallelism { get; set; } = 10;
    public bool ContinueOnError { get; set; } = true;
    public TimeSpan PerTenantTimeout { get; set; } = TimeSpan.FromMinutes(5);
    public bool DryRun { get; set; } = false;
    public string[]? OnlyTenants { get; set; }
    public string[]? ExcludeTenants { get; set; }
    public bool CanaryFirst { get; set; } = true;  // 1% canary then full rollout
}
```

Per-tenant state in `tenant_migrations` table:
- Skips already-migrated tenants on restart
- Per-tenant advisory lock prevents concurrent migration
- Schema drift audit endpoint compares tenant DBs to target schema
- Forward-only philosophy (Flyway-style)
- Expand/contract for breaking changes

### Tenant Migration Between Strategies

When tenant grows from Free to Enterprise:
```
Free (shared DB) → Enterprise (database-per-tenant)
```

Migration process:
1. Provision new database for tenant
2. Schema migrate
3. Copy tenant rows from shared DB to new DB (online, batched)
4. Verify row counts match
5. Update `TenantInfo.IsolationStrategy = "Database"`
6. Update `TenantInfo.ConnectionString`
7. Schema cache invalidation (Redis pub/sub)
8. Background: delete tenant rows from shared DB after grace period

Reverse migration (consolidation) supported similarly.

### Deployment Cells (Multi-Region)

```
┌──────────────────────────────────────────────┐
│   Global Tenant Routing Service              │
│   (DNS/edge: Cloudflare Workers, Front Door) │
│   Maps: tenant_id → cell_url                 │
└────────────┬─────────────────────────────────┘
             │
     ┌───────┼───────┬───────┬───────┐
     ▼       ▼       ▼       ▼       ▼
  ┌──────┐┌──────┐┌──────┐┌──────┐┌──────┐
  │Cell 1││Cell 2││Cell 3││Cell 4││Cell 5│
  │ EU-W ││ EU-W ││ US-E ││ US-W ││ AP-S │
  │t1-50 ││t51-99││t100..││t150..││t200..│
  └──────┘└──────┘└──────┘└──────┘└──────┘
```

Each cell:
- Own database cluster
- Own Redis cluster
- Own observability stack (or shared with `X-Scope-OrgID`)
- Own KMS/Key Vault (region-pinned for data residency)
- ~50-200 tenants per cell

GDPR data residency enforcement:
- EU tenants pinned to EU cells, NEVER processed in US/AP
- Background jobs scheduled to region-pinned queues
- Cross-region writes throw `RegionViolationException`
- Encryption keys per region in regional KMS

Cross-region failover:
- Active-passive per cell with async replication to paired region
- RPO: ~minutes
- RTO: ~minutes

### GDPR-Compliant Tenant Deletion

```
Active → Suspended → Offboarding → PendingDeletion → Deleted
```

| State | Behavior |
|---|---|
| Active | Normal operation |
| Suspended | Read-only (billing issue), data preserved |
| Offboarding | No access, 30-day grace period for data export |
| PendingDeletion | Grace period elapsed, scheduled for hard delete |
| Deleted | Crypto-shredded or DB-dropped, only audit trail remains |

Hard deletion process:

**Database-per-tenant:**
1. Verify tenant in `PendingDeletion` state past grace period
2. Final data export available for audit
3. `DROP DATABASE tenant_xxx;`
4. Remove tenant record from catalog
5. Audit: `tenant.deleted` event

**Shared DB (crypto-shredding):**
1. Each tenant's data encrypted with per-tenant DEK
2. DEK stored in KMS keyed by tenant ID
3. Deletion = destroy DEK in KMS
4. Encrypted data on disk becomes unrecoverable
5. Background job sweeps unrecoverable rows over time
6. Audit: `tenant.crypto_shredded` event

**Backups:**
- Documented retention (30 days default)
- Restore from backup re-triggers deletion automatically

**Pre-deletion data export (GDPR Article 20):**
```csharp
public interface ITenantExporter
{
    Task<string> ExportAsync(string tenantId, CancellationToken ct);
    // Returns: secure download URL with short TTL
}
```

### Tenant Quotas

```csharp
public class TenantQuota
{
    public int MaxUsers { get; set; }
    public long MaxStorageBytes { get; set; }
    public int MaxApiCallsPerHour { get; set; }
    public int MaxConcurrentSessions { get; set; }
    public int MaxBackgroundJobsPerDay { get; set; }
}
```

Enforcement points:
- Auth: rate limiting per tenant
- Data: storage usage tracked, blocked when over quota
- RPC: per-tenant request rate limiting
- Background jobs: queue depth check before scheduling
- Sessions: `ISessionManager` enforces concurrent limit

Metrics:
```
bse.tenant.quota.users.used / bse.tenant.quota.users.limit
bse.tenant.quota.storage.used / bse.tenant.quota.storage.limit
```

### Tenant Lifecycle Events

```csharp
public record TenantProvisionedEvent(string TenantId, DateTime ProvisionedAt) : IDomainEvent;
public record TenantActivatedEvent(string TenantId) : IDomainEvent;
public record TenantSuspendedEvent(string TenantId, string Reason) : IDomainEvent;
public record TenantOffboardingEvent(string TenantId, DateTime GracePeriodEndsAt) : IDomainEvent;
public record TenantDeletedEvent(string TenantId, DateTime DeletedAt) : IDomainEvent;
public record TenantUpgradedEvent(string TenantId, TenantTier From, TenantTier To) : IDomainEvent;
```

### Per-Tenant Streams (Noisy Neighbor Defense)

Redis Streams per tenant tier (not per individual tenant):
```
rpc.enterprise:{service}:{method}     ← Enterprise tier traffic
rpc.pro:{service}:{method}            ← Pro tier traffic
rpc.free:{service}:{method}           ← Free tier traffic
```

Free-tier flood cannot starve Enterprise traffic.

### MultiTenancySides (ABP Pattern)

```csharp
public enum MultiTenancySides
{
    Host = 1,    // Cross-tenant only
    Tenant = 2,  // Within a tenant context only
    Both = 3
}

[MultiTenancySide(MultiTenancySides.Host)]
public class PlatformAdminService { }

[MultiTenancySide(MultiTenancySides.Tenant)]  // default
public class StudentService { }
```

Startup validation:
- Host services CANNOT depend on tenant-side entities
- Tenant services CANNOT depend on host-only data
- Catches mistakes at startup

### Multi-Tenancy in Telemetry

(See RFC-0005 for details.)

- `tenant_tier` as bounded label (Free/Pro/Enterprise)
- Per-tenant via Mimir `X-Scope-OrgID` (NOT vanilla Prometheus)
- `tenant.id` in span attributes (Tempo)
- `tenant.id` in structured metadata (Loki, NOT label)
- Cost attribution via `count_connector`

### Migration from Existing Apps

Stud2/SafePack2/Orange2 already have multi-tenancy via `CompCode`/`BranchCode`:

| Current | Framework |
|---|---|
| `CompCode` | `TenantInfo.Id` |
| `BranchCode` | `TenantInfo.OrganizationId` |
| Year DB | `TenantInfo.ConnectionString` (varies by year) |

#### Phase 1: Adopt framework, keep existing connection logic
- `ITenantContext` returns `CompCode` as `TenantId`
- `ITenantConnectionResolver` returns existing dynamic connection string
- Application code unchanged

#### Phase 2: Move tenant config to tenant store
- Tenants migrated to tenant catalog DB
- Resolution moves from request params to JWT claims
- `CompCode` parameter removed from controller signatures

#### Phase 3: Apply isolation strategies
- Large tenants → database-per-tenant
- Small tenants → consolidate to shared DB
- Tenant filters applied automatically

## Future Work

### Reseller Hierarchy (B2B2B)
- Reseller → owns multiple Tenants
- Visibility across owned tenants
- Billing rolled up to Reseller
- Per-Reseller branding cascades

### Tenant Federation
- Two tenants explicitly consent to share specific data
- Federation contract (audited by both sides)
- Different from impersonation (consent-based)

### User-to-Multiple-Tenants
- Single user identity belongs to multiple tenants (Slack/Notion model)
- JWT carries: `allowed_tenants[] + active_tenant`
- Tenant switcher in UI without re-login

## References

- ADR-0006
- Finbuckle.MultiTenant: https://www.finbuckle.com/MultiTenant
- ABP Framework multi-tenancy
- AWS PostgreSQL RLS for Multi-Tenant
- AWS Deployment Stamps Pattern
- AWS SaaS Tenant Isolation Strategies whitepaper
