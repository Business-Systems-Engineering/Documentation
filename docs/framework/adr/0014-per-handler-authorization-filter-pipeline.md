# ADR-0014: Per-Handler Authorization via an Invocation-Filter Pipeline

- **Status:** Accepted
- **Date:** 2026-07-05
- **Deciders:** BSE Framework Team
- **Tags:** auth, authorization, rpc, dispatcher, extensibility

## Context

After cross-process identity propagation was established (ADR-0013), the next question is: how
does the framework enforce that a handler requiring an authenticated caller actually *gets* one,
without every handler author writing the same `if (user.IsAuthenticated == false) throw` guard?

Three constraints shape the design:

1. **Declaration site.** Auth requirements should be declared where the handler is defined —
   not scattered across caller code or configuration files.
2. **No Bse.Framework.Auth dependency in the dispatcher.** `Bse.Framework.Rpc` is the core
   package; pulling `IBseUserAccessor` or `BseUser` into it would create a layering-violating
   dependency.
3. **Extensibility.** Future policy enforcement (ABAC, fine-grained permissions, rate limits)
   should use the same seam rather than requiring changes to the dispatcher.

## Decision

Introduce an **`IRpcInvocationFilter` pipeline** in `RpcDispatcher`. Filters are resolved from
the per-message DI scope, run in registration order after inbound identity scopes have been
pushed and before the handler is invoked. A filter returns `null` to allow the call or a
`RpcError` to short-circuit:

```csharp
public interface IRpcInvocationFilter
{
    ValueTask<RpcError?> BeforeInvokeAsync(RpcInvocationContext context, CancellationToken ct);
}
```

The dispatcher iterates filters before calling `descriptor.Invoker`:

```csharp
foreach (var filter in scope.ServiceProvider.GetServices<IRpcInvocationFilter>())
{
    var filterError = await filter.BeforeInvokeAsync(
        new RpcInvocationContext(envelope, descriptor, scope.ServiceProvider),
        deadlineToken);

    if (filterError is not null)
        return BuildErrorReply(envelope, rpcRequest, filterError);
}
```

The built-in `AuthenticationInvocationFilter` enforces `[RequiresAuthentication]` with no
dependency on `Bse.Framework.Auth` — it checks `envelope.UserId is null`, the same null-check
the inbound user scope uses to determine whether a user was propagated:

```csharp
internal sealed class AuthenticationInvocationFilter : IRpcInvocationFilter
{
    public ValueTask<RpcError?> BeforeInvokeAsync(RpcInvocationContext context, CancellationToken ct)
    {
        if (context.Descriptor.RequiresAuthentication && context.Envelope.UserId is null)
        {
            return new ValueTask<RpcError?>(new RpcError(
                RpcErrorCodes.Unauthenticated,
                "This method requires an authenticated caller."));
        }
        return new ValueTask<RpcError?>((RpcError?)null);
    }
}
```

The attribute flows from source through the Roslyn source generator into `HandlerDescriptor`:

```csharp
// Handler class:
[BseRpcHandler("students.get")]
[RequiresAuthentication]
public sealed class GetStudentHandler : IRpcHandler<GetStudentRequest, GetStudentResponse> { … }

// Generated registration (emitted by BseRpcHandlerGenerator):
builder.AddHandler<GetStudentHandler, GetStudentRequest, GetStudentResponse>(
    "students.get", requiresAuthentication: true);

// HandlerDescriptor record:
public sealed record HandlerDescriptor(
    string Method, Type RequestType, Type? ResponseType, Type HandlerType,
    Func<IServiceProvider, JsonElement, CancellationToken, ValueTask<JsonElement?>> Invoker,
    bool RequiresAuthentication = false);
```

Rejected unauthenticated calls return error code `-32006` (`Unauthenticated`) as an ack-path
error reply — the message is acknowledged and not retried.

## Options Considered

### Option A: Per-handler in-code IsAuthenticated checks
- **Pros:** Explicit; no framework machinery needed
- **Cons:** Every handler author must remember the guard; not enforceable at compile time;
  inconsistent placement leads to diverging error shapes and missing coverage

### Option B: Transport middleware (before the dispatcher)
- **Pros:** Centralized; applies before any handler code runs
- **Cons:** Cannot distinguish per-method requirements — all methods share one rule or none;
  transport middleware cannot see `HandlerDescriptor` metadata; misaligns with the
  per-handler declaration intent

### Option C: Declarative attribute + invocation-filter pipeline (chosen)
- **Pros:** Requirement declared at the handler class; enforced uniformly by a pipeline the
  dispatcher owns; `Bse.Framework.Rpc` stays free of auth dependencies; the same seam accepts
  future policy/ABAC filters without dispatcher changes; short-circuit is an ack-path reply
  (no retry storm on auth denial)
- **Cons:** An additional abstraction (`IRpcInvocationFilter`) to learn; filters resolved from
  DI must be registered correctly or they silently have no effect

## Rationale

The filter pipeline is the natural extension point for cross-cutting per-invocation concerns.
Keeping `AuthenticationInvocationFilter` free of `Bse.Framework.Auth` dependencies (it only
reads `envelope.UserId`) preserves the layering: the RPC core enforces auth at the envelope
level; the auth package adds richer identity mapping above it. The attribute-to-source-
generator-to-`HandlerDescriptor` path means the requirement is declared once and checked at
build time (the generator emits the `requiresAuthentication: true` argument); the runtime
check is a single field read on an already-resolved descriptor.

## Consequences

### Positive
- `[RequiresAuthentication]` on a handler class is the single declaration point; no
  boilerplate guard code inside the handler body
- Adding a new enforcement concern (e.g., ABAC policy, rate limiter) is a new
  `IRpcInvocationFilter` implementation registered in DI — the dispatcher does not change
- Unauthenticated errors are ack-path replies, not exceptions, so transport retry logic
  is not triggered by auth denials

### Negative
- Filters registered in DI with the wrong lifetime (e.g., a singleton capturing a scoped
  service) will silently malfunction — no compile-time guard exists for lifetime mismatches
- The source generator must track `[RequiresAuthentication]` across incremental compilation;
  a stale incremental cache can leave `RequiresAuthentication = false` until a clean build

### Neutral
- `AuthenticationInvocationFilter` is registered by default in `AddBseRpc`; services with no
  `[RequiresAuthentication]` handlers pay only the `GetServices<IRpcInvocationFilter>`
  enumeration cost (empty enumerable, near-zero overhead)
- The `RpcInvocationContext` passed to filters exposes the scoped `IServiceProvider`, so
  filters can resolve services (e.g., a policy evaluator) from the per-message scope

## References

- ADR-0008: Source Generator Automation for Handler Registration
- ADR-0013: Cross-Process Identity Propagation on the Envelope
- RFC-0002: RPC and Distributed Computing
- RFC-0004: Auth and Security
- `Bse.Framework.Rpc/Dispatcher/IRpcInvocationFilter.cs`
- `Bse.Framework.Rpc/Dispatcher/AuthenticationInvocationFilter.cs`
- `Bse.Framework.Rpc/Dispatcher/RpcDispatcher.cs`
- `Bse.Framework.Rpc/Handlers/HandlerDescriptor.cs`
- `Bse.Framework.SourceGenerators.Attributes/RequiresAuthenticationAttribute.cs`
- `Bse.Framework.SourceGenerators/BseRpcHandlerGenerator.cs`
