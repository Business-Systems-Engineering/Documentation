# ADR-0002: JSON-RPC 2.0 Over Multiple Transports

- **Status:** Accepted
- **Date:** 2026-04-06
- **Deciders:** BSE Framework Team
- **Tags:** rpc, protocol, transport
- **Supersedes:** `0002-json-rpc-over-redis-streams.md` (earlier Redis-specific decision)

## Context

The framework must support distributed computing across services. The existing BSE apps have no
inter-service communication today — all three are monolithic Web API 2 applications. The framework
needs a transport that supports:

- Horizontal scaling of service workers.
- Background job processing and long-running consumers.
- Service-to-service request/response RPC.
- External client APIs over the public edge.
- A single protocol model so the team does not maintain separate error, serialization, and client
  libraries for internal vs. external traffic.

The transport choice must also satisfy the testing requirement: services should run fully in-process
during unit tests, with no external infrastructure dependency.

The original ADR-0002 fixed Redis Streams as the transport. As the transport abstraction (ADR-0009)
matured, it became clear that the protocol decision (JSON-RPC 2.0) and the primary transport
decision (Redis Streams) are separable concerns. This ADR supersedes the earlier document to record
both decisions together.

## Decision

Adopt **JSON-RPC 2.0** as the single wire protocol carried on a transport-agnostic
`TransportMessage` envelope. Three transport implementations ship with the framework:

| Transport | Package | Primary use |
|---|---|---|
| Redis Streams | `Bse.Framework.Rpc.RedisStreams` | Internal service-to-service (primary) |
| HTTP | `Bse.Framework.Rpc.Http` | External clients and edge APIs |
| In-Memory | `Bse.Framework.Testing` | Unit and integration tests |

All three implement the same four transport interfaces (`IMessagePublisher`, `IRpcClient`,
`IMessageConsumer`, `ITransportHealth` — see ADR-0009). Service handler code is transport-agnostic:
the same handler that processes requests over Redis in production receives them over the in-memory
transport in tests.

The `TransportMessage` envelope carries routing metadata (service name, method, correlation ID,
reply-to stream, deadline, W3C trace context, tenant ID, user ID, user code) separately from the
JSON-RPC 2.0 payload. The envelope is what the codec (ADR-0011) compresses and encrypts; the
transport sees only opaque bytes.

## Options Considered

### Option A: gRPC / protobuf for service-to-service, JSON-RPC 2.0 for external
- **Pros:** gRPC gives protobuf code-gen, bidirectional streaming, and strong .NET support with
  high throughput for internal calls.
- **Cons:** Two protocol stacks (two error models, two interceptor systems, two client libraries).
  gRPC does not naturally ride on Redis Streams — a gateway would be needed. Cognitive cost of
  context-switching between protocols doubles onboarding time. The team has no existing gRPC
  experience.

### Option B: REST / OpenAPI everywhere
- **Pros:** Universal tooling; every HTTP client speaks it.
- **Cons:** REST has no standard error model and no standard request-ID / correlation-ID
  convention. Background-job and pub/sub patterns don't map cleanly to HTTP semantics.
  Horizontal scaling of consumers requires an external queue anyway, re-introducing a second
  protocol for that path.

### Option C: JSON-RPC 2.0 over pluggable transports [chosen]
- **Pros:** Single protocol everywhere — one serialization format, one error model, one client
  library. Transport-agnostic service code; swapping Redis for HTTP for in-memory requires no
  handler changes. JSON-RPC 2.0 notifications (request without `id`) map naturally to events and
  background jobs. The BSE team already knows JSON-RPC 2.0 from the Python framework. The
  transport abstraction (ADR-0009) makes the choice durable without locking transport
  implementations.
- **Cons:** No built-in bidirectional streaming (can be added as a WebSocket transport later
  without changing the protocol). No protobuf-style schema code-gen (mitigated by source generators
  in `Bse.Framework.SourceGenerators`). JSON serialization overhead vs. binary formats (mitigated
  by `System.Text.Json` source-generated context).

## Rationale

Consistency wins. A single protocol means a single mental model, a single middleware pipeline
(ADR-0009's `IRpcInvocationFilter` chain), and a single observability story. The transport
abstraction already exists (ADR-0009), so the choice of Redis Streams as the primary transport
is an implementation detail that can be changed without touching handler code. For the current
BSE scale and team size, the simpler protocol stack is the right trade-off.

## Consequences

### Positive
- One protocol, one serialization format, one error system across all deployment topologies.
- Service handlers are transport-agnostic; tests run fully in-process.
- Familiar to the team (existing Python framework uses JSON-RPC 2.0).
- Standard JSON-RPC 2.0 tooling and external clients work without adaptation.
- Redis Streams consumer groups provide at-least-once delivery, dead-letter queues, and
  horizontal worker scaling without additional infrastructure.

### Negative
- No bidirectional streaming; a future WebSocket transport is the planned extension point.
- No protobuf-style schema code-gen for strong typing across service boundaries (partially
  mitigated by source generators).

### Neutral
- MessagePack serialization can be added as an alternative codec for high-performance internal
  paths; the `IRpcCodec` abstraction (ADR-0011) accommodates this.
- The `rpc.discover` method can be added later to expose an introspection endpoint without
  protocol changes.

## References

- JSON-RPC 2.0 Specification: <https://www.jsonrpc.org/specification>
- RFC-0002: RPC and Distributed Computing
- ADR-0009: Segregated Transport Interfaces (ISP)
- ADR-0011: Encrypt and Compress RPC Payloads in Transit
