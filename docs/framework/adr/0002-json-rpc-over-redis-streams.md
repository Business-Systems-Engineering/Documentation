# ADR-0002: JSON-RPC 2.0 Over Multiple Transports (Redis Streams Primary)

- **Status:** Accepted
- **Date:** 2026-04-06
- **Tags:** rpc, distributed-computing, transport, messaging

## Context

The framework must support distributed computing across services. The existing BSE apps have NO inter-service communication today (monolithic Web API 2). We need a transport that supports horizontal scaling, background job processing, service-to-service communication, and external client APIs.

## Decision

Use **JSON-RPC 2.0** as the protocol with a **transport abstraction** that supports Redis Streams (primary), HTTP, and In-Memory. Single protocol, multiple transports — same service code runs in any deployment topology.

## Options Considered

### Option A: JSON-RPC 2.0 Over Multiple Transports
- **Pros:** Single protocol everywhere (one serialization, one error model, one client library), proven JSON-RPC 2.0 implementations exist (Python framework), Redis Streams provides consumer groups + DLQ + horizontal scaling, external clients speak the same protocol as internal services
- **Cons:** No built-in streaming (request/response only), no schema-based code-gen like protobuf

### Option B: gRPC for Service-to-Service + JSON-RPC 2.0 for External
- **Pros:** gRPC gives protobuf code-gen, bidirectional streaming, strong .NET support, better performance for high-throughput internal calls
- **Cons:** Two protocol stacks to maintain, two error models, two interceptor systems, gRPC doesn't naturally ride on Redis Streams (would need gateway), more complexity

### Option C: JSON-RPC 2.0 Everywhere with Transport Abstraction
- **Pros:** Combines best of A and B — single protocol via Myriad-style transport abstraction
- **Cons:** Same as Option A

## Rationale

Consistency wins. The team already knows JSON-RPC 2.0 from the Python framework. The Redis Streams patterns from Myriad and caaspay translate directly. Avoiding the "two protocol tax" reduces cognitive load. JSON-RPC 2.0 notifications (request without `id`) map naturally to event streaming. For server-sent events, WebSocket transport can be added later without changing the protocol.

## Consequences

### Positive
- One protocol, one serialization format, one error system
- Transport-agnostic services — same code in-process, over Redis, or over HTTP
- Familiar to team (Python framework experience)
- Standard JSON-RPC 2.0 tooling and clients work
- Discovery endpoint (`rpc.discover`) provides introspection
- External and internal services speak the same protocol

### Negative
- No bidirectional streaming (would need separate WebSocket transport)
- No protobuf-style code-gen for strong typing (mitigated via source generators)
- JSON serialization overhead vs binary formats (mitigated via System.Text.Json source-generated context)

### Neutral
- MessagePack can be added as alternative serialization for high-performance internal paths
- WebSocket transport can be added later if streaming is needed

## References

- JSON-RPC 2.0 Specification: https://www.jsonrpc.org/specification
- ADR-0009: Transport Abstraction Pattern
- RFC-0002: RPC & Distributed Computing
