# RFC-0005: Telemetry and Observability

- **Status:** Implemented
- **Date:** 2026-07-05
- **Authors:** BSE Framework Team
- **Related ADRs:** ADR-0005
- **Related RFCs:** RFC-0001, RFC-0002

---

## Abstract

This document is the as-built specification for the BSE telemetry subsystem (`Bse.Framework.Telemetry`). It covers the three-signal OpenTelemetry pipeline (traces, metrics, logs), the resource model, head-based sampling, PII redaction at two layers, span limits, the decorator-based shutdown instrumentation, and the OTLP export path targeting the Grafana observability stack (Tempo / Prometheus / Loki). The design follows OpenTelemetry .NET SDK conventions and W3C Trace Context propagation.

---

## Motivation

BSE services previously had no unified observability story. Each service team rolled its own Serilog configuration, Prometheus scrape endpoint, or omitted structured logging entirely. The resulting gaps made incident diagnosis, latency attribution, and cross-service correlation impossible without ad-hoc log scraping. The framework needs:

- A single call site (`AddBseTelemetry`) that wires all three signal types with safe defaults.
- W3C traceparent propagation so spans from the RPC layer (RFC-0002) and application code form a single distributed trace.
- Metrics export compatible with Prometheus/OTEL-Collector pipelines without per-service Prometheus endpoint maintenance.
- Structured log export to Loki so logs and traces share the same resource labels and can be correlated by trace id.
- PII protection so OAuth codes, tokens, passwords, and API keys never reach a telemetry backend.

---

## Goals

- Single extension method `AddBseTelemetry` on `IBseFrameworkBuilder` wires traces, metrics, and logs.
- OTLP export to any OpenTelemetry-compatible collector (gRPC or HTTP); endpoint driven by config or environment variable.
- W3C Trace Context and Baggage propagation across process boundaries for all HTTP and RPC traffic.
- Head-based sampling with `ParentBased(TraceIdRatioBased)` so child services honor the caller's sampling decision.
- Base-2 exponential histograms for all framework duration metrics — 10× storage saving vs. fixed buckets.
- Trace-based exemplars so Prometheus/Grafana metric panels link directly to a sampled trace.
- Two-layer PII redaction: URL query-string scrubbing at instrumentation time and generic span-tag redaction on `OnEnd`.
- `InstrumentedShutdownCoordinator` emits a span and histogram for every graceful shutdown, providing latency visibility into draining behaviour.
- Span attribute/event/link limits written as OTEL env vars at startup to keep span sizes predictable.

## Non-Goals

- Tail-based sampling — the current architecture performs head-based sampling at the SDK. A Grafana Tempo tail-sampling policy is a future collector-side concern.
- Log-level filtering strategy — callers retain full control of `ILogger` category filters via `appsettings.json`.
- Custom metric views beyond the default Base-2 exponential histogram override — teams add their own `AddView` calls.
- Alert rule definitions or Grafana dashboard provisioning — those live in the infrastructure repository.
- Distributed baggage enforcement — baggage propagates but the framework does not validate or restrict its contents.

---

## Design

### Overview

`Bse.Framework.Telemetry` is a thin configuration layer on top of the OpenTelemetry .NET SDK. It takes the three separate SDK builder surfaces (`TracerProviderBuilder`, `MeterProviderBuilder`, `ILoggingBuilder`) and wires them with consistent resource attributes, a shared OTLP endpoint, and BSE-specific default sources and meters. The entry point is a single extension method on `IBseFrameworkBuilder` that accepts an optional fluent callback:

```csharp
public static IBseFrameworkBuilder AddBseTelemetry(
    this IBseFrameworkBuilder builder,
    Action<BseTelemetryBuilder>? configure = null)
```

The builder is idempotent with respect to the module marker (`BseTelemetryModule`) so calling `AddBseTelemetry` twice does not register duplicate providers.

### Components

#### BseTelemetryBuilder and BseTelemetryOptions

`BseTelemetryBuilder` is the fluent surface passed to the `configure` callback. It wraps a `BseTelemetryOptions` instance and exposes all configurable properties:

```csharp
public sealed class BseTelemetryBuilder
{
    public BseTelemetryBuilder(BseTelemetryOptions options);

    // Resource attributes
    public string ServiceName    { get; set; }  // default "unknown-service"
    public string ServiceVersion { get; set; }  // default "0.0.0"
    public string Environment    { get; set; }  // default "development"

    // Pipeline sub-options
    public TracesOptions  Traces  { get; }
    public MetricsOptions Metrics { get; }
    public LogsOptions    Logs    { get; }

    // OTLP opt-in
    public BseTelemetryBuilder UseOtlpExporter(Uri? endpoint = null);

    // Extension points
    public BseTelemetryBuilder AddSource(string name);  // additional ActivitySource
    public BseTelemetryBuilder AddMeter(string name);   // additional Meter

    // Advanced: direct options access
    public BseTelemetryOptions Options { get; }
}
```

`BseTelemetryOptions` carries all values that survive the builder callback:

```csharp
public sealed class BseTelemetryOptions
{
    public string  ServiceName                  { get; set; } = "unknown-service";
    public string  ServiceVersion               { get; set; } = "0.0.0";
    public string  Environment                  { get; set; } = "development";
    public Uri?    OtlpEndpoint                 { get; set; } = null;

    public TracesOptions  Traces  { get; } = new();
    public MetricsOptions Metrics { get; } = new();
    public LogsOptions    Logs    { get; } = new();

    // Additional user-supplied source / meter names
    public IList<string> Sources { get; } = new List<string>();
    public IList<string> Meters  { get; } = new List<string>();

    // Span limits (written to OTEL_SPAN_* env vars at startup if not already set)
    public int SpanAttributeCountLimit       { get; set; } = 128;
    public int SpanAttributeValueLengthLimit { get; set; } = 4096;
    public int SpanEventCountLimit           { get; set; } = 128;
    public int SpanLinkCountLimit            { get; set; } = 128;
}
```

Sub-option types:

```csharp
public sealed class TracesOptions
{
    // [0.0, 1.0]. Enforced at set time. Default 1.0 = sample all.
    public double SamplingRatio { get; set; } = 1.0;
}

public sealed class MetricsOptions
{
    public TimeSpan ExportInterval            { get; set; } = TimeSpan.FromSeconds(60);
    public bool     UseTraceBasedExemplarsFlag { get; private set; }

    // Fluent opt-in; sets ExemplarFilterType.TraceBased on the meter provider.
    public void UseTraceBasedExemplars();
}

public sealed class LogsOptions
{
    // ILogger.BeginScope contents as log attributes. Off by default.
    public bool IncludeScopes { get; set; }
    // IncludeFormattedMessage and ParseStateValues are always true (hardcoded in LoggingPipeline).
}
```

#### BseResourceBuilder

Every signal pipeline (traces, metrics, logs) calls `BseResourceBuilder.Build(options)`, which returns a `ResourceBuilder` with the following attributes:

```csharp
public static ResourceBuilder Build(BseTelemetryOptions options)
{
    return ResourceBuilder.CreateDefault()
        .AddService(
            serviceName:       options.ServiceName,
            serviceVersion:    options.ServiceVersion,
            serviceInstanceId: Guid.NewGuid().ToString("N"))  // unique per process start
        .AddAttributes([new("deployment.environment", options.Environment)])
        .AddEnvironmentVariableDetector();  // merges OTEL_RESOURCE_ATTRIBUTES
}
```

The per-run GUID instance id allows Grafana to distinguish replicas of the same service version on the same host. `AddEnvironmentVariableDetector` means `OTEL_RESOURCE_ATTRIBUTES` and `OTEL_SERVICE_NAME` override the programmatic values, supporting environment-specific injection without code changes.

#### Tracing Pipeline

`TracingPipeline.Configure` is an `internal static` method called once during `AddBseTelemetry`. It:

1. Installs a `CompositeTextMapPropagator([TraceContextPropagator, BaggagePropagator])` as the process-wide default — enabling W3C traceparent/tracestate and W3C Baggage on all outbound HTTP calls and BSE RPC envelopes.
2. Sets a `ParentBasedSampler(new TraceIdRatioBasedSampler(options.Traces.SamplingRatio))` so child spans defer to the upstream sampling decision.
3. Adds ASP.NET Core and `HttpClient` instrumentation with `QueryStringRedactor.RedactActivityTags` wired to both `EnrichWithHttpRequest` / `EnrichWithHttpResponse` and `EnrichWithHttpRequestMessage` / `EnrichWithHttpResponseMessage` callbacks.
4. Subscribes to the default framework sources plus any entries in `options.Sources`.
5. Registers a `RedactingSpanProcessor` (via `AddProcessor`) as the last processor before export.
6. Adds the OTLP exporter when `OtlpEndpoint` is non-null or `OTEL_EXPORTER_OTLP_ENDPOINT` is set.

```csharp
// Always-subscribed ActivitySource names
public static readonly string[] DefaultSources =
[
    "Bse.Framework",
    "Bse.Rpc",
    "Bse.Rpc.RedisStreams",
    "Bse.Data.EntityFramework",
    "Bse.Data.Dapper",
    "Bse.Auth",
    "Bse.MultiTenancy",
    // EF Core auto-emits this source for every SQL command since 5.0
    "Microsoft.EntityFrameworkCore.Database.Command"
];
```

#### Metrics Pipeline

`MetricsPipeline.Configure` mirrors the tracing pipeline for meters:

```csharp
// Always-subscribed Meter names
public static readonly string[] DefaultMeters =
[
    "Bse.Framework",
    "Bse.Rpc",
    "Bse.Rpc.RedisStreams",
    "Bse.Data.EntityFramework",
    "Bse.Data.Dapper",
    "Bse.Auth",
    "Bse.MultiTenancy"
];
```

Beyond subscribing to meters, the pipeline applies a global `AddView` that converts every `Histogram` instrument to `Base2ExponentialBucketHistogramConfiguration`, eliminating bucket boundary guessing and providing better dynamic range for latency distributions. When `UseTraceBasedExemplarsFlag` is set, `SetExemplarFilter(ExemplarFilterType.TraceBased)` ensures only sampled-trace requests record exemplars, preventing exemplar cardinality explosion under low sampling ratios.

`AddRuntimeInstrumentation` is always registered, providing GC pause, thread pool queue depth, and heap generation metrics without any service-level code.

#### Logging Pipeline

`LoggingPipeline.Configure` calls `ILoggingBuilder.AddOpenTelemetry` with:

- `IncludeScopes` from `options.Logs.IncludeScopes` (default `false`).
- `IncludeFormattedMessage = true` (always; ensures the log record body is the rendered message string).
- `ParseStateValues = true` (always; emits structured log fields as OTLP log record attributes).
- OTLP exporter added when `OtlpEndpoint` is set or `OTEL_EXPORTER_OTLP_ENDPOINT` is present; uses the explicit endpoint when provided.

All three pipelines read the same OTLP gating condition (`OtlpEndpoint is not null || HasOtlpEndpointEnv()`) so enabling export is a single option.

#### Span Limits

Span limits are applied at `AddBseTelemetry` time by writing to `OTEL_SPAN_*` environment variables if they are not already set. The SDK reads these env vars at first `Activity` creation, so setting them early guarantees programmatic defaults take effect without preventing an operator from overriding them via the deployment environment:

| Environment Variable | Default Value |
|---|---|
| `OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT` | 128 |
| `OTEL_SPAN_ATTRIBUTE_VALUE_LENGTH_LIMIT` | 4096 |
| `OTEL_SPAN_EVENT_COUNT_LIMIT` | 128 |
| `OTEL_SPAN_LINK_COUNT_LIMIT` | 128 |

The write uses `TrySetEnvIfMissing` — it is a no-op if the variable already has a value, so operator-set values always win.

#### PII Redaction

There are two complementary redaction layers:

**Layer 1 — `QueryStringRedactor` (URL query strings at instrumentation time).**

`QueryStringRedactor.RedactActivityTags` is called from the ASP.NET Core and HttpClient `Enrich` callbacks. It rewrites the `url.query` tag and the query portion of `url.full` in-place on the `Activity` before any processor or exporter sees them:

```csharp
internal static readonly HashSet<string> SensitiveKeys =
    new(StringComparer.OrdinalIgnoreCase)
{
    // OAuth / OIDC
    "code", "state", "token", "access_token", "id_token", "refresh_token", "client_secret",
    // Generic API auth
    "api_key", "apikey", "key", "auth", "authorization",
    // Plaintext credentials
    "password", "passwd", "secret",
    // Signed payloads
    "signature", "sig", "hmac",
};
```

Eighteen keys in total. Matched values are replaced with the string literal `[REDACTED]` while key names and unaffected parameters are preserved. The redactor is allocation-free when no sensitive key appears in the query string (early exit via substring scan). Leading `?` is preserved to avoid breaking downstream parsers.

**Layer 2 — `RedactingSpanProcessor` (all span tags on `OnEnd`).**

`RedactingSpanProcessor : BaseProcessor<Activity>` runs after all other processors and before the exporter. On `OnEnd` it iterates every tag on the activity and passes `(tagKey, tagValue)` to `ISensitiveDataRedactor.Redact`. Only tags whose value changes are rewritten via `activity.SetTag`:

```csharp
public sealed class RedactingSpanProcessor : BaseProcessor<Activity>
{
    private readonly ISensitiveDataRedactor _redactor;

    public override void OnEnd(Activity activity)
    {
        foreach (var tag in activity.TagObjects)
        {
            if (tag.Value is null) continue;
            var original = tag.Value.ToString();
            if (original is null) continue;
            var redacted = _redactor.Redact(tag.Key, original);
            if (!string.Equals(redacted, original, StringComparison.Ordinal))
                activity.SetTag(tag.Key, redacted);
        }
    }
}
```

`ISensitiveDataRedactor` is resolved from the DI container (registered by `Bse.Framework.Core`) and can be replaced in tests without touching the processor.

#### InstrumentedShutdownCoordinator

`InstrumentedShutdownCoordinator` is registered as a decorator over `IGracefulShutdownCoordinator` during `AddBseTelemetry` via a manual decoration helper (`services.Decorate<IGracefulShutdownCoordinator, InstrumentedShutdownCoordinator>()`). It emits:

- **Span** `bse.framework.shutdown` (source `Bse.Framework` v`0.1.0`, kind `Internal`) — wraps the entire `ShutdownAsync` call. A tag `bse.framework.shutdown.duration_s` carries the elapsed seconds.
- **Histogram** `bse.framework.shutdown.duration` (unit `s`, meter `Bse.Framework` v`0.1.0`) — records `Stopwatch.Elapsed.TotalSeconds` in the `finally` block so it is always emitted even when shutdown throws.

```csharp
public sealed class InstrumentedShutdownCoordinator : IGracefulShutdownCoordinator
{
    private static readonly ActivitySource ActivitySource = new("Bse.Framework", "0.1.0");

    public async Task ShutdownAsync(CancellationToken cancellationToken)
    {
        using var activity = ActivitySource.StartActivity("bse.framework.shutdown", ActivityKind.Internal);
        var sw = Stopwatch.StartNew();
        try   { await _inner.ShutdownAsync(cancellationToken).ConfigureAwait(false); }
        finally
        {
            sw.Stop();
            FrameworkMeters.ShutdownDuration.Record(sw.Elapsed.TotalSeconds);
            activity?.SetTag("bse.framework.shutdown.duration_s", sw.Elapsed.TotalSeconds);
        }
    }
}
```

#### BseTelemetryModule

`BseTelemetryModule : IBseModule` is a no-op marker registered by `RegisterModule<BseTelemetryModule>()`. It allows other framework packages (RPC, Data, Auth) to assert at startup that `AddBseTelemetry` was called before they register their auto-instrumentation, preventing silent misconfiguration where an `ActivitySource` is created but no subscriber exists.

---

### Data Flow

```
Application Code / Framework Packages
        │ ActivitySource.StartActivity(...)
        │ Meter.CreateHistogram / Counter.Add(...)
        │ ILogger.LogInformation(...)
        ▼
OpenTelemetry .NET SDK (in-process)
        │
        ├── TracerProvider
        │       ├── ParentBased(TraceIdRatioBased) sampler
        │       ├── QueryStringRedactor (Enrich callbacks — runs before processor pipeline)
        │       ├── RedactingSpanProcessor (BaseProcessor.OnEnd — runs before exporter)
        │       └── OtlpTraceExporter ──► gRPC/HTTP ──► OTel Collector ──► Grafana Tempo
        │
        ├── MeterProvider
        │       ├── Base2ExponentialBucketHistogram view (all histograms)
        │       ├── TraceBased exemplar filter (optional)
        │       ├── AddRuntimeInstrumentation (.NET runtime metrics)
        │       └── OtlpMetricExporter (60 s interval) ──► OTel Collector ──► Prometheus ──► Grafana
        │
        └── LoggerProvider
                ├── IncludeFormattedMessage = true
                ├── ParseStateValues = true
                └── OtlpLogExporter ──► OTel Collector ──► Grafana Loki
```

The OpenTelemetry Collector (or Grafana Alloy) is the single egress point. It applies tail-sampling policies, fanout to multiple backends, and metric relabeling without changes to service code.

W3C `traceparent` flows outbound on every ASP.NET Core response header and every `HttpClient` request header (via the global `CompositeTextMapPropagator`). The BSE RPC transport carries it explicitly in `TransportMessage.Trace.Traceparent` across Redis Streams (see RFC-0002), so distributed traces span HTTP and event-driven hops in a single timeline in Grafana Tempo.

---

### API / Interfaces

The public surface exposed by `Bse.Framework.Telemetry`:

| Type | Kind | Notes |
|---|---|---|
| `TelemetryServiceCollectionExtensions.AddBseTelemetry` | Extension method | Entry point |
| `BseTelemetryBuilder` | Class | Fluent callback argument |
| `BseTelemetryOptions` | Class | Strongly typed options |
| `TracesOptions` | Class | Traces sub-options |
| `MetricsOptions` | Class | Metrics sub-options |
| `LogsOptions` | Class | Logs sub-options |
| `BseResourceBuilder` | `public static` class | Resource attribute builder |
| `BseTelemetryModule` | Class (marker) | Module registration token |
| `RedactingSpanProcessor` | `public sealed class` | PII layer 2 (testable) |
| `InstrumentedShutdownCoordinator` | `public sealed class` | Shutdown span + histogram |
| `TracingPipeline.DefaultSources` | `public static string[]` | Known framework source names |
| `MetricsPipeline.DefaultMeters` | `public static string[]` | Known framework meter names |

`QueryStringRedactor`, `TracingPipeline`, `MetricsPipeline`, and `LoggingPipeline` are `internal`. They are exposed to the test project via `InternalsVisibleTo("Bse.Framework.Telemetry.Tests")`.

---

### Configuration

A typical production registration:

```csharp
services.AddBseFramework(framework =>
{
    framework.AddBseTelemetry(telemetry =>
    {
        telemetry.ServiceName    = "billing-service";
        telemetry.ServiceVersion = "3.1.0";
        telemetry.Environment    = "production";

        telemetry.UseOtlpExporter();               // reads OTEL_EXPORTER_OTLP_ENDPOINT
        telemetry.Traces.SamplingRatio = 0.1;      // 10% head sample; parent decision honoured
        telemetry.Metrics.UseTraceBasedExemplars(); // metric → trace click-through in Grafana
        telemetry.Logs.IncludeScopes = true;        // emit BeginScope keys as log attributes

        // Application ActivitySource / Meter subscriptions
        telemetry.AddSource("Billing");
        telemetry.AddMeter("Billing");
    });
});
```

Environment variables that interact with the subsystem:

| Variable | Effect |
|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Enables OTLP export; acts as fallback when `OtlpEndpoint` is null |
| `OTEL_SERVICE_NAME` | Overrides `ServiceName` via `ResourceBuilder.CreateDefault()` |
| `OTEL_RESOURCE_ATTRIBUTES` | Merged via `AddEnvironmentVariableDetector()` |
| `OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT` | Overrides `SpanAttributeCountLimit` (only if set before first `Activity`) |
| `OTEL_SPAN_ATTRIBUTE_VALUE_LENGTH_LIMIT` | Overrides `SpanAttributeValueLengthLimit` |
| `OTEL_SPAN_EVENT_COUNT_LIMIT` | Overrides `SpanEventCountLimit` |
| `OTEL_SPAN_LINK_COUNT_LIMIT` | Overrides `SpanLinkCountLimit` |

When `OtlpEndpoint` is null **and** `OTEL_EXPORTER_OTLP_ENDPOINT` is absent, all three OTLP exporters are skipped entirely. The SDK still collects signals in-process (visible to test processors), but no network calls are made — the correct default for unit test environments.

---

### Error Handling

The telemetry subsystem does not throw during normal signal emission — the OpenTelemetry SDK is designed to be non-throwing on the hot path. Configuration errors surface at startup:

- `BseTelemetryBuilder.AddSource` / `AddMeter` throw `ArgumentException` if the name is null or whitespace.
- `BseResourceBuilder.Build` throws `ArgumentNullException` if `options` is null.
- `RedactingSpanProcessor` throws `ArgumentNullException` if the injected `ISensitiveDataRedactor` is null.
- `InstrumentedShutdownCoordinator` throws `ArgumentNullException` if the inner coordinator is null.
- The `Decorate<IGracefulShutdownCoordinator, InstrumentedShutdownCoordinator>` helper throws `InvalidOperationException` if `AddBseFramework()` was not called before `AddBseTelemetry()`.

Export failures (network unreachable, OTLP endpoint down) are handled by the SDK's internal retry/drop logic and do not propagate to application code.

---

### Performance Considerations

**Hot-path allocation.** The `RedactingSpanProcessor.OnEnd` loop iterates tag objects and calls `ToString()` once per tag. Tags whose values do not change incur only a string equality check — no allocation. Tags that do change allocate one new string (the redacted value).

**QueryStringRedactor early exit.** `ContainsSensitiveKey` performs a case-insensitive substring scan across the 18 sensitive key names before splitting on `&`. Queries that contain no sensitive keys exit without any allocation.

**Base-2 exponential histograms.** Eliminating fixed bucket boundaries removes per-service histogram tuning and reduces Prometheus/OTLP storage by approximately 10× compared to equivalent fixed-bucket resolution, per the OpenTelemetry specification.

**Sampling.** `ParentBased(TraceIdRatioBased(ratio))` makes the keep/drop decision at root span creation. All child spans in the same trace inherit the decision without additional computation. At `SamplingRatio = 0.1`, 90% of root spans and all their descendants are dropped before any processor runs.

**Export interval.** The default 60-second metric export interval keeps Prometheus scrape alignment predictable. Short-lived processes (under 60 s) should use a shorter `ExportInterval` to ensure at least one flush before shutdown.

---

### Security Considerations

**Two-layer PII redaction.** Layer 1 (`QueryStringRedactor`) fires inside the `Enrich` callback while the `Activity` is still being built — no sensitive URL parameter ever reaches the processor pipeline. Layer 2 (`RedactingSpanProcessor`) is a catch-all: any tag set by application code or third-party instrumentation that the `ISensitiveDataRedactor` identifies as sensitive is overwritten before export. Together they ensure PII does not reach the OTLP backend even if instrumentation code inadvertently tags sensitive fields.

**Sensitive key scope.** The 18 redacted query-string keys cover OAuth 2.0 / OIDC authorization codes, access/refresh/id tokens, client secrets, API keys, plaintext credentials, and HMAC signatures. For domain-specific sensitive fields (e.g. account numbers, national identifiers) the `ISensitiveDataRedactor` implementation in `Bse.Framework.Core` is the extension point.

**No secret material in span tags.** Framework spans (`bse.rpc.*`, `bse.framework.shutdown`) carry only non-secret identifiers: service name, method name, message id, correlation id, duration.

**OTLP channel security.** The OTLP exporter uses gRPC or HTTP as configured by `OTEL_EXPORTER_OTLP_ENDPOINT`. Production deployments should use a TLS endpoint or route through a local agent sidecar (Grafana Alloy) that holds the mTLS certificate, keeping service code free of certificate management.

---

### Observability

The telemetry subsystem emits the following signals about itself:

| Signal | Name | Type | Description |
|---|---|---|---|
| Trace span | `bse.framework.shutdown` | `ActivityKind.Internal` | Wraps graceful shutdown; source `Bse.Framework` v0.1.0 |
| Metric | `bse.framework.shutdown.duration` | `Histogram<double>` (unit: `s`) | Shutdown duration; meter `Bse.Framework` v0.1.0 |

Tag on `bse.framework.shutdown`:

| Tag | Value |
|---|---|
| `bse.framework.shutdown.duration_s` | `double` — elapsed seconds |

When `OTEL_EXPORTER_OTLP_ENDPOINT` is absent, the SDK self-diagnostics listener is the only output channel; it emits at `Debug` level to `System.Diagnostics.Trace`.

---

### Testing Strategy

The `Bse.Framework.Telemetry.Tests` project covers:

- **Options tests** — `BseTelemetryOptionsTests`, `BseTelemetryOptionsAdditionalTests`: verify default values, `SamplingRatio` range validation, `UseTraceBasedExemplars` flag, `AddSource`/`AddMeter` guard conditions.
- **Builder tests** — `BseTelemetryBuilderTests`: verify builder property mutations propagate to the underlying options instance and `UseOtlpExporter(uri)` writes `OtlpEndpoint`.
- **DI integration tests** — `TelemetryServiceCollectionExtensionsTests`, `TelemetryServiceCollectionExtensionsAdditionalTests`: build a full `ServiceCollection` with `AddBseFramework` + `AddBseTelemetry` and assert `IOptions<BseTelemetryOptions>` is resolvable and `IGracefulShutdownCoordinator` resolves to `InstrumentedShutdownCoordinator`.
- **QueryStringRedactor tests** — `QueryStringRedactorTests`: round-trip all 18 sensitive keys in single-key, multi-key, mixed (sensitive + innocent), and URL-encoded-key forms; verify innocent-only queries return the original string reference (no allocation path).
- **TracingPipeline tests** — `TracingPipelineTests`: construct a `TracerProvider` in-process with an `InMemoryActivityProcessor` (`Helpers/InMemoryActivityProcessor.cs`) and assert `DefaultSources` spans are captured and `RedactActivityTags` fires on enrichment callbacks.
- **MetricsPipeline tests** — `MetricsPipelineTests`: verify `DefaultMeters` subscription, exponential histogram view application, and runtime instrumentation presence.
- **Logging tests** — `LoggingPipelineTests`: verify `IncludeFormattedMessage`, `ParseStateValues`, and scope inclusion via a test `ILoggerFactory`.
- **Resource tests** — `BseResourceBuilderTests`, `BseResourceBuilderAdditionalTests`: verify `service.name`, `service.version`, `deployment.environment` attributes and that `service.instance.id` is a non-empty hex string that differs across calls.
- **Span processor tests** — `RedactingSpanProcessorTests`, `RedactingSpanProcessorAdditionalTests`: run `OnEnd` against activities with synthetic tag sets; assert redacted tags are overwritten and clean tags are preserved.
- **Shutdown instrumentation tests** — `ShutdownInstrumentationTests`, `ShutdownInstrumentationAdditionalTests`: capture the `bse.framework.shutdown` span via `InMemoryActivityProcessor` and verify the duration tag and histogram recording.
- **Module marker test** — `BseTelemetryModuleTests`: asserts `BseTelemetryModule` is an `IBseModule` and that `Configure` is a no-op.
- **End-to-end smoke tests** — `EndToEndSmokeTests`, `EndToEndResourceAttributeTests`, `EndToEndMetricsTests`: build a full pipeline with in-memory exporters; emit signals through `AddBseTelemetry` wiring and assert they appear with correct resource attributes.

---

## Migration Path

### From no observability

Add the package reference and a single builder call. No changes are needed in handlers or controllers — framework instrumentation is automatic.

```csharp
// Before
services.AddBseFramework();

// After
services.AddBseFramework(framework =>
{
    framework.AddBseTelemetry(t =>
    {
        t.ServiceName = "my-service";
        t.UseOtlpExporter();
    });
});
```

Set `OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4317` in the deployment manifest to activate export.

### From Serilog-only structured logging

`AddBseTelemetry` calls `ILoggingBuilder.AddOpenTelemetry`, which adds an OTLP logger provider alongside existing providers. Serilog and the OTLP provider can coexist — remove Serilog once Loki is confirmed as the log destination.

### From a Prometheus scrape endpoint (`prometheus-net` or `UsePrometheusScrapingEndpoint`)

Set `UseOtlpExporter` and route metrics through the OTel Collector to Prometheus via remote write. Remove the scrape endpoint registration. The Base-2 exponential histograms require Prometheus 2.40+ (native histograms) or Collector conversion to classic buckets — confirm Prometheus version before cutover.

### From manual `ActivitySource` registration

Replace ad-hoc `AddSource("MySource")` calls on a raw `TracerProviderBuilder` with `telemetry.AddSource("MySource")` inside the `AddBseTelemetry` callback. The effect is identical; the builder stores the name in `options.Sources` and passes it to `TracingPipeline.Configure`.

---

## Open Questions

**Tail-based sampling.** The current design performs head-based sampling in the SDK (`ParentBased(TraceIdRatioBased)`). Tail-based sampling — where the keep/drop decision is deferred until the entire trace is complete — requires a stateful Collector layer (Grafana Tempo's tail-sampling processor or the OTel Collector's `tailsamplingprocessor`). This is a Collector configuration concern, not a framework concern, but it implies that low `SamplingRatio` values will lose error traces that happen to fall in the dropped fraction. Until tail-sampling is deployed at the Collector, the recommended operational setting is `SamplingRatio = 1.0` in staging and `0.1` in high-volume production with an error-override rule at the Collector.

**DefaultSources vs. emitted ActivitySource names.** `TracingPipeline.DefaultSources` lists the strings `"Bse.Rpc"`, `"Bse.Rpc.RedisStreams"`, `"Bse.Data.EntityFramework"`, `"Bse.Data.Dapper"`, `"Bse.Auth"`, and `"Bse.MultiTenancy"`. The OpenTelemetry .NET SDK matches `AddSource` entries by exact name, not prefix. The actual `ActivitySource` names emitted by the RPC layer (per RFC-0002) are `"Bse.Framework.Rpc.Dispatcher"` and `"Bse.Framework.Rpc.RedisStreams"`. Only `"Bse.Framework"` in `DefaultSources` is confirmed to exactly match a live `ActivitySource` (the one in `InstrumentedShutdownCoordinator`). Whether the remaining short-prefix entries match the sources actually registered by their respective packages at runtime should be audited per package. No change has been made to `DefaultSources` in this RFC — this is documented as an observation for follow-up.

**`service.instance.id` cross-signal consistency.** `BseResourceBuilder.Build` generates a new `Guid` on every call. Since `Build` is called once per provider (traces, metrics, logs) inside a single `AddBseTelemetry`, three different instance IDs are assigned. Grafana correlates signals using `service.instance.id`; differing IDs across signal types break metric-to-trace correlation. A future revision should generate the GUID once per `AddBseTelemetry` call and share it across all three `Build` invocations.

**Exemplar cardinality under low sampling.** At `SamplingRatio` below 0.01 the exemplar attachment rate drops proportionally. High-concurrency services may want a distinct exemplar sampling ratio independent of trace sampling. A `ExemplarSamplingRatio` option on `MetricsOptions` is not yet implemented.

---

## References

- [OpenTelemetry .NET SDK](https://github.com/open-telemetry/opentelemetry-dotnet)
- [OpenTelemetry .NET Instrumentation — ASP.NET Core](https://github.com/open-telemetry/opentelemetry-dotnet-contrib/tree/main/src/OpenTelemetry.Instrumentation.AspNetCore)
- [OpenTelemetry .NET Instrumentation — HttpClient](https://github.com/open-telemetry/opentelemetry-dotnet-contrib/tree/main/src/OpenTelemetry.Instrumentation.Http)
- [OpenTelemetry .NET Runtime Instrumentation](https://github.com/open-telemetry/opentelemetry-dotnet-contrib/tree/main/src/OpenTelemetry.Instrumentation.Runtime)
- [W3C Trace Context Specification](https://www.w3.org/TR/trace-context/)
- [W3C Baggage Specification](https://www.w3.org/TR/baggage/)
- [OpenTelemetry OTLP Exporter Specification](https://opentelemetry.io/docs/specs/otlp/)
- [Grafana Tempo — Distributed Tracing Backend](https://grafana.com/docs/tempo/latest/)
- [Grafana Loki — Log Aggregation](https://grafana.com/docs/loki/latest/)
- [Prometheus — Metrics and Alerting](https://prometheus.io/docs/introduction/overview/)
- [OpenTelemetry Base-2 Exponential Histogram](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#exponentialhistogram)
- [OpenTelemetry Exemplars](https://opentelemetry.io/docs/specs/otel/metrics/sdk/#exemplar)
- RFC-0001: Framework Overview and In-Memory Testing Rig
- RFC-0002: RPC, Source Generation, and the Invocation Pipeline
- ADR-0005: Observability Signal Selection
