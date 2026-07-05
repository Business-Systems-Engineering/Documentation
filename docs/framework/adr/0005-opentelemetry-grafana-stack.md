# ADR-0005: OpenTelemetry → Grafana Stack

- **Status:** Accepted
- **Date:** 2026-04-06
- **Deciders:** BSE Framework Team
- **Tags:** observability, telemetry, opentelemetry, grafana

## Context

The existing BSE apps have inconsistent or absent observability:

- **Stud2 / Orange2:** No logging framework at all — debugging requires SSH and `tail -f`.
- **SafePack2:** Prometheus metrics only; no distributed traces, no structured log search.

There is no distributed tracing, no centralized log aggregation, and no cross-signal correlation.
The framework's distributed RPC architecture (Redis Streams, HTTP, In-Memory transports) makes
this gap severe: a failed request can span multiple services and there is no way to follow it
without per-service log inspection.

All three signal types (traces, metrics, logs) were needed in a single coherent system with
low operational overhead for Docker-based deployments.

## Decision

Instrument with the **OpenTelemetry .NET SDK** for all three signals and export via **OTLP** to
the **Grafana observability stack**:

- **Tempo** for distributed traces
- **Loki** for structured logs
- **Prometheus / Mimir** for metrics

The framework ships `Bse.Framework.Telemetry` with three internal pipelines — `TracingPipeline`,
`MetricsPipeline`, and a logging pipeline — configured by `BseTelemetryOptions`.

Key as-built choices verified against source:

- **Head sampling:** `ParentBased(TraceIdRatioBased(ratio))` — child services honour upstream
  sampling decisions; ratio defaults to `1.0` (sample everything).
- **PII redaction:** `RedactingSpanProcessor` runs `ISensitiveDataRedactor` on every span tag at
  `OnEnd`; `QueryStringRedactor` strips OAuth codes, reset tokens, and API keys from `url.query`
  and `url.full` in ASP.NET Core and HttpClient instrumentation.
- **Base-2 exponential histograms:** `MetricsPipeline` applies a blanket `AddView` that returns
  `Base2ExponentialBucketHistogramConfiguration` for every histogram instrument, providing better
  dynamic range and ~10x storage savings over fixed buckets.
- **OTLP transport:** a single `OtlpEndpoint` (defaults to `OTEL_EXPORTER_OTLP_ENDPOINT` or
  `localhost:4317` gRPC) covers all three signals.

```csharp
// TracingPipeline.Configure (excerpt)
traceProvider
    .SetSampler(new ParentBasedSampler(
        new TraceIdRatioBasedSampler(options.Traces.SamplingRatio)))
    .AddAspNetCoreInstrumentation(o =>
    {
        o.EnrichWithHttpRequest = (activity, _) =>
            QueryStringRedactor.RedactActivityTags(activity);
    });

// MetricsPipeline.Configure (excerpt)
meterProvider.AddView(instrument =>
{
    if (instrument.GetType().Name.Contains("Histogram", StringComparison.Ordinal))
        return new Base2ExponentialBucketHistogramConfiguration();
    return null;
});
```

## Options Considered

### Option A: Per-signal bespoke stack (DB logs / Prometheus only)
- **Pros:** Familiar to teams already running Prometheus; no new vendor.
- **Cons:** No distributed tracing; logs stay on disk; no cross-signal correlation; cannot follow
  a request across RPC hops.

### Option B: Vendor APM (Datadog, New Relic, Azure Monitor)
- **Pros:** Managed, turnkey dashboards, no infrastructure to operate.
- **Cons:** Vendor lock-in, cost at scale (per-host pricing), PII data leaves the environment,
  incompatible with BSE's on-premises deployment requirement.

### Option C: OpenTelemetry → Grafana Stack (chosen)
- **Pros:** Open source, self-hosted, Docker Compose-friendly; OTLP is vendor-neutral so backends
  can be swapped without touching application code; Grafana unifies all three signals in one UI
  with exemplar links (metric → trace → log); pre-built dashboards ship with the framework.
- **Cons:** 4–5 services to operate (OTel Collector + Tempo + Loki + Prometheus + Grafana);
  cardinality discipline required (high-cardinality labels must not go to Prometheus directly);
  tail sampling needs a two-tier collector pattern.

## Rationale

Option C provides the distributed tracing the RPC architecture requires while staying open source
and on-premises. The Grafana ecosystem has the strongest cross-signal correlation story: clicking
an anomalous metric data point can jump to the matching trace, and from there to the correlated
log lines via Loki. OTLP as the single export protocol means a future move to Datadog or Azure
Monitor requires only a Collector config change, not application code changes.

The PII redaction requirement is met entirely at the SDK layer (`RedactingSpanProcessor`,
`QueryStringRedactor`) so no sensitive data reaches the Collector or any backend.

## Consequences

### Positive
- All three observability pillars unified in Grafana with exemplar-based cross-signal navigation.
- Distributed traces follow requests across Redis Streams and HTTP transports via W3C Trace Context
  propagation (set as the default `TextMapPropagator`).
- Base-2 exponential histograms improve storage efficiency without pre-defining bucket boundaries.
- PII redaction is automatic — application teams do not need to scrub spans manually.
- Vendor-agnostic: OTLP endpoint is the only coupling point.
- Auto-instrumentation for ASP.NET Core, HttpClient, EF Core, and runtime metrics included in the
  package; consuming services opt in with a single `AddBseTelemetry()` call.

### Negative
- 4–5 services to operate in Docker Compose; production deployments need retention and cardinality
  policies.
- Cardinality discipline is mandatory: `tenant_id` and `user_id` must not appear as Prometheus
  labels without Mimir (multi-tenant Prometheus).
- Tail sampling (sample-after-seeing-the-full-trace) requires a separate two-tier Collector
  topology with a load-balancing exporter.

### Neutral
- Default retention guidance: traces 7 d, logs 30 d, metrics 90 d raw + 1 y downsampled.
- Continuous profiling (Pyroscope) is an optional fourth signal not wired by default.
- Audit logs are a separate system with different retention requirements and are not routed to Loki.

## References

- RFC-0005: Telemetry and Observability
- [`Bse.Framework.Telemetry/Tracing/TracingPipeline.cs`]
- [`Bse.Framework.Telemetry/Metrics/MetricsPipeline.cs`]
- [`Bse.Framework.Telemetry/Processors/RedactingSpanProcessor.cs`]
- [`Bse.Framework.Telemetry/Options/BseTelemetryOptions.cs`]
- OpenTelemetry .NET SDK: https://opentelemetry.io/docs/languages/dotnet/
