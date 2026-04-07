# ADR-0009: Transport Abstraction with Interface Segregation

- **Status:** Accepted
- **Date:** 2026-04-06
- **Tags:** rpc, transport, architecture, interface-design

## Context

The framework needs to support multiple transports for the same JSON-RPC 2.0 protocol: Redis Streams (primary), HTTP (for external clients), and In-Memory (for testing). Different services have different needs — some only publish events, some only consume, some only call other services. Forcing every consumer to depend on a monolithic `IRpcTransport` interface that combines all operations violates the Interface Segregation Principle.

The original design had a single interface:
```csharp
public interface IRpcTransport
{
    Task PublishAsync(...);
    Task<TransportMessage> RequestAsync(...);
    Task SubscribeAsync(...);
    Task<bool> IsHealthyAsync(...);
}
```

Industry review identified this as a problem — MassTransit, Rebus, and NServiceBus all separate publish/request/consume into distinct interfaces.

## Decision

Split the transport abstraction into **four focused interfaces** following the Interface Segregation Principle:

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

Each transport implementation (Redis Streams, HTTP, In-Memory) implements all four interfaces, but **consumers only depend on what they need**.

## Options Considered

### Option A: Monolithic IRpcTransport
- **Pros:** Single interface, simple to register
- **Cons:** Violates ISP, every consumer depends on operations they don't use, harder to mock for tests, harder to compose

### Option B: Split by Operation (Publish, Request, Consume, Health)
- **Pros:** Follows ISP, focused interfaces, consumers depend only on what they use, easier to test, matches MassTransit/Rebus patterns
- **Cons:** More interfaces to register, slightly more code

### Option C: Split by Transport Type (IRedisTransport, IHttpTransport)
- **Pros:** Maximum specificity
- **Cons:** Defeats the purpose of abstraction, couples consumers to transport choice

## Rationale

Industry-standard messaging frameworks (MassTransit, Rebus, NServiceBus) all use the segregated approach. A service that only publishes events shouldn't depend on subscription logic. A test can mock `IRpcClient` without implementing all four interfaces. The pattern composes naturally with DI.

## Consequences

### Positive
- Each consumer depends only on what it uses
- Easier to test (mock only the needed interface)
- Composes naturally with DI
- Matches industry-standard messaging frameworks
- Allows different lifetimes for different concerns (e.g., publisher singleton, consumer per-instance)

### Negative
- Four interfaces to register per transport (not one)
- Slightly more documentation surface
- Developers must learn which interface to inject

### Neutral
- Each transport (Redis Streams, HTTP, In-Memory) implements all four
- Framework provides extension methods to register all four with one call: `services.AddBseRpc().UseRedisStreams(...)`
- Middleware pipeline is separate concern (see RFC-0002)

## References

- ADR-0002: JSON-RPC 2.0 Over Multiple Transports
- RFC-0002: RPC and Distributed Computing
- MassTransit interface design
- Rebus transport abstraction
- Interface Segregation Principle (SOLID)
