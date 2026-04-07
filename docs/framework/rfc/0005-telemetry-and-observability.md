# RFC-0005: Telemetry and Observability

- **Status:** Approved
- **Date:** 2026-04-06
- **Related ADRs:** ADR-0005
- **Related RFCs:** RFC-0001, RFC-0002, RFC-0003, RFC-0004, RFC-0006

## Abstract

The framework provides full-stack observability via OpenTelemetry SDK, exporting through OTLP to a Grafana stack (Tempo for traces, Loki for logs, Prometheus/Mimir for metrics). Each framework package auto-instruments its own concerns. The design emphasizes cardinality discipline, exemplars for metric-trace correlation, two-tier collector deployment for tail sampling, base-2 exponential histograms, OpenTelemetry semantic conventions, multi-tenant isolation via Mimir/Loki/Tempo `X-Scope-OrgID`, and strict separation between observability logs (ephemeral debugging) and audit logs (compliance evidence).

## Motivation

The existing BSE apps have inconsistent or absent observability:
- **Stud2 / Orange2:** No logging framework at all
- **SafePack2:** Prometheus metrics only (no traces, no logs)
- No distributed tracing
- No centralized log search
- No dashboards
- Production debugging requires SSH + `tail -f`

The framework needs unified observability that supports the new distributed RPC architecture, multi-tenant deployment, and modern compliance requirements.

## Goals

- Three signals (logs, traces, metrics) unified in one UI
- Distributed tracing across service boundaries via W3C Trace Context
- Auto-instrumentation in every framework package
- Multi-tenant observability with isolation
- Cardinality discipline (prevent metric storage explosions)
- Pre-built Grafana dashboards
- PII redaction
- Configurable sampling for cost management
- Health checks aggregated across packages
- Default Docker Compose deployment

## Non-Goals

- Building a custom observability backend (use Grafana stack)
- Replacing audit logs (separate system, see RFC-0004)
- Real User Monitoring (RUM) for frontends — separate concern

## Design

### Unified Telemetry Configuration

```csharp
services.AddBseTelemetry(telemetry => {
    telemetry.ServiceName = "student-service";
    telemetry.ServiceVersion = "1.2.0";
    telemetry.Environment = "production";

    telemetry.UseOtlpExporter();
    // Endpoint from OTEL_EXPORTER_OTLP_ENDPOINT env var

    telemetry.Traces.SamplingRatio = 0.1;  // 10% in prod
    telemetry.Metrics.ExportInterval = TimeSpan.FromSeconds(10);
    telemetry.Metrics.SetExemplarFilter(ExemplarFilterType.TraceBased);
    telemetry.Logs.IncludeScopes = true;
});
```

### Three Signals

```
┌─────────────────────────────────────────────────────────────┐
│                  Application Code                            │
│   ILogger<T>           ActivitySource          Meter         │
│   (logs)                (traces)                (metrics)     │
└──────┬──────────────────────┬──────────────────────┬─────────┘
       │                      │                      │
       │                  OpenTelemetry SDK          │
       │                                              │
┌──────▼──────────────────────▼──────────────────────▼─────────┐
│              OpenTelemetry Collector                          │
│           (sidecar or standalone deployment)                  │
└──────┬──────────────────────┬──────────────────────┬─────────┘
       │                      │                      │
┌──────▼──────┐        ┌──────▼──────┐        ┌──────▼──────┐
│    Loki     │        │    Tempo    │        │  Prometheus │
│   (logs)    │        │   (traces)  │        │  / Mimir    │
└──────┬──────┘        └──────┬──────┘        └──────┬──────┘
       │                      │                      │
       └──────────────────────┼──────────────────────┘
                              │
                       ┌──────▼──────┐
                       │   Grafana   │
                       │ (dashboards)│
                       └─────────────┘
```

### Auto-Instrumentation by Package

| Package | Instruments |
|---|---|
| `Bse.Framework.Core` | Health check results, service lifecycle events, graceful shutdown duration |
| `Bse.Framework.Rpc` | RPC request duration, in-flight, message size, deserialization time |
| `Bse.Framework.Rpc.RedisStreams` | Stream length, consumer lag, pending messages, DLQ depth, XADD/XREADGROUP latency, redelivery count |
| `Bse.Framework.Rpc.Http` | Standard ASP.NET Core (HttpContext) |
| `Bse.Framework.Data.EntityFramework` | Query duration, command count, connection pool utilization, change tracker size, SaveChanges duration, retry count |
| `Bse.Framework.Data.Dapper` | Query duration per `[Query]` method, connection acquisition time |
| `Bse.Framework.Auth` | Login attempts, session creation, permission checks, MFA challenges, lockouts |
| `Bse.Framework.MultiTenancy` | Tenant resolution duration, active tenants, per-tenant request rate |

### Distributed Tracing

W3C Trace Context propagation (`traceparent`, `tracestate` headers).

```
Service A                        Service B                       Service C
─────────                        ─────────                       ─────────
ActivitySource.StartActivity()
   ↓ creates span A
   ↓ traceparent: 00-{traceId}-{spanA}-01
   ↓
RPC call → injects traceparent
                        Reads traceparent
                        ActivitySource.StartActivity(parent: spanA)
                           ↓ creates span B (child of A)
                           ↓
                        DB query → child span B.1
                        Redis call → child span B.2
                           ↓
                        RPC call → injects traceparent
                                                Reads traceparent
                                                Creates span C (child of B)
```

### ActivitySource Naming

```
Bse.Rpc                  — RPC framework spans
Bse.Rpc.RedisStreams     — Redis Streams transport spans
Bse.Data.EntityFramework — EF Core query spans
Bse.Data.Dapper          — Dapper query spans
Bse.Auth                 — Auth spans
Bse.MultiTenancy         — Tenant resolution spans
{ServiceName}            — Application code uses service-named source
```

### OpenTelemetry Semantic Conventions

Set `OTEL_SEMCONV_STABILITY_OPT_IN=database,rpc/dup` for stable conventions.

```
Resource attributes (every span/metric/log):
  service.name              — service name
  service.version           — service version
  service.instance.id       — instance identifier
  deployment.environment    — production/staging/dev

RPC spans (stable RC 2025):
  rpc.system                = "jsonrpc"
  rpc.service               = target service
  rpc.method                = method name
  rpc.jsonrpc.version       = "2.0"
  rpc.jsonrpc.request_id    = MessageId
  bse.tenant.id             = tenant context
  bse.user.id               = authenticated user (NOT username)

DB spans (stable May 2025):
  db.system.name            = "mssql" / "postgresql"
  db.namespace              = database name
  db.operation.name         = SELECT/INSERT/UPDATE/DELETE
  db.collection.name        = table name
  db.query.summary          = sanitized query summary
  -- NOT db.query.text by default (cardinality + PII risk)

Messaging spans (Redis Streams):
  messaging.system              = "redis_streams"
  messaging.destination.name    = stream name
  messaging.operation           = publish/receive/process
  messaging.consumer.group.name = consumer group
  messaging.message.id          = message ID
```

### Metrics

#### Naming Conventions

- Dot-separated, lowercase
- UCUM units (`s` for seconds, `By` for bytes, `1` dimensionless)
- DROP `.total` suffix from counter names — Prometheus exporter appends `_total` automatically
- Avoid `bse_rpc_requests_total_total` confusion

#### Histograms — Base-2 Exponential

All duration histograms use `Base2ExponentialBucketHistogramAggregation`:
- Better dynamic range than fixed buckets
- Native histogram support in Prometheus 3.x
- ~10x storage savings

#### Exemplars

`SetExemplarFilter(ExemplarFilterType.TraceBased)` enables click-through from a Prometheus metric spike directly to a Tempo trace in Grafana — highest-ROI feature, near-zero cost.

#### Metric Catalog

```
Counters:
  bse.rpc.requests              {service, method, status}
  bse.rpc.errors                {service, method, error_code}
  bse.auth.logins               {tenant_tier, status}
  bse.auth.permission_denied    {tenant_tier, permission}
  bse.data.queries              {provider, operation}

Histograms:
  bse.rpc.request.duration      {service, method}        (s, exponential)
  bse.rpc.message.size          {direction}              (By)
  bse.data.query.duration       {provider, operation}    (s, exponential)
  bse.auth.login.duration       {tenant_tier}            (s)
  bse.cache.lookup.duration     {cache_name, hit}        (s)

Gauges:
  bse.rpc.requests.active       {service}
  bse.rpc.consumer.lag          {stream, consumer_group}
  bse.rpc.dlq.depth             {service}
  bse.rpc.circuit_breaker.state {remote_service}
  bse.data.connection_pool.active {pool_name}
  bse.auth.sessions.active      {tenant_tier}
  bse.tenant.active             {environment}

Up-down counters:
  bse.rpc.consumer.in_flight    {stream}
```

#### Cardinality Discipline (CRITICAL)

**NEVER as labels:**
- `user_id`, `request_id`, `session_id`, `trace_id`
- raw `tenant_id` (unless using Mimir multi-tenancy)
- email, IP, full URL paths with IDs

**Bounded labels OK:**
- `service.name`, `environment`, `rpc.method`, `rpc.service`
- `db.operation.name`, `http.response.status_code`
- `tenant_tier` (free/pro/enterprise)

**Startup-time validation:**
The framework includes a Roslyn analyzer that scans Meter declarations and fails fast at startup if denylisted labels are detected:

```csharp
private static readonly string[] DenylistedLabels = {
    "user_id", "user", "email", "request_id", "trace_id", "span_id",
    "session_id", "tenant_id" /* unless using Mimir */, "ip_address",
    "url", "path" /* must be route template, not actual path */
};
```

### Logs

Default: `Microsoft.Extensions.Logging` + OpenTelemetry bridge.

```csharp
options.IncludeFormattedMessage = true;
options.IncludeScopes = true;
options.ParseStateValues = true;
```

Optional: `Bse.Framework.Telemetry.Serilog` package for teams that want Serilog enrichers.

#### Structured Logging

```csharp
using (_logger.BeginScope(new {
    TraceId = Activity.Current?.TraceId,
    SpanId = Activity.Current?.SpanId,
    CorrelationId = correlationId,
    TenantId = currentUser.TenantId,
    UserId = currentUser.UserId,
    Service = "student-service",
    Method = "Enroll"
})) {
    _logger.LogInformation("Enrolling student {StudentId} in semester {SemesterId}",
                           studentId, semesterId);
}
```

Output (Loki ingests as JSON):
```json
{
  "timestamp": "2026-04-06T10:23:45.123Z",
  "level": "Information",
  "message": "Enrolling student 12345 in semester 2026-1",
  "trace_id": "abc123...",
  "span_id": "def456...",
  "correlation_id": "req-789",
  "tenant_id": "univ-cairo",
  "user_id": "user-42",
  "service": "student-service",
  "method": "Enroll",
  "student_id": 12345,
  "semester_id": "2026-1"
}
```

#### Span Events vs Logs

- Use `ILogger` for human-readable messages (auto-correlated to span via OTel bridge)
- Use `Activity.AddEvent()` for structured lifecycle markers only

### Sampling Strategy

Head sampling (parent-based):
```
ParentBased(TraceIdRatioBased(0.1))
```
Child services HONOR upstream decisions — never half-sample a trace.

Tail sampling REQUIRES two-tier Collector pattern:

```
Tier 1 (Load Balancer Collector):
  receivers: otlp
  exporters:
    loadbalancing:
      routing_key: traceID  ← all spans of one trace go to same Tier 2
      protocol:
        otlp: { resolver: { dns: { hostname: tier2-collector } } }

Tier 2 (Tail Sampling Collector):
  receivers: otlp
  processors:
    memory_limiter      ← ALWAYS first
    tail_sampling:
      decision_wait: 30s
      policies:
        - { name: errors, type: status_code, status_code: { status_codes: [ERROR] } }
        - { name: slow, type: latency, latency: { threshold_ms: 1000 } }
        - { name: rare, type: string_attribute,
            string_attribute: { key: bse.event.type, values: [auth.lockout] } }
        - { name: debug, type: string_attribute,
            string_attribute: { key: bse.debug, values: [true] } }
        - { name: probabilistic, type: probabilistic,
            probabilistic: { sampling_percentage: 10 } }
    batch               ← ALWAYS last
  exporters: otlphttp/tempo
```

**CRITICAL:** Single-Collector setups silently drop fragmented traces. Document this in deployment guides.

### Multi-Tenant Observability

**Vanilla Prometheus is NOT multi-tenant.** For deployments with >100 tenants, use **Grafana Mimir**.

| Tenant Count | Backend |
|---|---|
| < 100 | Vanilla Prometheus + `tenant_tier` bounded label |
| > 100 | Grafana Mimir with `X-Scope-OrgID` per tenant |

#### Tenant Isolation

Loki, Tempo, and Mimir all support multi-tenancy via the `X-Scope-OrgID` HTTP header.

**Metrics:**
- `tenant_tier` as bounded label (Free/Pro/Enterprise)
- Per-tenant via Mimir for SLO-critical metrics

**Logs (Loki):**
- `tenant_id` is **NEVER** a Loki label (label cardinality bomb)
- `tenant_id` goes in **structured metadata** (Loki 3.0+) or log line body
- Loki labels limited to: `service`, `env`, `level`, `namespace`

**Traces (Tempo):**
- `tenant_id` in span attributes (fine)
- Per-tenant Tempo isolation via `X-Scope-OrgID`

#### Cost Attribution

Use `count_connector` in Collector to derive per-tenant volume metrics for chargeback:
```
bse.tenant.observability.bytes_ingested per tenant
```

### Span Limits

```
OTEL_SPAN_ATTRIBUTE_VALUE_LENGTH_LIMIT=4096
OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT=128
OTEL_SPAN_EVENT_COUNT_LIMIT=128
OTEL_SPAN_LINK_COUNT_LIMIT=128
```

Prevents giant DB queries / RPC payloads from blowing up Tempo storage.

### PII Redaction

**Layered redaction (defense in depth):**

#### Layer 1 (SDK side)
- Drop attributes matching denylist
- Hash sensitive identifiers (NOT drop) for joinability:
  ```
  user.id → user.id.hash = SHA256(salt + user.id)
  ```
- GDPR erasure: destroy salt for that tenant → all logs unjoinable

#### Layer 2 (Collector side, OTTL transform)
- Final safety net
- Authorization headers, Cookie headers, password fields
- Credit card patterns (Luhn check)
- JWT shapes (`eyJ...` → `[JWT_REDACTED]`)

```csharp
telemetry.Redaction.HashAttribute("user.id");
telemetry.Redaction.DropAttribute("password");
telemetry.Redaction.RedactPattern(@"\d{16}", "[CC_REDACTED]");
```

### Audit Logs vs Observability Logs (Critical Distinction)

| | Observability Logs (Loki) | Audit Logs (Separate System) |
|---|---|---|
| Purpose | Debugging | Compliance evidence |
| Retention | 30 days default | 7 years (regulatory) |
| Mutability | Ephemeral | Immutable, append-only |
| PII | Redacted | Pseudonymized |
| Sampling | Sampled / dropped at scale | Guaranteed delivery |
| Storage | Loki | Dedicated DB / SIEM / `notifyd` |

**Framework provides separate APIs:**
- `ILogger<T>` → observability logs
- `IAuditLogger` → audit logs

Auth events from RFC-0004 use `IAuditLogger`, NOT `ILogger`.

### Continuous Profiling (Fourth Signal)

Optional package: **`Bse.Framework.Telemetry.Profiling`**

Pyroscope integration:
- .NET continuous profiling (CPU, memory, allocations, locks)
- `SpanProcessor` links profiles to traces
- Click a slow span in Tempo → see exact code path that was hot

### Health Checks

Each package registers its own health checks. `Bse.Framework.Core` aggregates them.

```csharp
services.AddHealthChecks()
    .AddCheck<RedisStreamsHealthCheck>("redis_streams")
    .AddCheck<DatabaseHealthCheck>("database")
    .AddCheck<AuthSessionStoreHealthCheck>("session_store");
```

Two endpoints (Kubernetes pattern):
- `/health/live` → liveness (process is running)
- `/health/ready` → readiness (process is ready to serve traffic)

Liveness fails → Kubernetes restarts pod.
Readiness fails → Kubernetes removes from load balancer (no restart).

Health check results also exposed as metrics:
```
bse.health.check.status   {check_name}  (0=healthy, 1=degraded, 2=unhealthy)
bse.health.check.duration {check_name}  (s)
```

### Default Alert Rules

Ship alongside Grafana dashboards as `prometheus-alerts.yaml`:

```yaml
groups:
  - name: bse-rpc
    rules:
      - alert: BseRpcHighErrorRate
        expr: rate(bse_rpc_errors[5m]) / rate(bse_rpc_requests[5m]) > 0.05
        for: 5m
        severity: warning

      - alert: BseRpcDlqGrowing
        expr: bse_rpc_dlq_depth > 0
        for: 1m
        severity: critical

      - alert: BseRpcConsumerLag
        expr: bse_rpc_consumer_lag > 1000
        for: 5m
        severity: warning
```

SLI/SLO definitions in Sloth or Pyrra format:
- RPC availability SLO: 99.9% over 30 days
- RPC latency SLO: p99 < 500ms over 30 days
- Auth login SLO: 99.95% over 30 days
- Burn-rate alerts at 2%/1h, 5%/6h, 10%/24h

### Drop Rules at Collector

```yaml
processors:
  filter:
    spans:
      exclude:
        match_type: regexp
        attributes:
          - { key: http.target, value: "/health.*|/metrics" }
    logs:
      log_record:
        - 'severity_number < SEVERITY_NUMBER_INFO and resource.attributes["deployment.environment"] == "production"'
```

Cost savings: 20-40% typical.

### Default Docker Compose Stack

```yaml
services:
  otel-collector:
    image: otel/opentelemetry-collector-contrib
    ports: ["4317:4317", "4318:4318"]
    volumes: [./otel-collector-config.yaml:/etc/otel-collector-config.yaml]

  loki:
    image: grafana/loki
    ports: ["3100:3100"]

  tempo:
    image: grafana/tempo
    ports: ["3200:3200"]

  prometheus:
    image: prom/prometheus
    ports: ["9090:9090"]

  grafana:
    image: grafana/grafana
    ports: ["3000:3000"]
    volumes:
      - ./grafana-datasources.yaml:/etc/grafana/provisioning/datasources/datasources.yaml
      - ./grafana-dashboards/:/var/lib/grafana/dashboards/
```

### Pre-Built Grafana Dashboards

Framework ships JSON dashboard definitions:

1. **RPC Overview** — Request rate, error rate, p50/p95/p99 latency, in-flight requests, DLQ depth
2. **Data Layer** — Query rate (EF vs Dapper), slow query log, connection pool utilization, failed queries, migration status
3. **Auth & Security** — Login success/failure, permission denials, active sessions, locked accounts, MFA usage
4. **Multi-Tenancy** — Active tenants, per-tenant request rate, per-tenant error rate, tenant resolution latency, per-tenant resource usage
5. **Service Health** — Health check status, CPU/memory per service, GC pause times, thread pool utilization

### Retention Defaults

| Signal | Production | Staging | Development |
|---|---|---|---|
| Traces | 7 days | 7 days | 1 day |
| Logs | 30 days | 7 days | 1 day |
| Metrics | 90 days raw + 1 year downsampled | 30 days | 7 days |
| Audit | 7 years | 7 years | N/A |

### Data Residency

```csharp
telemetry.Regions = new() {
    ["EU"] = "https://otel-collector.eu.bse.com:4317",
    ["US"] = "https://otel-collector.us.bse.com:4317",
    ["AP"] = "https://otel-collector.ap.bse.com:4317"
};
```

Tenant region resolved from tenant config. EU tenant data NEVER leaves EU collectors → EU Loki/Tempo/Mimir.

## Performance Considerations

- OTel SDK overhead: 1-5% CPU at moderate throughput
- Sample at SDK first (parent-based ratio) before tail sampling
- `Activity.IsAllDataRequested` short-circuits attribute computation when sampled out
- Batch processors with `MaxQueueSize=8192`, `MaxExportBatchSize=512`
- Avoid `db.query.text` capture for every query (slow queries only)

## Migration Path

| Current Pattern | Framework Replacement |
|---|---|
| Stud2/Orange2: no logging | Structured logging via ILogger → Loki |
| SafePack2: Prometheus only | Full OTel: traces + metrics + logs |
| `LogUser.InsertPrint()` | Audit events to dedicated audit store |
| No distributed tracing | W3C Trace Context propagation |
| Manual exception logging | Auto-captured in spans + logs with correlation |
| No dashboards | Pre-built Grafana dashboards |
| No health checks | `/health/live` + `/health/ready` |
| No sampling | Head + tail-based sampling |
| No PII redaction | Configurable redaction rules |

## References

- ADR-0005
- OpenTelemetry .NET docs
- OWASP Top 10:2025 A09 (Logging & Alerting Failures)
- Grafana stack documentation
- Pyroscope continuous profiling
