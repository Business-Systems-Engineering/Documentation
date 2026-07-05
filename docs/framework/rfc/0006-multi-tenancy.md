# RFC-0006: Multi-Tenancy

- **Status:** Implemented
- **Date:** 2026-07-05
- **Authors:** BSE Framework Team
- **Related ADRs:** ADR-0006
- **Related RFCs:** RFC-0001, RFC-0003, RFC-0004

---

## Abstract

This document is the as-built specification for BSE multi-tenancy. It covers the ambient tenant context abstraction (`ITenantContext` / `ITenantContextAccessor`), the pluggable resolver chain, three ASP.NET Core HTTP resolvers (header, host, claim), the RPC integration that propagates tenant identity across process boundaries via `TransportMessage.TenantId`, and the EF Core isolation layer (application-side RLS via global query filters + `AuditingSaveChangesInterceptor`). The design is single-isolation-strategy (shared database, query-filter scoped), anonymous-by-default, and spread across three opt-in packages: `Bse.Framework.MultiTenancy`, `Bse.Framework.MultiTenancy.AspNetCore`, and `Bse.Framework.MultiTenancy.Rpc`.

---

## Motivation

The existing BSE applications propagate tenancy through a `CompCode` parameter threaded through every controller action, service method, and repository call. This approach has several known failure modes:

- A developer who forgets to pass `CompCode` silently operates without tenant scope.
- There is no enforcement layer: a caller can pass any `CompCode` value, including one belonging to a different customer.
- Cross-process calls (messaging, batch jobs) have no standardized mechanism to carry the tenant identifier; each team solves this ad hoc.
- Reading tenancy from `IBseUser.CompCode` conflates the user's home tenant with the request's target tenant, which breaks in cross-tenant admin scenarios and in RPC hops where the user object is not carried in full.

The framework needs an ambient tenant context that propagates automatically through async call stacks, is enforced by the data layer without application-level discipline, and crosses process boundaries via the existing RPC transport envelope.

---

## Goals

- Ambient tenant context backed by `AsyncLocal<T>` — no manual parameter passing.
- Pluggable resolver chain so teams can mix header, claim, and subdomain resolution strategies in priority order.
- ASP.NET Core middleware that resolves, validates, and scopes the tenant to each HTTP request with a single `app.UseBseMultiTenancy()` call.
- EF Core isolation: a global query filter on every `IMultiTenant` entity so tenant-scoped queries are enforced without any application-level `WHERE` clause.
- Defense in depth: the save-changes interceptor stamps `TenantId` on insert and throws a `BseAuthorizationException` on cross-tenant modification even if the query filter was bypassed.
- RPC integration: `TransportMessage.TenantId` carries tenant identity across process boundaries; inbound handlers push it into the ambient accessor before handler execution.
- Anonymous-by-default: services that do not call `AddBseMultiTenancy` are unaffected; services that opt in but do not resolve a tenant receive `TenantContext.Empty` (no `TenantId`), which causes the EF query filter to match `NULL` and return zero rows — the safe default.

## Non-Goals

- Physical database-per-tenant or schema-per-tenant isolation strategies — only shared-database query-filter isolation is implemented.
- Finbuckle.MultiTenant-style per-tenant `IOptions<T>` branching — per-tenant configuration lives at the query-filter and entity-data layer, not at the DI options layer.
- A tenant store, tenant lifecycle management (provisioning, suspension, GDPR deletion), or tenant quotas.
- Per-tenant Redis streams or any transport-level tenant namespace partitioning.
- Sub-tenant or workspace hierarchies (`IOrganizationScoped`, `IWorkspaceScoped`).

---

## Design

### Package Structure

The implementation is split across three packages so services depend only on what they use:

| Package | Depends On | Registers |
|---|---|---|
| `Bse.Framework.MultiTenancy` | BSE Core | `ITenantContextAccessor`, `TenantResolverChain`, `BseMultiTenancyOptions` |
| `Bse.Framework.MultiTenancy.AspNetCore` | Core + ASP.NET Core | `TenantResolutionMiddleware`, three HTTP resolvers |
| `Bse.Framework.MultiTenancy.Rpc` | Core + `Bse.Framework.Rpc` | `TenantRpcEnvelopeScope`, `TenantOutgoingEnvelopeDecorator` |

A background service that receives tenant identity only via inbound RPC envelopes needs only Core + Rpc. An HTTP gateway needs Core + AspNetCore. A service that does both adds all three.

---

### Core Abstractions

#### ITenantContext and TenantContext

`ITenantContext` is the read-only snapshot of the tenant identity active on the current logical thread:

```csharp
// Bse.Framework.MultiTenancy.ITenantContext
public interface ITenantContext
{
    // The resolved tenant identifier, or null when no tenant is active.
    // Typically a slug (e.g. "acme"). Never a numeric id or GUID.
    string? TenantId { get; }

    // true when a tenant has been resolved; false for anonymous / system contexts.
    bool HasTenant { get; }

    // Optional metadata attached by the resolver (tier, region, plan).
    // Empty when no properties were provided; never null.
    IReadOnlyDictionary<string, string> Properties { get; }
}

// Bse.Framework.MultiTenancy.TenantContext
public sealed record TenantContext(
    string? TenantId,
    IReadOnlyDictionary<string, string> Properties) : ITenantContext
{
    // Shared empty context used for anonymous / system execution.
    // HasTenant is false; TenantId is null.
    public static readonly TenantContext Empty =
        new(TenantId: null, Properties: new Dictionary<string, string>());

    public bool HasTenant => TenantId is not null;
}
```

`TenantId` is always a `string?` slug — the framework places no constraint on format beyond being non-empty when present. Numeric identifiers and GUIDs are intentionally out-of-band; tenant slugs are stable, human-readable, and safe to log.

#### ITenantContextAccessor and AsyncLocalTenantContextAccessor

`ITenantContextAccessor` is the ambient accessor that framework components (middleware, interceptors, RPC scopes) use to read and temporarily override the current tenant:

```csharp
// Bse.Framework.MultiTenancy.Accessor.ITenantContextAccessor
public interface ITenantContextAccessor
{
    // The tenant active on the current logical thread.
    // Returns TenantContext.Empty when nothing has been pushed. Never null.
    ITenantContext Current { get; }

    // Scopes context to the current async execution context.
    // The previous context is restored when the returned IDisposable is disposed.
    // Pattern: using var scope = accessor.Push(ctx);
    IDisposable Push(ITenantContext context);
}
```

The production implementation, `AsyncLocalTenantContextAccessor`, is registered as a singleton. It stores the current context in a `static AsyncLocal<ITenantContext?>`, which propagates through async continuations while keeping each logical flow isolated from siblings spawned with `Task.Run`:

```csharp
public sealed class AsyncLocalTenantContextAccessor : ITenantContextAccessor
{
    private static readonly AsyncLocal<ITenantContext?> _current = new();

    public ITenantContext Current => _current.Value ?? TenantContext.Empty;

    public IDisposable Push(ITenantContext context)
    {
        var previous = _current.Value;
        _current.Value = context;
        return new RestoreScope(previous);   // restores _current.Value on Dispose()
    }
}
```

The inner `RestoreScope` is idempotent (double-dispose is a no-op) and handles the `using var` pattern correctly across async boundaries because `AsyncLocal<T>` writes on the current execution context flow down to child contexts but not back up to the parent — a `Push` on a child task does not pollute the parent's slot.

---

### Resolution Pipeline

#### ITenantResolver

Resolvers are single-responsibility units that attempt to identify the tenant from one source. Returning `null` signals "I cannot determine the tenant from my source; let the next resolver try":

```csharp
// Bse.Framework.MultiTenancy.Resolution.ITenantResolver
public interface ITenantResolver
{
    // Returns the resolved ITenantContext, or null to pass to the next resolver.
    ValueTask<ITenantContext?> ResolveAsync(CancellationToken cancellationToken);
}
```

#### TenantResolverChain

`TenantResolverChain` walks the registered resolvers in DI registration order and returns the first non-null result. If all resolvers return `null`, it returns `TenantContext.Empty`:

```csharp
public sealed class TenantResolverChain
{
    public async ValueTask<ITenantContext> ResolveAsync(CancellationToken ct)
    {
        foreach (var resolver in _resolvers)
        {
            var context = await resolver.ResolveAsync(ct).ConfigureAwait(false);
            if (context is null) continue;

            // Logs at Debug, EventId 5001 "TenantResolved",
            // message: "Tenant '{TenantId}' resolved by {ResolverType}"
            _logTenantResolved(_logger, context.TenantId, resolver.GetType().Name, null);

            return context;
        }
        return TenantContext.Empty;
    }
}
```

The chain never returns `null`. Anonymous flows (no resolver matched) produce `TenantContext.Empty`, which the middleware may then accept or reject based on `BseMultiTenancyOptions.RequireTenant`.

---

### DI and Builder API

```csharp
// Entry point — returns IBseFrameworkBuilder for module-level chaining.
IBseFrameworkBuilder AddBseMultiTenancy(
    this IBseFrameworkBuilder builder,
    Action<BseMultiTenancyBuilder>? configure = null);
```

`AddBseMultiTenancy` registers `ITenantContextAccessor` (singleton, `AsyncLocalTenantContextAccessor`), `BseMultiTenancyOptions` (via `AddOptions`), `BseMultiTenancyModule` (marker), and `TenantResolverChain` (singleton, registered after the configure callback so all resolver registrations are already in the container before the chain singleton resolves its `IEnumerable<ITenantResolver>` constructor argument).

`BseMultiTenancyBuilder` is the fluent builder returned inside the configure callback:

```csharp
public sealed class BseMultiTenancyBuilder
{
    // Appends TResolver to the resolver chain. Registration order = priority.
    // Uses AddSingleton (not TryAddSingleton) so multiple resolvers are preserved.
    public BseMultiTenancyBuilder AddResolver<TResolver>()
        where TResolver : class, ITenantResolver;

    // Direct access for advanced scenarios.
    public IServiceCollection Services { get; }
}
```

A typical registration for an HTTP service that accepts both a header and a JWT claim:

```csharp
builder.Services
    .AddBseFramework()
    .AddBseMultiTenancy(mt =>
    {
        mt.AddHeaderResolver()   // reads X-Tenant-Id header
          .AddClaimResolver();   // reads tenant_id JWT claim — runs second
    });
```

---

### Configuration

`BseMultiTenancyOptions` governs enforcement behavior. It is bound from `IOptions<BseMultiTenancyOptions>` and is read by `TenantResolutionMiddleware`:

```csharp
public sealed class BseMultiTenancyOptions
{
    // When true, requests without a resolved tenant throw BseValidationException
    // with field "tenant", error "required". Default: false (anonymous flows allowed).
    public bool RequireTenant { get; set; }

    // Optional allowlist. Empty = accept all tenants.
    // Non-empty + resolved tenant not in list = BseValidationException "not allowed".
    public IList<string> AllowedTenants { get; } = new List<string>();
}
```

Configuration can be set inline via the builder or via `appsettings.json` under the `"MultiTenancy"` section:

```json
{
  "MultiTenancy": {
    "RequireTenant": true,
    "AllowedTenants": ["acme", "globex", "initech"]
  }
}
```

---

### ASP.NET Core: Middleware and Resolvers

#### TenantResolutionMiddleware

`TenantResolutionMiddleware` is added to the pipeline with `app.UseBseMultiTenancy()`. It must run **after** `app.UseAuthentication()` so that `ClaimTenantResolver` sees a populated `HttpContext.User`:

```
app.UseRouting()
app.UseAuthentication()
app.UseBseMultiTenancy()   // ← tenant is now in ITenantContextAccessor.Current
app.UseAuthorization()
app.MapControllers()
```

The middleware calls the resolver chain, validates the result, and scopes it for the lifetime of the request:

```csharp
public async Task InvokeAsync(
    HttpContext context,
    TenantResolverChain chain,
    ITenantContextAccessor accessor,
    IOptions<BseMultiTenancyOptions> options,
    ILogger<TenantResolutionMiddleware>? logger = null)
{
    var tenantContext = await chain.ResolveAsync(context.RequestAborted);

    // RequireTenant + no tenant  → BseValidationException("tenant", "required")
    // AllowedTenants not empty + tenant not in list → BseValidationException("tenant", "not allowed")
    ValidateTenantContext(tenantContext, options.Value);

    using var scope = accessor.Push(tenantContext);
    await _next(context);
}
```

The `using var scope = accessor.Push(...)` pattern ensures the previous tenant context (typically `TenantContext.Empty`) is restored when the request completes, regardless of exceptions.

#### Built-In HTTP Resolvers

Three resolvers are shipped with `Bse.Framework.MultiTenancy.AspNetCore`. All depend on `IHttpContextAccessor` (auto-registered by the `AddHeaderResolver` / `AddHostResolver` / `AddClaimResolver` builder extensions).

**HeaderTenantResolver** — reads a configurable HTTP header. Default: `X-Tenant-Id`.

```csharp
// Registration
mt.AddHeaderResolver(opts => opts.HeaderName = "X-Tenant-Id");  // default
```

Returns `null` when the header is absent or empty.

**HostTenantResolver** — extracts the tenant from the request hostname using two strategies in priority order:

1. **Explicit map** — `HostTenantResolverOptions.HostToTenant` (case-insensitive dictionary). Takes priority over subdomain extraction.
2. **Subdomain extraction** — strips a leading `www.` label, then returns the leftmost DNS label as the tenant. `localhost` and `BaseDomain` (default: `example.com`) are explicitly skipped (return `null`).

```csharp
mt.AddHostResolver(opts =>
{
    opts.BaseDomain = "bse.app";
    opts.HostToTenant["app.bse.app"] = "admin";   // explicit override
});
// acme.bse.app        → "acme"
// www.acme.bse.app    → "acme"  (www. stripped first)
// bse.app             → null    (matches BaseDomain → pass to next resolver)
// localhost            → null    (localhost → pass to next resolver)
```

**ClaimTenantResolver** — reads a JWT claim from `HttpContext.User`. Default claim type: `tenant_id` (the canonical claim emitted by `Bse.Framework.Auth.Jwt`).

```csharp
mt.AddClaimResolver(opts => opts.ClaimType = "tenant_id");  // default
```

Returns `null` when the claim is absent or when there is no `HttpContext` (e.g. in a background thread without a request).

---

### RPC Integration

#### Identity Propagation: The Critical Rule

Cross-process tenancy is carried in `TransportMessage.TenantId` and is restored into `ITenantContextAccessor` on the receiving side. Handlers read the active tenant from `ITenantContextAccessor.Current` — **not** from `IBseUser.CompCode`. Reading tenancy from the user accessor conflates the user's home tenant with the request's target tenant and fails in any cross-tenant admin scenario. This is the primary footgun the RPC integration exists to prevent.

#### TenantOutgoingEnvelopeDecorator

On the publisher side, `TenantOutgoingEnvelopeDecorator` implements `IRpcOutgoingEnvelopeDecorator` and stamps the current tenant onto the outbound envelope before it is encoded and written to the transport:

```csharp
public sealed class TenantOutgoingEnvelopeDecorator : IRpcOutgoingEnvelopeDecorator
{
    public TransportMessage Decorate(TransportMessage envelope)
    {
        var current = _accessor.Current;

        // Only stamp when a tenant is active AND the envelope does not already have one.
        // The no-overwrite rule prevents callers from accidentally masking an explicitly
        // assigned tenant id (e.g. in cross-tenant admin scenarios).
        if (!current.HasTenant || envelope.TenantId is not null)
            return envelope;

        return envelope with { TenantId = current.TenantId };
    }
}
```

#### TenantRpcEnvelopeScope

On the consumer side, `TenantRpcEnvelopeScope` implements `IRpcEnvelopeScope` and pushes the inbound envelope's `TenantId` into the ambient accessor before the dispatcher resolves the handler. When the envelope carries no `TenantId`, a `NoOpDisposable` is returned and the accessor is left unchanged:

```csharp
public sealed class TenantRpcEnvelopeScope : IRpcEnvelopeScope
{
    public IDisposable Push(TransportMessage envelope)
    {
        if (envelope.TenantId is null)
            return NoOpDisposable.Instance;

        var tenantContext = new TenantContext(
            TenantId: envelope.TenantId,
            Properties: new Dictionary<string, string>(0, StringComparer.Ordinal));

        return _accessor.Push(tenantContext);
    }
}
```

The dispatcher disposes the returned `IDisposable` in a `finally` block (LIFO order across all registered `IRpcEnvelopeScope` instances), restoring the previous tenant context after the handler completes.

#### Registration

```csharp
// Option A — chain off AddBseMultiTenancy:
builder.Services
    .AddBseFramework()
    .AddBseMultiTenancy(mt => mt.AddRpcIntegration());

// Option B — separate framework builder call:
builder.Services
    .AddBseFramework()
    .AddBseMultiTenancy()
    .AddBseMultiTenancyRpcIntegration();
```

Both options register `TenantRpcEnvelopeScope` and `TenantOutgoingEnvelopeDecorator` as singletons. `AddBseMultiTenancy` must have been called before `AddBseMultiTenancyRpcIntegration` so that `ITenantContextAccessor` is already in the container.

---

### EF Core Isolation

#### IMultiTenant Marker

Entities that must be tenant-scoped implement `IMultiTenant`:

```csharp
// Bse.Framework.Data.Entities.IMultiTenant
public interface IMultiTenant
{
    // Tenant identifier (slug). Non-nullable on the entity — every persisted
    // row must have an owner. Contrast with ITenantContext.TenantId which is
    // nullable to represent the anonymous / system context.
    string TenantId { get; }
}
```

#### MultiTenantQueryFilterConvention

`MultiTenantQueryFilterConvention.Apply` is called from `BseDbContext.OnModelCreating` when a `ITenantContextAccessor` was provided to the context constructor. It adds a global query filter to every entity in the model that implements `IMultiTenant`:

```csharp
// Bse.Framework.Data.EntityFramework.Conventions (internal)
public static void Apply(ModelBuilder modelBuilder, ITenantContextAccessor accessor)
{
    foreach (var entityType in modelBuilder.Model.GetEntityTypes())
    {
        if (!typeof(IMultiTenant).IsAssignableFrom(entityType.ClrType)) continue;

        // EF.Property<string>(e, "TenantId") == accessor.Current.TenantId
        // The accessor is captured by reference — re-evaluated per query.
        // When accessor.Current.TenantId is null (anonymous context), the
        // filter becomes TenantId == null, which matches no production row
        // (safe zero-row default rather than unsafe all-rows leakage).
        modelBuilder.Entity(entityType.ClrType).HasQueryFilter(lambda);
    }
}
```

`BseDbContext.OnModelCreating` wires it up:

```csharp
protected override void OnModelCreating(ModelBuilder modelBuilder)
{
    base.OnModelCreating(modelBuilder);
    SoftDeleteQueryFilterConvention.Apply(modelBuilder);

    if (_tenantAccessor is not null)
        MultiTenantQueryFilterConvention.Apply(modelBuilder, _tenantAccessor);
}
```

Subclasses pass the accessor through one of the three `BseDbContext` constructor overloads:

```csharp
// Most common — multi-tenant with user identity stamping
protected MyDbContext(
    DbContextOptions<MyDbContext> options,
    ISystemClock clock,
    ITenantContextAccessor tenantAccessor,
    IBseUserAccessor userAccessor)
    : base(options, clock, tenantAccessor, userAccessor) { }
```

#### AuditingSaveChangesInterceptor — Tenant Enforcement

The interceptor's tenant logic runs inside `SavingChanges` / `SavingChangesAsync` over every changed `IMultiTenant` entity:

**On `EntityState.Added`**: if `TenantId` is null or empty on the entity, it is stamped from `accessor.Current.TenantId`. If both the entity and the current context have no tenant id, a `BseValidationException("tenant", "required")` is thrown — inserting a record with no owner would silently violate isolation invariants.

**On `EntityState.Modified`**: if the entity's `TenantId` does not match the current context's `TenantId`, a `BseAuthorizationException` is thrown:

```
"Cross-tenant modification not allowed: entity belongs to tenant '{entity.TenantId}',
current context is '{currentTenantId}'."
```

This is a defense-in-depth guard against a tracked entity from a prior tenant context leaking into the change tracker via `IgnoreQueryFilters()` or scope reuse. It is classified as an authorization failure (not a concurrency conflict) because retrying the same request would produce the same result.

---

### Data Flow

#### HTTP Request Path

```
HTTP Request
  │
  ├─ UseAuthentication()    → HttpContext.User populated (JWT claims available)
  │
  ├─ UseBseMultiTenancy()  → TenantResolutionMiddleware
  │     │
  │     ├─ TenantResolverChain.ResolveAsync()
  │     │     ├─ HeaderTenantResolver  (X-Tenant-Id header)?
  │     │     ├─ HostTenantResolver    (subdomain)?
  │     │     └─ ClaimTenantResolver   (tenant_id claim)?
  │     │         first non-null wins → ITenantContext
  │     │         all null → TenantContext.Empty
  │     │
  │     ├─ Validate RequireTenant + AllowedTenants
  │     │     (BseValidationException on violation)
  │     │
  │     └─ using var scope = accessor.Push(tenantContext)
  │           ITenantContextAccessor.Current = resolved tenant
  │
  ├─ Controller / Handler
  │     │
  │     └─ BseDbContext queries
  │           EF query filter: WHERE TenantId = accessor.Current.TenantId
  │           (evaluated at query time; null TenantId → zero rows)
  │
  └─ scope.Dispose()  → previous TenantContext (Empty) restored
```

#### RPC Cross-Process Path

```
Caller Process (tenant "acme" active in accessor)
  │
  ├─ IMessagePublisher.PublishAsync(stream, envelope)
  │     │
  │     └─ IRpcOutgoingEnvelopeDecorator(s) applied in order:
  │           TenantOutgoingEnvelopeDecorator
  │             HasTenant=true, envelope.TenantId=null
  │             → envelope with { TenantId = "acme" }
  │
  └─ IRpcCodec.EncodeAsync → Redis XADD

Consumer Process
  │
  ├─ IRpcCodec.DecodeAsync → TransportMessage(TenantId = "acme", ...)
  │
  ├─ RpcDispatcher.HandleAsync
  │     │
  │     ├─ IServiceScopeFactory.CreateAsyncScope()
  │     │
  │     ├─ IRpcEnvelopeScope(s) Push() in registration order:
  │     │     TenantRpcEnvelopeScope.Push(envelope)
  │     │       envelope.TenantId = "acme" → accessor.Push(TenantContext("acme"))
  │     │       ITenantContextAccessor.Current = "acme"
  │     │
  │     ├─ IRpcInvocationFilter(s)
  │     │
  │     └─ Handler.HandleAsync(request, ct)
  │           BseDbContext queries
  │           EF query filter: WHERE TenantId = "acme"
  │
  └─ finally: scope.Dispose() → accessor restored to Empty
              XACK
```

---

### Security Considerations

**Isolation default is zero rows, not all rows.** When `ITenantContextAccessor.Current.TenantId` is `null` (anonymous or system context), the EF query filter evaluates to `WHERE TenantId = NULL`, which returns no rows in SQL (NULL != NULL). This is intentional: an unauthenticated request or a misconfigured service fails closed rather than open.

**Cross-tenant write guard is defense in depth.** The EF query filter prevents reading another tenant's rows. The `AuditingSaveChangesInterceptor` adds a second, independent check that prevents writing to an entity whose `TenantId` does not match the current context, even if a row somehow entered the change tracker through `IgnoreQueryFilters()` or a scope that was reused across request boundaries. A `BseAuthorizationException` is non-retryable.

**No-overwrite rule on the outgoing decorator.** `TenantOutgoingEnvelopeDecorator` only writes `TransportMessage.TenantId` when the envelope field is `null`. An explicitly set `TenantId` (e.g. in a platform-admin cross-tenant operation) is preserved. This prevents the ambient tenant from masking intentional overrides.

**Claim resolver ordering.** Callers that place `ClaimTenantResolver` last in the chain allow a request with a valid header but an invalid claim to resolve to the header value. For environments where the JWT claim is authoritative, `ClaimTenantResolver` should be registered first (first non-null wins) and the `AllowedTenants` allowlist should be used to restrict which tenants can be resolved at all.

**`IBseUser.CompCode` is not the tenant.** The `CompCode` property on `IBseUser` represents the user's home company as recorded in the identity store. In a cross-tenant operation or a multi-hop RPC call, the user's `CompCode` may differ from the current request's tenant. Always read the active tenant from `ITenantContextAccessor.Current.TenantId`.

**Suppressing the filter.** EF Core's `IgnoreQueryFilters()` is available but unguarded by the framework. No Roslyn analyzer enforces its usage. The `AuditingSaveChangesInterceptor` cross-tenant write guard remains active regardless of `IgnoreQueryFilters()` and provides the final safety net for write paths. Teams that call `IgnoreQueryFilters()` accept responsibility for the read-path isolation of those queries.

---

### Observability

**Log event ids** — the multi-tenancy package occupies the range `5000–5099`:

| EventId | Name | Level | Message |
|---|---|---|---|
| 5001 | `TenantResolved` | Debug | `Tenant '{TenantId}' resolved by {ResolverType}` |

The `TenantResolved` log is emitted by `TenantResolverChain` via `LoggerMessage.Define` each time a resolver returns a non-null result. It records the winning resolver type so pipeline ordering issues are visible without attaching a debugger. Logs at `Information` or above are not emitted by the multi-tenancy package itself; enforcement failures surface as `BseValidationException` and `BseAuthorizationException` which the host's error-handling middleware converts to structured HTTP responses and RPC error codes.

---

### Testing Strategy

Each package ships a dedicated test project:

- **`Bse.Framework.MultiTenancy.Tests`** — unit tests covering `TenantContext` immutability, `AsyncLocalTenantContextAccessor` Push/Dispose isolation (including concurrent child tasks), `TenantResolverChain` first-wins ordering, DI registration uniqueness, and the module marker.
- **`Bse.Framework.MultiTenancy.AspNetCore.Tests`** — unit tests per resolver (`HeaderTenantResolver`, `HostTenantResolver` with explicit map and subdomain extraction, `ClaimTenantResolver`), middleware `RequireTenant` + `AllowedTenants` enforcement, and the `UseBseMultiTenancy` application builder extension.
- **`Bse.Framework.MultiTenancy.Rpc.Tests`** — unit tests for `TenantOutgoingEnvelopeDecorator` (no-overwrite rule, no-tenant no-op), `TenantRpcEnvelopeScope` (push with TenantId, `NoOpDisposable` when null), and DI registration via both extension method overloads.

EF isolation testing is covered in `Bse.Framework.Data.EntityFramework.Tests` using the in-memory SQLite provider to verify query filter behaviour across anonymous, single-tenant, and cross-tenant insert/modify scenarios.

---

## Migration Path

The following steps move a service from the legacy `CompCode`-parameter pattern to ambient multi-tenancy without a big-bang rewrite.

**Step 1 — Add the package and wire the accessor.**

```csharp
builder.Services
    .AddBseFramework()
    .AddBseMultiTenancy(mt =>
    {
        mt.AddClaimResolver();   // or AddHeaderResolver() for service-to-service
    });

// In app pipeline:
app.UseAuthentication();
app.UseBseMultiTenancy();
```

`RequireTenant` remains `false` (default), so existing anonymous flows are unaffected.

**Step 2 — Replace `CompCode` reads with `ITenantContextAccessor.Current.TenantId`.**

Before:
```csharp
public async Task<Invoice> GetInvoiceAsync(string compCode, Guid id, CancellationToken ct)
{
    var invoice = await _db.Invoices
        .Where(i => i.CompCode == compCode && i.Id == id)
        .FirstOrDefaultAsync(ct);
    // ...
}
```

After:
```csharp
public async Task<Invoice> GetInvoiceAsync(Guid id, CancellationToken ct)
{
    // accessor.Current.TenantId is set by middleware or by TenantRpcEnvelopeScope
    // EF query filter WHERE TenantId = accessor.Current.TenantId is applied automatically
    var invoice = await _db.Invoices
        .Where(i => i.Id == id)
        .FirstOrDefaultAsync(ct);
    // ...
}
```

**Step 3 — Opt the DbContext into multi-tenant query filters.**

```csharp
public class InvoiceDbContext : BseDbContext
{
    public InvoiceDbContext(
        DbContextOptions<InvoiceDbContext> options,
        ISystemClock clock,
        ITenantContextAccessor tenantAccessor,
        IBseUserAccessor userAccessor)
        : base(options, clock, tenantAccessor, userAccessor) { }

    public DbSet<Invoice> Invoices => Set<Invoice>();
}
```

Mark `Invoice` with `IMultiTenant` and add a `TenantId` column in a migration. The query filter and auto-stamp are now active.

**Step 4 — Add RPC integration for cross-service flows.**

```csharp
.AddBseMultiTenancy(mt =>
{
    mt.AddClaimResolver()
      .AddRpcIntegration();   // stamps outgoing + restores inbound
});
```

Remove all `CompCode` parameters from RPC request types. The tenant now travels in `TransportMessage.TenantId` and is available in handler code via `ITenantContextAccessor.Current.TenantId`.

**Step 5 — Enforce tenant requirement.**

Once all callers are producing a tenant context, flip the option:

```json
{ "MultiTenancy": { "RequireTenant": true } }
```

Requests that arrive without a resolvable tenant now fail fast at the middleware with a `BseValidationException` rather than silently accessing zero rows.

---

## Open Questions

**Physical isolation (database-per-tenant / schema-per-tenant).** The current implementation is shared-database only, with isolation enforced at the application layer. For regulated environments (SOC 2, HIPAA) or very large tenants, physical isolation is materially stronger. The `ITenantContextAccessor` abstraction is isolation-strategy-agnostic — a future `IDbContextFactory<T>` that routes to a per-tenant connection string could sit below `BseDbContext` without changing handler or repository code. The design decision is open: whether to build this in-house or to adopt a package such as Finbuckle.MultiTenant as the connection-routing layer.

**Per-tenant `IOptions<T>`.** Finbuckle.MultiTenant's `PerTenantOptions` extension replaces the `IOptionsSnapshot<T>` singleton with a per-tenant-resolved snapshot, enabling per-tenant JWT issuers, SMTP servers, or feature flags. This is not yet implemented. The hook would be at the `BseMultiTenancyBuilder` level: `mt.PerTenantOptions<TOptions>((opts, ctx) => { ... })`. The ambient `ITenantContextAccessor` is already in place to support this.

**PostgreSQL Row-Level Security.** The EF query filter is bypassed by raw Dapper queries, by DBA sessions, and by any code path that calls `context.Database.ExecuteSqlRaw`. PostgreSQL RLS (`ALTER TABLE ... ENABLE ROW LEVEL SECURITY; CREATE POLICY ... USING (TenantId = current_setting('app.current_tenant_id'))`) enforces isolation at the database engine and is immune to application-layer bypass. The `SET app.current_tenant_id = @t` session variable would need to be issued on every connection checkout from the pool. This is a strengthening step, not a replacement for the application-layer filter; both layers can coexist.

**Noisy-neighbor isolation.** Tenant traffic currently shares a single Redis stream per service. A high-throughput free-tier tenant can starve paid tenants. Per-tier or per-tenant stream namespacing (e.g. `bse.rpc.{service}.{tier}.requests`) is a transport-level extension and does not require any changes to the multi-tenancy abstractions.

---

## References

- [Finbuckle.MultiTenant](https://www.finbuckle.com/MultiTenant) — prior art for ambient tenant context, per-tenant options, and the resolver chain pattern
- [Microsoft SaaS Tenant Isolation Guidance (Azure)](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/tenant-isolation)
- [AWS SaaS Tenant Isolation Strategies whitepaper](https://docs.aws.amazon.com/whitepapers/latest/saas-tenant-isolation-strategies/saas-tenant-isolation-strategies.html)
- [PostgreSQL Row Security Policies](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
- [EF Core Global Query Filters](https://learn.microsoft.com/en-us/ef/core/querying/filters)
- [AsyncLocal&lt;T&gt; propagation semantics](https://learn.microsoft.com/en-us/dotnet/api/system.threading.asynclocal-1)
- ADR-0006: Multi-Tenancy Architecture Decision
- RFC-0001: Framework Overview and In-Memory Testing Rig
- RFC-0003: Data Access Layer
- RFC-0004: Auth and Security
