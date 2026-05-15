# RFC-0002: RPC and Distributed Computing

- **Status:** Approved (revised 2026-05-15 — see ADR-0011 amendment)
- **Date:** 2026-04-06
- **Revised:** 2026-05-15
- **Related ADRs:** ADR-0002, ADR-0009, ADR-0011
- **Related RFCs:** RFC-0001, RFC-0006

## Abstract

The framework provides distributed computing via JSON-RPC 2.0 over a transport abstraction supporting Redis Streams (primary), HTTP, and In-Memory implementations. Services declare RPC methods, event emitters, and event receivers via attributes; source generators produce dispatch code at compile time.

## Motivation

The existing BSE apps are monolithic Web API 2 deployments with no inter-service communication. Adding distributed computing requires:
- Service-to-service RPC for cross-domain operations
- Event publishing/subscription for loose coupling
- Background job processing
- Horizontal scaling via consumer groups
- External API exposure via HTTP

The framework must provide these capabilities with consistent semantics, transport flexibility, and zero developer boilerplate.

## Goals

- JSON-RPC 2.0 spec compliance (batch requests, notifications, error codes)
- Transport abstraction with multiple implementations
- Source generator-based service registration (no manual wiring)
- Consumer groups for horizontal scaling
- Dead letter queues for poison messages
- Distributed tracing across service boundaries
- Idempotency support for at-least-once delivery
- Circuit breakers and bulkheads for resilience
- Graceful shutdown without message loss

## Non-Goals

- Bidirectional streaming (use WebSocket transport later if needed)
- Protobuf code generation (JSON-RPC 2.0 with TypeScript-style types is sufficient)
- Replacing notifyd for email/SMS notifications

## Design

### Protocol Layer

The protocol follows JSON-RPC 2.0 strictly. Standard message types:

```csharp
// JSON-RPC 2.0 wire format
public record JsonRpcRequest(string Jsonrpc, object Id, string Method, JsonElement? Params);
public record JsonRpcNotification(string Jsonrpc, string Method, JsonElement? Params);
public record JsonRpcResponse(string Jsonrpc, object Id, JsonElement? Result, JsonRpcError? Error);
public record JsonRpcError(int Code, string Message, JsonElement? Data);

// Batch support (JSON-RPC 2.0 spec section 6)
public record JsonRpcBatch(JsonRpcRequest[] Requests);
public record JsonRpcBatchResponse(JsonRpcResponse[] Responses);
```

The transport envelope wraps the JSON-RPC message with routing/auth/trace metadata:

```csharp
public record TransportMessage
{
    string MessageId;          // unique per message (CSPRNG)
    string CorrelationId;      // for reply matching
    string Service;            // target service name
    string Method;             // RPC method name
    string? ReplyTo;           // reply stream/channel (null = notification)
    long Deadline;             // unix nano
    AuthContext? Auth;         // JWT claims, tenant context
    TraceContext? Trace;       // W3C trace propagation
    JsonElement Args;          // serialized params
    JsonElement? Response;     // serialized result
    MessageError? Error;       // error if failed
}
```

### Standard Error Codes

| Code | Meaning |
|---|---|
| -32700 | Parse error |
| -32600 | Invalid request |
| -32601 | Method not found |
| -32602 | Invalid params |
| -32603 | Internal error |
| -32000 to -32099 | Server error (framework-defined) |
| 1+ | Application-defined |

Application errors must use codes ≥ 1 to avoid collision with reserved ranges.

### Service Registration

Services declare RPC methods, emitters, and receivers via attributes:

```csharp
public class StudentService
{
    [RpcMethod(Summary = "Get student by ID")]
    [RequirePermission("Students.View")]
    public async Task<StudentDto> GetStudent(int studentId, ICurrentUser user)
    {
        // method injection — no base class needed
    }

    [RpcMethod]
    [RequirePermission("Students.Enroll")]
    public async Task<EnrollmentResult> Enroll(EnrollRequest request) { ... }

    [Emitter(Channel = "student.enrolled")]
    public async IAsyncEnumerable<StudentEvent> StudentEvents([EnumeratorCancellation] CancellationToken ct)
    {
        // yields events
    }

    [Receiver(From = "billing", Channel = "payment.received")]
    public async Task OnPaymentReceived(PaymentEvent payment) { ... }
}
```

POCO handlers are supported (no `BseService` base class required) for simpler testing. Method injection resolves framework services per call.

### Transport Abstraction (Segregated)

Following Interface Segregation (ADR-0009):

```csharp
public interface IMessagePublisher
{
    Task PublishAsync(string stream, TransportMessage message, CancellationToken ct);
}

public interface IRpcClient
{
    Task<TransportMessage> RequestAsync(string stream, TransportMessage message,
                                         TimeSpan timeout, CancellationToken ct);
}

public interface IMessageConsumer
{
    Task SubscribeAsync(string stream, string consumerGroup,
                        Func<TransportMessage, Task> handler, CancellationToken ct);
    Task UnsubscribeAsync(string stream, string consumerGroup, CancellationToken ct);
}

public interface ITransportHealth
{
    Task<bool> IsHealthyAsync(CancellationToken ct);
}
```

Implementations:
- `RedisStreamsTransport` — primary, with consumer groups, DLQ, pending recovery
- `HttpTransport` — for external clients via `/jsonrpc` endpoint
- `InMemoryTransport` — for testing, faithfully simulates Redis semantics

### Stream Naming Convention

```
rpc:{service}:{method}              → RPC request streams
reply:{callerInstance}              → RPC reply streams (one per caller, not per method)
emitter:{service}:{channel}         → Event emission streams
receiver:{service}:{channel}        → Event consumption streams
dlq:{service}:{method}              → Dead letter queue
```

The reply stream consolidation (`reply:{callerInstance}` not `reply:{service}:{method}:{caller}`) reduces stream proliferation. CorrelationId matches responses.

### Middleware Pipeline

Every mature messaging framework supports middleware. The framework provides a pipeline pattern:

```csharp
public interface IRpcMiddleware
{
    Task<JsonRpcResponse> InvokeAsync(RpcContext context, RpcDelegate next);
}
```

Built-in middleware (executed in order):

1. **DeadlineEnforcementMiddleware** — cancel if past deadline
2. **TelemetryMiddleware** — start Activity, record metrics
3. **AuthContextMiddleware** — validate JWT, set ClaimsPrincipal
4. **TenantContextMiddleware** — resolve tenant from auth context
5. **IdempotencyMiddleware** — check MessageId dedup store
6. **ValidationMiddleware** — validate params against schema
7. **TransactionMiddleware** — optional, wraps handler in DB transaction
8. **[Handler execution]**

Custom middleware registration:
```csharp
services.AddBseRpc(rpc => {
    rpc.UseMiddleware<AuditLogMiddleware>();
    rpc.UseMiddleware<RateLimitMiddleware>();
});
```

### Redis Streams Hardening

#### Stream Trimming

Every `XADD` uses `MAXLEN ~ N` (approximate trimming for efficiency):

| Stream Type | Default MAXLEN |
|---|---|
| RPC streams | 10,000 |
| Event streams | 100,000 |
| Reply streams | 100 |

Without trimming, Redis memory grows unboundedly.

#### Pending Recovery

Use `XAUTOCLAIM` (Redis 6.2+) instead of `XPENDING + XCLAIM`:
- Atomic pending message recovery
- Runs on startup and periodically (configurable interval)
- Avoids race conditions under concurrent recovery

#### Backpressure

Bounded `System.Threading.Channels` between polling loop and handler dispatch:
- Configurable capacity (default 100)
- Stops reading when full
- Exposed as metric: `bse.rpc.consumer.channel_utilization`

#### Consumer Groups

- Each service instance joins consumer group named `{service}`
- Multiple instances share the group → Redis distributes messages
- ACK after handler completes (at-least-once semantics)
- Failed messages retry with exponential backoff + jitter
- After max retries → DLQ

### Resilience (Polly v8)

Built into remote service proxy via `Microsoft.Extensions.Resilience`:

```csharp
services.AddRemoteService<IBillingService>(options => {
    options.Timeout = TimeSpan.FromSeconds(10);
    options.Retry = new RetryOptions {
        MaxAttempts = 3,
        BackoffType = DelayBackoffType.ExponentialWithJitter
    };
    options.CircuitBreaker = new CircuitBreakerOptions {
        FailureRatio = 0.5,
        SamplingDuration = TimeSpan.FromSeconds(30),
        BreakDuration = TimeSpan.FromSeconds(15)
    };
    options.ConcurrencyLimit = 25;  // bulkhead
});
```

### Idempotency

Every `TransportMessage` has a `MessageId`. The `IdempotencyMiddleware`:
1. Checks Redis: `SET {messageId} NX EX 86400`
2. If key exists → returns cached response, skips handler
3. If key doesn't exist → executes handler, caches response
4. Configurable TTL (default 24h)
5. Disabled per method via `[RpcMethod(Idempotent = false)]`

### Remote Service Proxy

Source generator creates client implementations from interfaces:

```csharp
[RemoteService("billing")]
public interface IBillingService
{
    Task<Invoice> CreateInvoice(CreateInvoiceRequest request);
    Task<PaymentStatus> GetPaymentStatus(int invoiceId);
}

// Generated implementation injected via DI
public class StudentService
{
    private readonly IBillingService _billing;

    public StudentService(IBillingService billing) => _billing = billing;

    [RpcMethod]
    public async Task<EnrollmentResult> Enroll(EnrollRequest request)
    {
        var invoice = await _billing.CreateInvoice(new { StudentId = request.StudentId });
        // ...
    }
}
```

### Discovery

Built-in `rpc.discover` method always registered:

```csharp
[RpcMethod(Name = "rpc.discover")]
public DiscoveryResponse Discover()
{
    // Returns all registered methods with:
    // - method name, summary, description
    // - parameter schema (JSON Schema from source generator)
    // - return type schema
    // - required permissions
}
```

### Graceful Shutdown

1. `IHostedService.StopAsync` triggered
2. Stop accepting new messages (unsubscribe from consumer groups)
3. Wait for in-flight handlers to complete (configurable timeout, default 30s)
4. **DO NOT ACK unfinished messages** → they get redelivered to other instances
5. Close Redis connections
6. Signal completion

This matches Kubernetes' default `terminationGracePeriodSeconds=30`.

### Serialization

- **Default:** System.Text.Json with source-generated `JsonSerializerContext` (AOT-friendly)
- **Optional:** MessagePack for internal service-to-service (configurable per stream)
- **Always:** generic `Serialize<T>`, never `Serialize(object)` (slower runtime type detection)

### Payload Codec — Compression + Encryption (added 2026-05-15)

Per **ADR-0011**, every RPC message is **compressed then encrypted** at the envelope layer
before it reaches any transport. The transport sees only opaque ciphertext.

**Order: compress → encrypt** (the inverse is a textbook anti-pattern — encrypted bytes
look random and don't compress).

```
┌────────────────────────┐   compress    ┌──────────────────────┐   encrypt     ┌────────────────────────┐
│ JSON-RPC envelope      │ ────────────▶ │ Brotli-compressed    │ ────────────▶ │ AEAD ciphertext + tag  │
│ (System.Text.Json)     │   (Brotli L4) │ bytes                │ (AES-256-GCM) │ (+ 13-byte framing)    │
└────────────────────────┘               └──────────────────────┘               └────────────────────────┘
```

**Wire format** (what the transport carries):

```
[1 byte version=0x01][12 byte nonce][N byte ciphertext+tag]
```

- **version** byte distinguishes raw vs compressed payloads and enables future algorithm migration.
- **nonce** is 96-bit cryptographically random per message (NIST GCM recommendation).
- **tag** is 128-bit GCM authentication tag, included in the ciphertext blob by the API.
- **AAD** binds the envelope's `id`, `method`, and timestamp into the authentication tag, so any tampering with routing metadata fails decryption.

**Abstractions** (shipped in `Bse.Framework.Rpc` v0.1.0):

```csharp
public interface IRpcCodec
{
    byte[] Encode(RpcEnvelope envelope);
    RpcEnvelope Decode(byte[] payload);
}

public interface IRpcKeyProvider
{
    Task<RpcKey> GetCurrentKeyAsync(CancellationToken ct);
    Task<RpcKey?> GetKeyByIdAsync(string keyId, CancellationToken ct);   // for rotation
}
```

**Implementations:**
- `EncryptedBrotliCodec` — production default. Brotli level 4, AES-256-GCM.
- `IdentityCodec` — test-only. No compression, no encryption. Used to inspect wire format in unit tests.
- `EnvironmentRpcKeyProvider` — reads base64 key from `BSE_RPC_KEY_<context>` env var (dev).
- `RotatingRpcKeyProvider` — wraps any inner provider with a "current + previous" key window so rotation doesn't reject in-flight messages.

**Out of scope for v0.1.0** (separate optional packages, slot in without breaking changes):
- `Bse.Framework.Rpc.Security.Aws` — AWS KMS-backed key provider.
- `Bse.Framework.Rpc.Security.AzureKeyVault` — Azure Key Vault provider.
- `Bse.Framework.Rpc.Security.HashicorpVault` — Vault provider.

**Threshold for skipping compression:** payloads under 100 bytes skip Brotli (compressed output would be larger). The version byte distinguishes the two cases on decode.

**Configuration:**

```csharp
services.AddBseRpc(rpc => {
    rpc.ServiceName = "student-service";
    rpc.UseRedisStreams("redis://localhost:6379");

    // Codec opt-out for in-process tests only.
    // In any non-test deployment, EncryptedBrotliCodec is required.
    rpc.UseCodec<EncryptedBrotliCodec>();
    rpc.UseKeyProvider<EnvironmentRpcKeyProvider>();
});
```

### Observability

#### ActivitySource per package
- `Bse.Rpc` — RPC framework spans
- `Bse.Rpc.RedisStreams` — Redis Streams transport spans
- Application code uses service-named source

#### Span Attributes (OpenTelemetry semantic conventions)
```
rpc.system              = "jsonrpc"
rpc.service             = target service name
rpc.method              = method name
rpc.jsonrpc.version     = "2.0"
rpc.jsonrpc.request_id  = MessageId
bse.tenant.id           = tenant context
bse.user.id             = authenticated user
```

#### Metrics
```
bse.rpc.requests              counter
bse.rpc.errors                counter
bse.rpc.request.duration      histogram (base-2 exponential)
bse.rpc.message.size          histogram
bse.rpc.requests.active       up-down counter
bse.rpc.consumer.lag          gauge
bse.rpc.dlq.depth             gauge
bse.rpc.circuit_breaker.state gauge (0=closed, 1=half-open, 2=open)
```

## Configuration

```csharp
services.AddBseRpc(rpc => {
    rpc.ServiceName = "student-service";
    rpc.UseRedisStreams("redis://localhost:6379");

    rpc.Streams.RpcMaxLen = 10_000;
    rpc.Streams.EventMaxLen = 100_000;
    rpc.Streams.ReplyMaxLen = 100;

    rpc.Consumer.PrefetchCount = 100;
    rpc.Consumer.AckMode = AckMode.AfterProcessing;
    rpc.Consumer.PendingRecoveryInterval = TimeSpan.FromMinutes(5);

    rpc.Idempotency.Enabled = true;
    rpc.Idempotency.Ttl = TimeSpan.FromHours(24);

    rpc.GracefulShutdown.Timeout = TimeSpan.FromSeconds(30);

    rpc.UseMiddleware<CustomMiddleware>();
});

services.AddRemoteService<IBillingService>(options => {
    options.Timeout = TimeSpan.FromSeconds(10);
    options.Retry.MaxAttempts = 3;
    options.CircuitBreaker.FailureRatio = 0.5;
});
```

## Error Handling

- Exceptions in handlers → JSON-RPC error response with mapped code
- Domain exceptions extending `BseException` carry their own error codes
- Stack traces logged but never sent over the wire in production
- Failed messages → retry → DLQ after max retries
- DLQ messages have a poison message handler (manual replay or analysis)

## Performance Considerations

- Source generators avoid runtime reflection (compile-time dispatch table)
- Connection pooling via singleton `ConnectionMultiplexer` (StackExchange.Redis)
- Pipeline batching for high-throughput emitters (`IBatch` in StackExchange.Redis)
- `Activity.IsAllDataRequested` short-circuits attribute computation when sampled out
- Default exponential histograms in metrics (better dynamic range, less storage)

## Security Considerations

- **Payload encryption (ADR-0011):** every RPC message is encrypted with AES-256-GCM at the envelope layer before reaching the transport. Operators, sidecars, network appliances, log captures, Redis replicas, and memory dumps all see only ciphertext. This is defense in depth — transport-level TLS / mTLS may also be applied, but is not relied upon for confidentiality.
- **Payload integrity (ADR-0011):** AES-GCM's 128-bit auth tag covers the ciphertext, and the envelope's routing metadata (`id`, `method`, timestamp) is bound into the AAD. Tampering with routing fields invalidates the tag.
- **Key rotation:** `RotatingRpcKeyProvider` carries a "current + previous" window so rotation never rejects in-flight messages. KMS / Vault-backed providers ship as optional packages.
- Auth context propagated via signed JWT in `TransportMessage.Auth`
- Each service validates JWT independently (zero-trust)
- mTLS optional for service-to-service (transport-level mutual auth — orthogonal to payload encryption above)
- Tenant context immutable through middleware (cannot be tampered)
- Idempotency prevents replay attacks within TTL window
- Rate limiting per tenant/user/endpoint via Polly

## Testing Strategy

- `InMemoryTransport` for unit tests (faithfully simulates Redis semantics)
- Testcontainers for integration tests with real Redis
- Test fixtures in `Bse.Framework.Testing` package
- Builder pattern for test data
- Chaos tests: kill consumer mid-processing, verify recovery

## Migration Path

Existing BSE apps:
1. Adopt RPC for new inter-app communication only
2. Existing intra-app calls remain direct method invocation
3. Gradually extract bounded contexts as separate services
4. Use `InMemoryTransport` initially, switch to Redis when distributed

## References

- ADR-0002, ADR-0009
- JSON-RPC 2.0 spec
- MassTransit, Wolverine, Rebus design patterns
- OpenTelemetry semantic conventions
