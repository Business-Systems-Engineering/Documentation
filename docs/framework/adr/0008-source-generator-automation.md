# ADR-0008: Roslyn Source-Generator Handler Registration

- **Status:** Accepted
- **Date:** 2026-04-06
- **Deciders:** BSE Framework Team
- **Tags:** source-generators, rpc, compile-time, roslyn

## Context

The existing BSE apps require massive amounts of boilerplate: 240+ manual service registrations in
`IocConfigurator.cs` (SafePack2), 40–90 hand-written repository implementations per app, and
manual wiring of RPC handlers to dispatcher method tables. Adding a new RPC handler required
editing two files: the handler class and the DI registration. Forgetting the second file produced
a runtime error with no compile-time signal.

The framework needed a way to register RPC handlers automatically without runtime reflection
(incompatible with AOT) and without T4 templates (drift problem). Compile-time registration also
enables compile-time validation — catching structural mistakes (wrong interface, abstract class,
duplicate method name) before the service starts.

## Decision

An **incremental Roslyn source generator** (`BseRpcHandlerGenerator`,
`IIncrementalGenerator`) discovers every class annotated with
`[BseRpcHandler("method.name")]` and emits a single `AddBseRpcGeneratedHandlers` extension
method on `BseRpcBuilder` in a generated file `BseGeneratedRpcRegistrations.g.cs`. Each
discovered handler produces one call to `AddHandler<THandler, TRequest, TResponse>(builder, "method")`
for request/response handlers, or `AddNotificationHandler<THandler, TRequest>(builder, "method")`
for notification handlers.

Authentication gating is opt-in per handler: adding `[RequiresAuthentication]` alongside
`[BseRpcHandler]` causes the generator to emit `requiresAuthentication: true` in the registration
call. The runtime `AuthenticationInvocationFilter` then rejects unauthenticated envelopes with a
typed `Unauthenticated` (JSON-RPC code –32006) error before the handler runs.

The generator emits diagnostics BSE0001–BSE0006 for structural violations:

| Code | Severity | Condition |
|------|----------|-----------|
| BSE0001 | Error | Class implements both `IRpcHandler<,>` and `IRpcNotificationHandler<>` |
| BSE0002 | Error | Class implements neither interface |
| BSE0003 | Error | `[BseRpcHandler]` method name is empty |
| BSE0004 | Error | Handler class is abstract |
| BSE0005 | Error | Handler class is generic |
| BSE0006 | Error | Multiple closed forms of the same interface on one class |

```csharp
// Attribute declaration (Bse.Framework.SourceGenerators.Attributes)
[AttributeUsage(AttributeTargets.Class, Inherited = false, AllowMultiple = false)]
public sealed class BseRpcHandlerAttribute : Attribute
{
    public BseRpcHandlerAttribute(string method) { Method = method; }
    public string Method { get; }
}

[AttributeUsage(AttributeTargets.Class, Inherited = false, AllowMultiple = false)]
public sealed class RequiresAuthenticationAttribute : Attribute { }

// Example usage
[BseRpcHandler("students.get")]
[RequiresAuthentication]
public sealed class GetStudentHandler : IRpcHandler<GetStudentRequest, GetStudentResponse>
{
    public Task<GetStudentResponse> HandleAsync(GetStudentRequest req, CancellationToken ct)
        => ...;
}

// Generated output (excerpt)
public static BseRpcBuilder AddBseRpcGeneratedHandlers(this BseRpcBuilder builder)
{
    BseRpcBuilderHandlerExtensions
        .AddHandler<GetStudentHandler, GetStudentRequest, GetStudentResponse>(
            builder, "students.get", requiresAuthentication: true);
    return builder;
}
```

The generator implements `IIncrementalGenerator` (not the older `ISourceGenerator`) and captures
only plain-data `HandlerInfo` records — not Roslyn symbols — between pipeline stages, preserving
IDE incremental cache correctness. Discovered handlers are sorted by method name before emission
so the output is deterministic across builds.

## Options Considered

### Option A: Reflection assembly-scan at startup
- **Pros:** Simple to implement; no build-time complexity.
- **Cons:** Runtime overhead; incompatible with Native AOT; errors discovered at service startup
  rather than at compile time; no compile-time validation of handler structure.

### Option B: Manual registration
- **Pros:** No tooling required; always visible.
- **Cons:** Exactly the 240+ registration problem the framework must solve; forgetting a
  registration silently drops a method from the dispatcher; no structural validation.

### Option C: Roslyn source generator (chosen)
- **Pros:** Zero runtime overhead; AOT-compatible; structural errors (BSE0001–BSE0006) are
  compiler errors visible in the IDE; generated file is deterministic and auditable; output
  regenerates automatically on every build when handler classes change.
- **Cons:** Generator targets `netstandard2.0` (compiler constraint); must use
  `IIncrementalGenerator` for IDE performance; debugging generated code requires special tooling.

## Rationale

Source generators are the modern .NET pattern for eliminating registration boilerplate (Microsoft
uses them in `System.Text.Json`, logging source generators, and regex). They give compile-time
automation without the drift that plagues T4 templates. The `[BseRpcHandler]` + `[RequiresAuthentication]`
attribute pair gives handler authors a clear, minimal surface: declare the method name, declare
whether auth is required, implement the interface — the registration is generated. Runtime
reflection assembly-scan was rejected because Native AOT is a framework design requirement and
scan-at-startup produces runtime failures rather than compiler errors.

## Consequences

### Positive
- Forgetting to register a handler is a compiler error (the method simply doesn't appear in
  the generated extension method).
- Structural mistakes (abstract class, wrong interface, empty method name) are compiler errors
  caught in the IDE before a build runs.
- Auth gating (`[RequiresAuthentication]`) is declared on the handler class itself — colocated
  with the business logic, not in a separate registration file.
- Generated output is deterministic and diff-friendly in code review.
- AOT-compatible by construction — no reflection at runtime.

### Negative
- Generator must target `netstandard2.0` (the Roslyn host runs on .NET Framework on Windows).
- `IIncrementalGenerator` pipeline design is non-trivial; Roslyn objects must not escape the
  transform stage or IDE caching breaks.
- Generated code is harder to step through in the debugger without `#line` directive tooling.
- Duplicate `[BseRpcHandler("same.method")]` across two classes is a runtime
  `BseConfigurationException` at `AddBseRpc` completion time, not a BSE diagnostic.

### Neutral
- Attributes ship in `Bse.Framework.SourceGenerators.Attributes` (consumed at runtime); the
  generator itself ships in `Bse.Framework.SourceGenerators` (build-time only, never deployed).
- Generated file uses the naming convention `BseGeneratedRpcRegistrations.g.cs`.
- Handler classes are sorted alphabetically by method name in the generated output.

## References

- RFC-0002: RPC and Distributed Computing
- ADR-0014: RPC Per-Handler Auth Gating
- [`Bse.Framework.SourceGenerators/BseRpcHandlerGenerator.cs`]
- [`Bse.Framework.SourceGenerators.Attributes/BseRpcHandlerAttribute.cs`]
- [`Bse.Framework.SourceGenerators.Attributes/RequiresAuthenticationAttribute.cs`]
- Roslyn Incremental Generators documentation
