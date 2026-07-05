# ADR-0009: Segregated Transport Interfaces (ISP)

- **Status:** Accepted
- **Date:** 2026-04-06
- **Deciders:** BSE Framework Team
- **Tags:** rpc, transport, architecture, interface-design

## Context

The framework needs to support multiple transports for the same JSON-RPC 2.0 protocol: Redis Streams
(primary), HTTP (for external clients), and In-Memory (for testing). Different services have
different needs — some only publish events, some only consume, some only call other services.
Forcing every consumer to depend on a monolithic `IRpcTransport` interface that combines all
operations violates the Interface Segregation Principle.

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

Industry review identified this as a problem — MassTransit, Rebus, and NServiceBus all separate
publish/request/consume into distinct interfaces.

## Decision

Split the transport abstraction into **four focused interfaces** following the Interface Segregation
Principle:

```csharp
public interface IMessagePublisher
{
    Task PublishAsync(string stream, TransportMessage message,
                      CancellationToken cancellationToken = default);
}

public interface IRpcClient
{
    Task<TransportMessage> RequestAsync(
        string stream,
        TransportMessage message,
        TimeSpan timeout,
        CancellationToken cancellationToken = default);
}

public interface IMessageConsumer
{
    Task SubscribeAsync(
        string stream,
        string consumerGroup,
        Func<TransportMessage, CancellationToken, Task<TransportMessage?>> handler,
        CancellationToken cancellationToken = default);

    Task UnsubscribeAsync(string stream, string consumerGroup,
                          CancellationToken cancellationToken = default);
}

public interface ITransportHealth
{
    Task<bool> IsHealthyAsync(CancellationToken cancellationToken = default);
}
```

The `IMessageConsumer` handler signature is
`Func<TransportMessage, CancellationToken, Task<TransportMessage?>>`: the handler returns a response
envelope for request streams, or `null` for notification (fire-and-forget) streams. Transports
apply at-least-once semantics — the handler is acknowledged after it returns successfully; throwing
causes a retry.

Each transport implementation (Redis Streams, HTTP, In-Memory) implements all four interfaces, but
**consumers only inject what they need**.

## Options Considered

### Option A: Monolithic `IRpcTransport`
- **Pros:** Single interface, single registration per transport.
- **Cons:** Violates ISP. Every consumer depends on operations it doesn't use. Harder to mock
  in tests — a mock must implement all four capabilities even when only one is exercised.
  Harder to assign different DI lifetimes to publish vs. consume concerns.

### Option B: Split by operation (Publish, Request, Consume, Health) [chosen]
- **Pros:** Follows ISP. Consumers inject only what they use. Each interface is independently
  mockable. Matches MassTransit, Rebus, and NServiceBus patterns. Different DI lifetimes
  are possible per interface (e.g. publisher as singleton, consumer as per-instance hosted service).
- **Cons:** Four registrations per transport instead of one. Slightly more documentation surface.
  Developers must learn which interface to inject for which scenario.

### Option C: Split by transport type (`IRedisTransport`, `IHttpTransport`)
- **Pros:** Maximum specificity — callers know exactly what backing infrastructure they use.
- **Cons:** Defeats the purpose of abstraction. Couples handler and publisher code to a specific
  transport, making transport substitution (e.g. swapping Redis for in-memory in tests) require
  code changes rather than DI reconfiguration.

## Rationale

Industry-standard messaging frameworks (MassTransit, Rebus, NServiceBus) all use the segregated
approach. A service that only publishes events should not depend on subscription or health-check
logic. A unit test that exercises `IRpcClient` should not need to provide a full `IMessageConsumer`
implementation. The segregated interfaces compose naturally with DI and make integration tests
cheaper to write.

## Consequences

### Positive
- Each consumer depends only on the interfaces it uses.
- Easier to test: mock only the needed interface.
- Composes naturally with DI.
- Matches industry-standard messaging framework patterns.
- Different DI lifetimes are assignable to different concerns.

### Negative
- Four interfaces to register per transport (not one).
- Slightly more documentation surface.
- Developers must learn which interface to inject for each use case.

### Neutral
- Each transport (Redis Streams, HTTP, In-Memory) implements all four.
- Framework provides extension methods to register all four in one call:
  `builder.AddBseRpc(rpc => rpc.UseRedisStreams(...))`.
- The middleware pipeline (`IRpcInvocationFilter` chain) is a separate concern wired in the
  dispatcher, not in the transport interfaces.

## References

- RFC-0002: RPC and Distributed Computing
- ADR-0002: JSON-RPC 2.0 Over Multiple Transports
- MassTransit interface design
- Rebus transport abstraction
- Interface Segregation Principle (SOLID)
