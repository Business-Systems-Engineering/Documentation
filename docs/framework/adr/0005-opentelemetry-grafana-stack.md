# ADR-0005: OpenTelemetry → Grafana Stack for Observability

- **Status:** Accepted
- **Date:** 2026-04-06
- **Tags:** observability, telemetry, opentelemetry, grafana

## Context

The existing BSE apps have inconsistent or absent observability:
- **Stud2/Orange2:** No logging framework at all
- **SafePack2:** Prometheus metrics only (no traces, no logs)

There is no distributed tracing, no centralized logging, no structured log search, and no dashboards. Debugging production issues requires SSH access and `tail -f` on log files. We need a unified observability stack that supports the framework's distributed RPC architecture.

## Decision

Use **OpenTelemetry SDK** for instrumentation, exporting via **OTLP** to an **OpenTelemetry Collector**, which routes to a **Grafana stack**:
- **Tempo** for traces
- **Loki** for logs
- **Prometheus / Mimir** for metrics
- **Grafana** for visualization

For multi-tenant deployments (>100 tenants), use **Mimir** (multi-tenant Prometheus) instead of vanilla Prometheus.

## Options Considered

### Option A: OpenTelemetry Collector → Grafana Stack
- **Pros:** Open source, self-hosted, Docker-friendly, single collector receives all signals, OTel is vendor-neutral standard, OTLP enables export to any backend later
- **Cons:** Requires running collector + 3-4 backends, operational overhead

### Option B: OpenTelemetry Collector → Jaeger + Prometheus + ELK
- **Pros:** Traditional stack, Jaeger is mature for traces, ELK widely adopted for logs
- **Cons:** Multiple separate UIs, no unified visualization, ELK is heavy

### Option C: Backend-Agnostic (OTel SDK Only)
- **Pros:** Maximum flexibility, customers configure their own backends
- **Cons:** No default deployment, harder onboarding, no pre-built dashboards

## Rationale

Approach A gives us a default deployment that works out of the box (Docker Compose) while remaining flexible (OTLP enables swapping to Datadog, Azure Monitor, etc.). The Grafana stack is open source, has the best correlation experience between signals (click a metric → jump to trace → jump to logs), and supports multi-tenancy via `X-Scope-OrgID`. Pre-built Grafana dashboards ship with the framework.

## Consequences

### Positive
- Three pillars (logs, traces, metrics) unified in one UI
- Distributed tracing across all framework services via W3C Trace Context propagation
- Pre-built dashboards ship with framework
- Vendor-agnostic via OTLP — easy to swap backends
- Per-tenant observability via Mimir/Loki/Tempo `X-Scope-OrgID`
- Exemplars link metrics to traces
- Auto-instrumentation in every framework package

### Negative
- 4-5 services to operate (collector + 3 backends + grafana)
- Cardinality discipline required (tenant_id NEVER as a label without Mimir)
- Tail sampling requires two-tier collector pattern (load-balancing exporter → tail sampling)
- Cost management requires sampling, drop rules, retention policies

### Neutral
- Continuous profiling (Pyroscope) added as optional fourth signal
- Audit logs are SEPARATE system (not Loki) — different retention requirements
- Default retention: traces 7d, logs 30d, metrics 90d raw + 1y downsampled

## References

- RFC-0005: Telemetry and Observability
- OpenTelemetry .NET: https://opentelemetry.io/docs/languages/dotnet/
- Grafana stack documentation
- OWASP Top 10:2025 A09 (Logging & Alerting Failures)
