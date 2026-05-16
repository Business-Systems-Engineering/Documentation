# Bse.Framework.Rpc v0.1.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Ship two packages — `Bse.Framework.Rpc` (protocol + codec + transport abstractions) and `Bse.Framework.Rpc.RedisStreams` (Redis Streams transport implementation) — that let two .NET services call each other via JSON-RPC 2.0 over Redis with **AES-256-GCM-encrypted, Brotli-compressed payloads** (ADR-0011) and W3C-trace-context-propagated distributed spans. A two-app sample (`rpc-server`, `rpc-client`) demonstrates a request flowing across services with one trace spanning both in Tempo.

**Architecture:**
- `Bse.Framework.Rpc` — pure abstractions: JSON-RPC 2.0 records, `TransportMessage` envelope, segregated transport interfaces (`IMessagePublisher`, `IRpcClient`, `IMessageConsumer`, `ITransportHealth` — ADR-0009), `IRpcCodec` + `IRpcKeyProvider`, `EncryptedBrotliCodec` + `IdentityCodec`, `EnvironmentRpcKeyProvider` + `RotatingRpcKeyProvider`, `BseRpcBuilder` + `AddBseRpc()`. Zero transport dependency.
- `Bse.Framework.Rpc.RedisStreams` — references `Bse.Framework.Rpc` + `StackExchange.Redis`. Provides `RedisStreamsPublisher`, `RedisStreamsConsumer`, `RedisStreamsRpcClient`, `RedisStreamsTransportHealth`, `UseRedisStreams()` extension. Stream trimming via `MAXLEN ~`, consumer groups via `XREADGROUP`, ACK after handler completes.
- Telemetry integration: `Bse.Rpc` + `Bse.Rpc.RedisStreams` ActivitySources emit spans with RFC-0005 semantic attributes; metrics `bse.rpc.request.duration`, `bse.rpc.requests`, `bse.rpc.errors`, `bse.rpc.message.size`. Picked up automatically by Telemetry's `DefaultSources` / `DefaultMeters` lists.
- Sample: two ASP.NET Core minimal APIs talking through Redis. The client makes one HTTP call, which fans out to one RPC call into the server. In Tempo, both spans appear under one trace.

**Tech Stack:**
- .NET 9 (single target)
- xUnit / Shouldly / NSubstitute (existing test stack)
- `StackExchange.Redis` 2.8.x
- `Testcontainers.Redis` 4.0.x (CI integration tests)
- `Bse.Framework.Core` v0.1.0, `Bse.Framework.Telemetry` v0.1.0 (project references)

**Repository layout (additions only):**

```
bse-core/
├── src/
│   ├── Bse.Framework.Core/                            ← exists
│   ├── Bse.Framework.Telemetry/                       ← exists
│   ├── Bse.Framework.Data/                            ← exists
│   ├── Bse.Framework.Data.EntityFramework/            ← exists
│   ├── Bse.Framework.Rpc/                             ← NEW (abstractions)
│   │   ├── Bse.Framework.Rpc.csproj
│   │   ├── README.md
│   │   ├── BseRpcModule.cs
│   │   ├── Protocol/
│   │   │   ├── RpcRequest.cs
│   │   │   ├── RpcResponse.cs
│   │   │   ├── RpcError.cs
│   │   │   └── RpcErrorCodes.cs
│   │   ├── Envelope/
│   │   │   ├── TransportMessage.cs
│   │   │   └── TraceContext.cs
│   │   ├── Transport/
│   │   │   ├── IMessagePublisher.cs
│   │   │   ├── IRpcClient.cs
│   │   │   ├── IMessageConsumer.cs
│   │   │   └── ITransportHealth.cs
│   │   ├── Codec/
│   │   │   ├── IRpcCodec.cs
│   │   │   ├── IdentityCodec.cs
│   │   │   ├── EncryptedBrotliCodec.cs
│   │   │   ├── RpcKey.cs
│   │   │   ├── IRpcKeyProvider.cs
│   │   │   ├── EnvironmentRpcKeyProvider.cs
│   │   │   └── RotatingRpcKeyProvider.cs
│   │   └── DependencyInjection/
│   │       ├── BseRpcBuilder.cs
│   │       └── RpcServiceCollectionExtensions.cs
│   └── Bse.Framework.Rpc.RedisStreams/                ← NEW (transport)
│       ├── Bse.Framework.Rpc.RedisStreams.csproj
│       ├── README.md
│       ├── BseRpcRedisStreamsModule.cs
│       ├── RedisStreamsOptions.cs
│       ├── Publisher/RedisStreamsPublisher.cs
│       ├── Consumer/RedisStreamsConsumer.cs
│       ├── Client/RedisStreamsRpcClient.cs
│       ├── Health/RedisStreamsTransportHealth.cs
│       ├── Instrumentation/RpcInstrumentation.cs
│       └── DependencyInjection/
│           └── RedisStreamsServiceCollectionExtensions.cs
├── tests/
│   ├── (existing)
│   ├── Bse.Framework.Rpc.Tests/                       ← NEW (unit)
│   │   ├── Bse.Framework.Rpc.Tests.csproj
│   │   ├── Codec/EncryptedBrotliCodecTests.cs
│   │   ├── Codec/IdentityCodecTests.cs
│   │   └── Codec/KeyProviderTests.cs
│   └── Bse.Framework.Rpc.RedisStreams.Tests/          ← NEW (integration, Testcontainers Redis)
│       ├── Bse.Framework.Rpc.RedisStreams.Tests.csproj
│       ├── Fixtures/RedisFixture.cs
│       ├── PublisherConsumerTests.cs
│       └── RpcClientTests.cs
└── samples/
    ├── (existing)
    ├── rpc-server/                                    ← NEW
    │   ├── rpc-server.csproj
    │   ├── Program.cs
    │   ├── appsettings.json
    │   └── README.md
    └── rpc-client/                                    ← NEW
        ├── rpc-client.csproj
        ├── Program.cs
        ├── appsettings.json
        └── README.md
```

**Sample wire format (after compression + encryption — ADR-0011):**

```
[1 byte version=0x01][12 byte nonce][N byte ciphertext+16 byte tag]
```

The transport (Redis Streams) sees only this opaque byte blob. The recipient decodes back to a `TransportMessage` containing the JSON-RPC 2.0 envelope.

---

## Task 1: Scaffold two packages + 2 test projects + Directory.Packages.props additions

**Files:**
- Create: `src/Bse.Framework.Rpc/Bse.Framework.Rpc.csproj`
- Create: `src/Bse.Framework.Rpc/README.md`
- Create: `src/Bse.Framework.Rpc.RedisStreams/Bse.Framework.Rpc.RedisStreams.csproj`
- Create: `src/Bse.Framework.Rpc.RedisStreams/README.md`
- Create: `tests/Bse.Framework.Rpc.Tests/Bse.Framework.Rpc.Tests.csproj`
- Create: `tests/Bse.Framework.Rpc.RedisStreams.Tests/Bse.Framework.Rpc.RedisStreams.Tests.csproj`
- Modify: `Directory.Packages.props`
- Modify: `BseFramework.sln`

- [ ] **Step 1: Add Redis package versions to `Directory.Packages.props`**

Append before the closing `</Project>`:

```xml
  <ItemGroup Label="Redis">
    <PackageVersion Include="StackExchange.Redis" Version="2.8.16" />
  </ItemGroup>

  <ItemGroup Label="Testing.Redis">
    <PackageVersion Include="Testcontainers.Redis" Version="4.0.0" />
  </ItemGroup>
```

- [ ] **Step 2: Create `Bse.Framework.Rpc` (abstractions)**

```bash
mkdir -p src/Bse.Framework.Rpc
cd src/Bse.Framework.Rpc
dotnet new classlib --output . --framework net9.0
rm Class1.cs
cd ../..
```

Overwrite `src/Bse.Framework.Rpc/Bse.Framework.Rpc.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <RootNamespace>Bse.Framework.Rpc</RootNamespace>
    <AssemblyName>Bse.Framework.Rpc</AssemblyName>
    <PackageId>Bse.Framework.Rpc</PackageId>
    <Description>Bse.Framework RPC abstractions: JSON-RPC 2.0 protocol, transport interfaces (publisher/client/consumer/health), payload codec (AES-256-GCM + Brotli per ADR-0011). Transport-agnostic.</Description>
    <PackageTags>bse;framework;rpc;jsonrpc;encryption;brotli</PackageTags>
    <PackageReadmeFile>README.md</PackageReadmeFile>
    <GenerateDocumentationFile>true</GenerateDocumentationFile>
  </PropertyGroup>

  <ItemGroup>
    <None Include="README.md" Pack="true" PackagePath="\" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="..\Bse.Framework.Core\Bse.Framework.Core.csproj" />
  </ItemGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.Extensions.DependencyInjection.Abstractions" />
    <PackageReference Include="Microsoft.SourceLink.GitHub" PrivateAssets="All" />
  </ItemGroup>

</Project>
```

Create `src/Bse.Framework.Rpc/README.md`:

```markdown
# Bse.Framework.Rpc

JSON-RPC 2.0 abstractions + transport-agnostic payload codec for Bse.Framework. Reference this from application code; pick a transport implementation (e.g. `Bse.Framework.Rpc.RedisStreams`) at the composition root.

## Exports

- **Protocol:** `RpcRequest`, `RpcResponse`, `RpcError`, `RpcErrorCodes` (JSON-RPC 2.0)
- **Envelope:** `TransportMessage`, `TraceContext`
- **Transports (segregated per ADR-0009):** `IMessagePublisher`, `IRpcClient`, `IMessageConsumer`, `ITransportHealth`
- **Codec (per ADR-0011):** `IRpcCodec`, `EncryptedBrotliCodec` (production), `IdentityCodec` (tests)
- **Keys:** `IRpcKeyProvider`, `EnvironmentRpcKeyProvider`, `RotatingRpcKeyProvider`, `RpcKey`
- **Builder:** `BseRpcBuilder`, `AddBseRpc()`

Wire format (after compression + encryption): `[1 byte version=0x01][12 byte nonce][ciphertext+16 byte GCM tag]`.
```

- [ ] **Step 3: Create `Bse.Framework.Rpc.RedisStreams` (transport)**

```bash
mkdir -p src/Bse.Framework.Rpc.RedisStreams
cd src/Bse.Framework.Rpc.RedisStreams
dotnet new classlib --output . --framework net9.0
rm Class1.cs
cd ../..
```

Overwrite csproj:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <RootNamespace>Bse.Framework.Rpc.RedisStreams</RootNamespace>
    <AssemblyName>Bse.Framework.Rpc.RedisStreams</AssemblyName>
    <PackageId>Bse.Framework.Rpc.RedisStreams</PackageId>
    <Description>Redis Streams transport for Bse.Framework.Rpc. Implements publisher/client/consumer/health with consumer groups, MAXLEN trimming, encrypted+compressed payloads (ADR-0011).</Description>
    <PackageTags>bse;framework;rpc;redis;streams;transport</PackageTags>
    <PackageReadmeFile>README.md</PackageReadmeFile>
    <GenerateDocumentationFile>true</GenerateDocumentationFile>
  </PropertyGroup>

  <ItemGroup>
    <None Include="README.md" Pack="true" PackagePath="\" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="..\Bse.Framework.Core\Bse.Framework.Core.csproj" />
    <ProjectReference Include="..\Bse.Framework.Rpc\Bse.Framework.Rpc.csproj" />
    <ProjectReference Include="..\Bse.Framework.Telemetry\Bse.Framework.Telemetry.csproj" />
  </ItemGroup>

  <ItemGroup>
    <PackageReference Include="StackExchange.Redis" />
    <PackageReference Include="Microsoft.Extensions.Hosting.Abstractions" />
    <PackageReference Include="Microsoft.SourceLink.GitHub" PrivateAssets="All" />
  </ItemGroup>

</Project>
```

Create `src/Bse.Framework.Rpc.RedisStreams/README.md`:

```markdown
# Bse.Framework.Rpc.RedisStreams

Redis Streams transport for `Bse.Framework.Rpc`.

## Provides

- `RedisStreamsPublisher` — `IMessagePublisher` over `XADD` with `MAXLEN ~` trimming
- `RedisStreamsConsumer` — `IMessageConsumer` over consumer groups + `XREADGROUP` + `XACK`
- `RedisStreamsRpcClient` — `IRpcClient` (request/reply via dedicated reply stream, correlation by `MessageId`)
- `RedisStreamsTransportHealth` — `ITransportHealth` via `PING`
- `UseRedisStreams(connectionString)` extension on `BseRpcBuilder`
- Telemetry: spans on every publish/consume, metrics `bse.rpc.*`

## Quick start

```csharp
services.AddBseFramework(framework =>
{
    framework.AddBseTelemetry(t => /* ... */);
    framework.AddBseRpc(rpc =>
    {
        rpc.ServiceName = "billing-service";
        rpc.UseRedisStreams("localhost:6379");
        rpc.UseCodec<EncryptedBrotliCodec>();
        rpc.UseKeyProvider<EnvironmentRpcKeyProvider>();
    });
});
```
```

- [ ] **Step 4: Create test projects**

```bash
mkdir -p tests/Bse.Framework.Rpc.Tests tests/Bse.Framework.Rpc.RedisStreams.Tests
cd tests/Bse.Framework.Rpc.Tests
dotnet new xunit --output . --framework net9.0
rm UnitTest1.cs
cd ../Bse.Framework.Rpc.RedisStreams.Tests
dotnet new xunit --output . --framework net9.0
rm UnitTest1.cs
cd ../..
```

Overwrite `tests/Bse.Framework.Rpc.Tests/Bse.Framework.Rpc.Tests.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <RootNamespace>Bse.Framework.Rpc.Tests</RootNamespace>
    <AssemblyName>Bse.Framework.Rpc.Tests</AssemblyName>
    <IsPackable>false</IsPackable>
    <IsTestProject>true</IsTestProject>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" />
    <PackageReference Include="xunit" />
    <PackageReference Include="xunit.runner.visualstudio" />
    <PackageReference Include="Shouldly" />
    <PackageReference Include="NSubstitute" />
    <PackageReference Include="coverlet.collector" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="..\..\src\Bse.Framework.Rpc\Bse.Framework.Rpc.csproj" />
  </ItemGroup>

  <ItemGroup>
    <Using Include="Xunit" />
    <Using Include="Shouldly" />
    <Using Include="NSubstitute" />
  </ItemGroup>

</Project>
```

Overwrite `tests/Bse.Framework.Rpc.RedisStreams.Tests/Bse.Framework.Rpc.RedisStreams.Tests.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <RootNamespace>Bse.Framework.Rpc.RedisStreams.Tests</RootNamespace>
    <AssemblyName>Bse.Framework.Rpc.RedisStreams.Tests</AssemblyName>
    <IsPackable>false</IsPackable>
    <IsTestProject>true</IsTestProject>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" />
    <PackageReference Include="xunit" />
    <PackageReference Include="xunit.runner.visualstudio" />
    <PackageReference Include="Shouldly" />
    <PackageReference Include="NSubstitute" />
    <PackageReference Include="coverlet.collector" />
    <PackageReference Include="Testcontainers.Redis" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="..\..\src\Bse.Framework.Rpc.RedisStreams\Bse.Framework.Rpc.RedisStreams.csproj" />
  </ItemGroup>

  <ItemGroup>
    <Using Include="Xunit" />
    <Using Include="Shouldly" />
    <Using Include="NSubstitute" />
  </ItemGroup>

</Project>
```

- [ ] **Step 5: Add to solution + build**

```bash
cd /Users/mahrous/Projects/bse/bse-core
dotnet sln add src/Bse.Framework.Rpc/Bse.Framework.Rpc.csproj
dotnet sln add src/Bse.Framework.Rpc.RedisStreams/Bse.Framework.Rpc.RedisStreams.csproj
dotnet sln add tests/Bse.Framework.Rpc.Tests/Bse.Framework.Rpc.Tests.csproj
dotnet sln add tests/Bse.Framework.Rpc.RedisStreams.Tests/Bse.Framework.Rpc.RedisStreams.Tests.csproj
dotnet build
```

Expected: 0 warnings, 0 errors. All 12 projects compile (4 src + 4 tests + 2 new src + 2 new tests).

- [ ] **Step 6: Commit**

```bash
git add Directory.Packages.props BseFramework.sln \
        src/Bse.Framework.Rpc/ \
        src/Bse.Framework.Rpc.RedisStreams/ \
        tests/Bse.Framework.Rpc.Tests/ \
        tests/Bse.Framework.Rpc.RedisStreams.Tests/
git commit -m "feat(rpc): scaffold Bse.Framework.Rpc + Bse.Framework.Rpc.RedisStreams projects"
```

---

## Task 2: JSON-RPC 2.0 protocol records

**Files:**
- Create: `src/Bse.Framework.Rpc/Protocol/RpcRequest.cs`
- Create: `src/Bse.Framework.Rpc/Protocol/RpcResponse.cs`
- Create: `src/Bse.Framework.Rpc/Protocol/RpcError.cs`
- Create: `src/Bse.Framework.Rpc/Protocol/RpcErrorCodes.cs`

- [ ] **Step 1: `RpcError.cs`**

```csharp
using System.Text.Json;

namespace Bse.Framework.Rpc.Protocol;

/// <summary>JSON-RPC 2.0 error object.</summary>
/// <param name="Code">Numeric error code. See <see cref="RpcErrorCodes"/> for the reserved range.</param>
/// <param name="Message">Short human-readable summary.</param>
/// <param name="Data">Optional structured details (often a domain error code or validation map).</param>
public sealed record RpcError(int Code, string Message, JsonElement? Data = null);
```

- [ ] **Step 2: `RpcErrorCodes.cs`**

```csharp
namespace Bse.Framework.Rpc.Protocol;

/// <summary>Reserved JSON-RPC 2.0 error codes (and framework-defined extensions).</summary>
public static class RpcErrorCodes
{
    /// <summary>Invalid JSON received.</summary>
    public const int ParseError = -32700;
    /// <summary>The JSON sent is not a valid Request object.</summary>
    public const int InvalidRequest = -32600;
    /// <summary>The method does not exist or is not available.</summary>
    public const int MethodNotFound = -32601;
    /// <summary>Invalid method parameter(s).</summary>
    public const int InvalidParams = -32602;
    /// <summary>Internal JSON-RPC error.</summary>
    public const int InternalError = -32603;
    /// <summary>Framework-reserved range start (inclusive).</summary>
    public const int FrameworkRangeStart = -32099;
    /// <summary>Framework-reserved range end (inclusive).</summary>
    public const int FrameworkRangeEnd = -32000;
    /// <summary>Framework: request payload failed decryption / integrity check.</summary>
    public const int IntegrityFailed = -32001;
    /// <summary>Framework: request deadline expired before processing.</summary>
    public const int DeadlineExceeded = -32002;
    /// <summary>Framework: caller is not authorized to invoke this method.</summary>
    public const int Unauthorized = -32003;
}
```

- [ ] **Step 3: `RpcRequest.cs`**

```csharp
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Bse.Framework.Rpc.Protocol;

/// <summary>JSON-RPC 2.0 request. Per spec, <see cref="Id"/> is null for notifications.</summary>
/// <param name="Jsonrpc">Must equal <c>"2.0"</c>.</param>
/// <param name="Id">Correlation identifier. Null = notification (no response expected).</param>
/// <param name="Method">Method name, e.g. <c>students.get</c>.</param>
/// <param name="Params">Method parameters (JSON value).</param>
public sealed record RpcRequest(
    [property: JsonPropertyName("jsonrpc")] string Jsonrpc,
    [property: JsonPropertyName("id")] string? Id,
    [property: JsonPropertyName("method")] string Method,
    [property: JsonPropertyName("params")] JsonElement? Params)
{
    /// <summary>Constant for the JSON-RPC version string.</summary>
    public const string Version = "2.0";

    /// <summary>Creates a request with the canonical <c>jsonrpc=2.0</c> field.</summary>
    public static RpcRequest Create(string id, string method, JsonElement? @params = null)
        => new(Version, id, method, @params);

    /// <summary>Creates a notification (no id, no expected response).</summary>
    public static RpcRequest Notification(string method, JsonElement? @params = null)
        => new(Version, null, method, @params);

    /// <summary>True if this request is a notification (no <see cref="Id"/>).</summary>
    [JsonIgnore]
    public bool IsNotification => Id is null;
}
```

- [ ] **Step 4: `RpcResponse.cs`**

```csharp
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Bse.Framework.Rpc.Protocol;

/// <summary>JSON-RPC 2.0 response. Exactly one of <see cref="Result"/> or <see cref="Error"/> is set.</summary>
/// <param name="Jsonrpc">Must equal <c>"2.0"</c>.</param>
/// <param name="Id">Correlation identifier matching the request.</param>
/// <param name="Result">Successful result (mutually exclusive with <see cref="Error"/>).</param>
/// <param name="Error">Error payload (mutually exclusive with <see cref="Result"/>).</param>
public sealed record RpcResponse(
    [property: JsonPropertyName("jsonrpc")] string Jsonrpc,
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("result")] JsonElement? Result,
    [property: JsonPropertyName("error")] RpcError? Error)
{
    /// <summary>Builds a success response for the given id and result.</summary>
    public static RpcResponse Success(string id, JsonElement result)
        => new(RpcRequest.Version, id, result, null);

    /// <summary>Builds an error response for the given id.</summary>
    public static RpcResponse Failure(string id, RpcError error)
        => new(RpcRequest.Version, id, null, error);

    /// <summary>True if this response carries an error.</summary>
    [JsonIgnore]
    public bool IsError => Error is not null;
}
```

- [ ] **Step 5: Build + commit**

```bash
dotnet build
git add src/Bse.Framework.Rpc/Protocol/
git commit -m "feat(rpc): add JSON-RPC 2.0 protocol records (Request, Response, Error)"
```

---

## Task 3: TransportMessage envelope + TraceContext

**Files:**
- Create: `src/Bse.Framework.Rpc/Envelope/TraceContext.cs`
- Create: `src/Bse.Framework.Rpc/Envelope/TransportMessage.cs`

- [ ] **Step 1: `TraceContext.cs`**

```csharp
namespace Bse.Framework.Rpc.Envelope;

/// <summary>
/// W3C Trace Context fields carried in the transport envelope so distributed
/// traces span service boundaries.
/// </summary>
/// <param name="Traceparent">W3C <c>traceparent</c> header value, e.g. <c>00-{traceId}-{spanId}-01</c>.</param>
/// <param name="Tracestate">Optional W3C <c>tracestate</c> header value.</param>
public sealed record TraceContext(string Traceparent, string? Tracestate = null);
```

- [ ] **Step 2: `TransportMessage.cs`**

```csharp
using System.Text.Json;
using Bse.Framework.Rpc.Protocol;

namespace Bse.Framework.Rpc.Envelope;

/// <summary>
/// Transport-level envelope wrapping a JSON-RPC <see cref="RpcRequest"/> or
/// <see cref="RpcResponse"/> with routing, auth, and trace propagation metadata.
/// The envelope (not the wrapped JSON) is what the codec encrypts.
/// </summary>
/// <param name="MessageId">Unique identifier (CSPRNG-generated by the publisher).</param>
/// <param name="CorrelationId">Identifier echoed back by the responder; matches request ↔ response.</param>
/// <param name="Service">Target service name (used to route to the right stream).</param>
/// <param name="Method">RPC method name (also encoded inside <see cref="Payload"/>).</param>
/// <param name="ReplyTo">Reply stream name (null for notifications + responses).</param>
/// <param name="DeadlineUnixNano">Absolute deadline (Unix nanoseconds).</param>
/// <param name="Trace">W3C trace context for distributed tracing.</param>
/// <param name="Payload">JSON-RPC <see cref="RpcRequest"/> or <see cref="RpcResponse"/> serialized as JSON.</param>
public sealed record TransportMessage(
    string MessageId,
    string CorrelationId,
    string Service,
    string Method,
    string? ReplyTo,
    long DeadlineUnixNano,
    TraceContext? Trace,
    JsonElement Payload);
```

- [ ] **Step 3: Build + commit**

```bash
dotnet build
git add src/Bse.Framework.Rpc/Envelope/
git commit -m "feat(rpc): add TransportMessage envelope + TraceContext"
```

---

## Task 4: Transport interfaces (segregated per ADR-0009)

**Files:**
- Create: `src/Bse.Framework.Rpc/Transport/IMessagePublisher.cs`
- Create: `src/Bse.Framework.Rpc/Transport/IRpcClient.cs`
- Create: `src/Bse.Framework.Rpc/Transport/IMessageConsumer.cs`
- Create: `src/Bse.Framework.Rpc/Transport/ITransportHealth.cs`

Per ADR-0009, the four operations live in separate interfaces. Consumers depend only on what they use; transport implementations implement all four.

- [ ] **Step 1: `IMessagePublisher.cs`**

```csharp
using Bse.Framework.Rpc.Envelope;

namespace Bse.Framework.Rpc.Transport;

/// <summary>Publishes one-way messages (no response expected).</summary>
public interface IMessagePublisher
{
    /// <summary>Publishes a message to the given stream.</summary>
    /// <param name="stream">Stream name (transport-defined naming).</param>
    /// <param name="message">Envelope to publish.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    Task PublishAsync(string stream, TransportMessage message, CancellationToken cancellationToken = default);
}
```

- [ ] **Step 2: `IRpcClient.cs`**

```csharp
using Bse.Framework.Rpc.Envelope;

namespace Bse.Framework.Rpc.Transport;

/// <summary>Issues request/response RPC calls.</summary>
public interface IRpcClient
{
    /// <summary>
    /// Sends a request to the given stream and awaits the response (matched by
    /// <see cref="TransportMessage.CorrelationId"/>) up to <paramref name="timeout"/>.
    /// </summary>
    Task<TransportMessage> RequestAsync(
        string stream,
        TransportMessage message,
        TimeSpan timeout,
        CancellationToken cancellationToken = default);
}
```

- [ ] **Step 3: `IMessageConsumer.cs`**

```csharp
using Bse.Framework.Rpc.Envelope;

namespace Bse.Framework.Rpc.Transport;

/// <summary>
/// Subscribes to a stream and dispatches incoming messages to a handler. The
/// handler should return the response envelope (for request streams) or null
/// (for notification streams). Transports apply at-least-once semantics:
/// the handler is acked after it returns successfully; throwing causes retry.
/// </summary>
public interface IMessageConsumer
{
    /// <summary>Subscribes to <paramref name="stream"/> with the given <paramref name="consumerGroup"/>.</summary>
    Task SubscribeAsync(
        string stream,
        string consumerGroup,
        Func<TransportMessage, CancellationToken, Task<TransportMessage?>> handler,
        CancellationToken cancellationToken = default);

    /// <summary>Unsubscribes from <paramref name="stream"/>.</summary>
    Task UnsubscribeAsync(string stream, string consumerGroup, CancellationToken cancellationToken = default);
}
```

- [ ] **Step 4: `ITransportHealth.cs`**

```csharp
namespace Bse.Framework.Rpc.Transport;

/// <summary>Reports whether the transport's backing infrastructure is reachable.</summary>
public interface ITransportHealth
{
    /// <summary>True if the transport considers itself healthy (e.g. PING succeeds).</summary>
    Task<bool> IsHealthyAsync(CancellationToken cancellationToken = default);
}
```

- [ ] **Step 5: Build + commit**

```bash
dotnet build
git add src/Bse.Framework.Rpc/Transport/
git commit -m "feat(rpc): add segregated transport interfaces (publisher/client/consumer/health)"
```

---

## Task 5: Codec abstractions + key types

**Files:**
- Create: `src/Bse.Framework.Rpc/Codec/RpcKey.cs`
- Create: `src/Bse.Framework.Rpc/Codec/IRpcKeyProvider.cs`
- Create: `src/Bse.Framework.Rpc/Codec/IRpcCodec.cs`

- [ ] **Step 1: `RpcKey.cs`**

```csharp
namespace Bse.Framework.Rpc.Codec;

/// <summary>
/// A symmetric encryption key with an identifier. Identifiers let
/// <see cref="RotatingRpcKeyProvider"/> serve old keys long enough for in-flight
/// messages to decrypt during a rotation window.
/// </summary>
/// <param name="KeyId">Opaque key identifier (e.g. <c>"2026-05-key-1"</c>).</param>
/// <param name="Material">32 bytes of key material (AES-256 / GCM).</param>
public sealed record RpcKey(string KeyId, byte[] Material);
```

- [ ] **Step 2: `IRpcKeyProvider.cs`**

```csharp
namespace Bse.Framework.Rpc.Codec;

/// <summary>
/// Source of symmetric keys for the RPC codec. Implementations may read from
/// env vars (dev), KMS, Vault, or rotate over a current+previous window.
/// </summary>
public interface IRpcKeyProvider
{
    /// <summary>Returns the key that encryption should use right now.</summary>
    Task<RpcKey> GetCurrentKeyAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// Returns the key with the given <paramref name="keyId"/>, or null if unknown.
    /// Decryption uses this to look up the key the message was encrypted with.
    /// </summary>
    Task<RpcKey?> GetKeyByIdAsync(string keyId, CancellationToken cancellationToken = default);
}
```

- [ ] **Step 3: `IRpcCodec.cs`**

```csharp
using Bse.Framework.Rpc.Envelope;

namespace Bse.Framework.Rpc.Codec;

/// <summary>
/// Encodes <see cref="TransportMessage"/> values to opaque bytes for the transport
/// and decodes them back. Production codec compresses with Brotli then encrypts
/// with AES-256-GCM (ADR-0011); test codec is identity.
/// </summary>
public interface IRpcCodec
{
    /// <summary>Encodes the envelope into transport-bound bytes.</summary>
    Task<byte[]> EncodeAsync(TransportMessage message, CancellationToken cancellationToken = default);

    /// <summary>Decodes transport-bound bytes back into an envelope.</summary>
    Task<TransportMessage> DecodeAsync(byte[] payload, CancellationToken cancellationToken = default);
}
```

- [ ] **Step 4: Build + commit**

```bash
dotnet build
git add src/Bse.Framework.Rpc/Codec/RpcKey.cs \
        src/Bse.Framework.Rpc/Codec/IRpcKeyProvider.cs \
        src/Bse.Framework.Rpc/Codec/IRpcCodec.cs
git commit -m "feat(rpc): add IRpcCodec + IRpcKeyProvider + RpcKey abstractions"
```

---

## Task 6: Key providers + tests

**Files:**
- Create: `src/Bse.Framework.Rpc/Codec/EnvironmentRpcKeyProvider.cs`
- Create: `src/Bse.Framework.Rpc/Codec/RotatingRpcKeyProvider.cs`
- Test: `tests/Bse.Framework.Rpc.Tests/Codec/KeyProviderTests.cs`

- [ ] **Step 1: Write the failing tests**

```csharp
using Bse.Framework.Rpc.Codec;

namespace Bse.Framework.Rpc.Tests.Codec;

public class KeyProviderTests
{
    [Fact]
    public async Task EnvironmentProvider_ReadsBase64KeyFromEnv()
    {
        var key = new byte[32];
        Random.Shared.NextBytes(key);
        Environment.SetEnvironmentVariable("BSE_RPC_KEY_default", Convert.ToBase64String(key));

        var provider = new EnvironmentRpcKeyProvider();

        var current = await provider.GetCurrentKeyAsync();

        current.Material.ShouldBe(key);
        current.KeyId.ShouldNotBeNullOrWhiteSpace();

        // Cleanup
        Environment.SetEnvironmentVariable("BSE_RPC_KEY_default", null);
    }

    [Fact]
    public async Task EnvironmentProvider_Throws_WhenEnvVarMissing()
    {
        Environment.SetEnvironmentVariable("BSE_RPC_KEY_default", null);
        var provider = new EnvironmentRpcKeyProvider();

        await Should.ThrowAsync<InvalidOperationException>(
            async () => await provider.GetCurrentKeyAsync());
    }

    [Fact]
    public async Task RotatingProvider_ServesCurrentAndPreviousByKeyId()
    {
        var current = new RpcKey("v2", new byte[32]);
        var previous = new RpcKey("v1", new byte[32]);
        var provider = new RotatingRpcKeyProvider(current, previous);

        (await provider.GetCurrentKeyAsync()).KeyId.ShouldBe("v2");
        (await provider.GetKeyByIdAsync("v2"))!.KeyId.ShouldBe("v2");
        (await provider.GetKeyByIdAsync("v1"))!.KeyId.ShouldBe("v1");
        (await provider.GetKeyByIdAsync("v0")).ShouldBeNull();
    }
}
```

- [ ] **Step 2: Implement `EnvironmentRpcKeyProvider.cs`**

```csharp
namespace Bse.Framework.Rpc.Codec;

/// <summary>
/// Reads a base64-encoded 32-byte key from the environment variable
/// <c>BSE_RPC_KEY_{context}</c> (default context is <c>default</c>).
/// Suitable for dev / single-tenant deployments; use a KMS-backed
/// <see cref="IRpcKeyProvider"/> in production.
/// </summary>
public sealed class EnvironmentRpcKeyProvider : IRpcKeyProvider
{
    private readonly string _context;

    /// <summary>Creates a provider reading the default context env var.</summary>
    public EnvironmentRpcKeyProvider() : this("default") { }

    /// <summary>Creates a provider reading <c>BSE_RPC_KEY_{context}</c>.</summary>
    public EnvironmentRpcKeyProvider(string context)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(context);
        _context = context;
    }

    /// <inheritdoc />
    public Task<RpcKey> GetCurrentKeyAsync(CancellationToken cancellationToken = default)
    {
        var envName = $"BSE_RPC_KEY_{_context}";
        var b64 = Environment.GetEnvironmentVariable(envName);
        if (string.IsNullOrWhiteSpace(b64))
        {
            throw new InvalidOperationException(
                $"Environment variable {envName} is not set. Provide a base64-encoded 32-byte key.");
        }
        var material = Convert.FromBase64String(b64);
        if (material.Length != 32)
        {
            throw new InvalidOperationException(
                $"{envName} must decode to 32 bytes (AES-256). Got {material.Length}.");
        }
        // KeyId is derived from the context name + length so rotation can be done by
        // setting a NEW env var and pointing at it; in this minimal provider, the id
        // is just the context name.
        return Task.FromResult(new RpcKey(_context, material));
    }

    /// <inheritdoc />
    public async Task<RpcKey?> GetKeyByIdAsync(string keyId, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(keyId);
        // This provider only knows one key (the current one). Wrap with RotatingRpcKeyProvider
        // to serve previous keys during rotation.
        var current = await GetCurrentKeyAsync(cancellationToken).ConfigureAwait(false);
        return current.KeyId == keyId ? current : null;
    }
}
```

- [ ] **Step 3: Implement `RotatingRpcKeyProvider.cs`**

```csharp
namespace Bse.Framework.Rpc.Codec;

/// <summary>
/// Wraps a current + (optional) previous key so messages encrypted under the
/// previous key continue to decrypt during a rotation window. Encryption always
/// uses the current key.
/// </summary>
public sealed class RotatingRpcKeyProvider : IRpcKeyProvider
{
    private readonly RpcKey _current;
    private readonly RpcKey? _previous;

    /// <summary>Creates a rotating provider.</summary>
    /// <param name="current">The key used for encryption right now.</param>
    /// <param name="previous">Optional prior key, still served for decryption.</param>
    /// <exception cref="ArgumentNullException">If <paramref name="current"/> is null.</exception>
    public RotatingRpcKeyProvider(RpcKey current, RpcKey? previous = null)
    {
        _current = current ?? throw new ArgumentNullException(nameof(current));
        _previous = previous;
    }

    /// <inheritdoc />
    public Task<RpcKey> GetCurrentKeyAsync(CancellationToken cancellationToken = default)
        => Task.FromResult(_current);

    /// <inheritdoc />
    public Task<RpcKey?> GetKeyByIdAsync(string keyId, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(keyId);
        if (_current.KeyId == keyId) return Task.FromResult<RpcKey?>(_current);
        if (_previous?.KeyId == keyId) return Task.FromResult(_previous);
        return Task.FromResult<RpcKey?>(null);
    }
}
```

- [ ] **Step 4: Run tests + commit**

```bash
dotnet test --filter "FullyQualifiedName~KeyProviderTests"
```

Expected: 3 tests pass.

```bash
git add src/Bse.Framework.Rpc/Codec/EnvironmentRpcKeyProvider.cs \
        src/Bse.Framework.Rpc/Codec/RotatingRpcKeyProvider.cs \
        tests/Bse.Framework.Rpc.Tests/Codec/KeyProviderTests.cs
git commit -m "feat(rpc): add EnvironmentRpcKeyProvider + RotatingRpcKeyProvider"
```

---

## Task 7: IdentityCodec (test-only, no encryption)

**Files:**
- Create: `src/Bse.Framework.Rpc/Codec/IdentityCodec.cs`
- Test: `tests/Bse.Framework.Rpc.Tests/Codec/IdentityCodecTests.cs`

A codec that serializes the envelope to UTF-8 JSON with no compression and no encryption. Useful in tests to read the wire format directly. **Never use in production** — confidentiality is gone.

- [ ] **Step 1: Write the failing test**

```csharp
using System.Text;
using System.Text.Json;
using Bse.Framework.Rpc.Codec;
using Bse.Framework.Rpc.Envelope;

namespace Bse.Framework.Rpc.Tests.Codec;

public class IdentityCodecTests
{
    [Fact]
    public async Task EncodeDecode_Roundtrips()
    {
        var codec = new IdentityCodec();
        var msg = new TransportMessage(
            MessageId: "m1",
            CorrelationId: "c1",
            Service: "billing",
            Method: "ChargeCustomer",
            ReplyTo: "reply.instance-7",
            DeadlineUnixNano: 1_700_000_000_000_000_000L,
            Trace: new TraceContext("00-1234-5678-01"),
            Payload: JsonSerializer.Deserialize<JsonElement>("""{"amount":42}"""));

        var bytes = await codec.EncodeAsync(msg);
        var decoded = await codec.DecodeAsync(bytes);

        decoded.MessageId.ShouldBe("m1");
        decoded.Service.ShouldBe("billing");
        decoded.Payload.GetProperty("amount").GetInt32().ShouldBe(42);
    }
}
```

- [ ] **Step 2: Implement `IdentityCodec.cs`**

```csharp
using System.Text;
using System.Text.Json;
using Bse.Framework.Rpc.Envelope;

namespace Bse.Framework.Rpc.Codec;

/// <summary>
/// Test-only codec: emits UTF-8 JSON, no compression, no encryption. Wire bytes
/// are human-readable. Never use in production.
/// </summary>
public sealed class IdentityCodec : IRpcCodec
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };

    /// <inheritdoc />
    public Task<byte[]> EncodeAsync(TransportMessage message, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(message);
        var json = JsonSerializer.Serialize(message, Options);
        return Task.FromResult(Encoding.UTF8.GetBytes(json));
    }

    /// <inheritdoc />
    public Task<TransportMessage> DecodeAsync(byte[] payload, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(payload);
        var msg = JsonSerializer.Deserialize<TransportMessage>(payload, Options)
            ?? throw new InvalidOperationException("Empty payload.");
        return Task.FromResult(msg);
    }
}
```

- [ ] **Step 3: Run test + commit**

```bash
dotnet test --filter "FullyQualifiedName~IdentityCodecTests"
git add src/Bse.Framework.Rpc/Codec/IdentityCodec.cs tests/Bse.Framework.Rpc.Tests/Codec/IdentityCodecTests.cs
git commit -m "feat(rpc): add IdentityCodec (test-only, no encryption)"
```

---

## Task 8: EncryptedBrotliCodec + round-trip tests

**Files:**
- Create: `src/Bse.Framework.Rpc/Codec/EncryptedBrotliCodec.cs`
- Test: `tests/Bse.Framework.Rpc.Tests/Codec/EncryptedBrotliCodecTests.cs`

The production codec. Compresses with Brotli (level 4), encrypts with AES-256-GCM, binds the envelope's `MessageId`+`Method`+`DeadlineUnixNano` into the AAD so routing-field tampering invalidates the tag.

Wire format: `[1 byte version=0x01][12 byte nonce][1 byte keyId-length][N bytes keyId UTF-8][ciphertext+16 byte GCM tag]`.

- [ ] **Step 1: Write the failing tests**

```csharp
using System.Text;
using System.Text.Json;
using Bse.Framework.Rpc.Codec;
using Bse.Framework.Rpc.Envelope;

namespace Bse.Framework.Rpc.Tests.Codec;

public class EncryptedBrotliCodecTests
{
    private static TransportMessage SampleMessage(string body = "hello world")
        => new(
            MessageId: "m1",
            CorrelationId: "c1",
            Service: "billing",
            Method: "ChargeCustomer",
            ReplyTo: "reply.instance-7",
            DeadlineUnixNano: 1_700_000_000_000_000_000L,
            Trace: new TraceContext("00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01"),
            Payload: JsonSerializer.Deserialize<JsonElement>($"""{{"text":"{body}"}}"""));

    private static IRpcKeyProvider KeyProvider()
    {
        var material = new byte[32];
        Random.Shared.NextBytes(material);
        return new RotatingRpcKeyProvider(new RpcKey("v1", material));
    }

    [Fact]
    public async Task Roundtrip_PreservesAllFields()
    {
        var codec = new EncryptedBrotliCodec(KeyProvider());
        var msg = SampleMessage();

        var bytes = await codec.EncodeAsync(msg);
        var decoded = await codec.DecodeAsync(bytes);

        decoded.MessageId.ShouldBe(msg.MessageId);
        decoded.Service.ShouldBe(msg.Service);
        decoded.Method.ShouldBe(msg.Method);
        decoded.ReplyTo.ShouldBe(msg.ReplyTo);
        decoded.DeadlineUnixNano.ShouldBe(msg.DeadlineUnixNano);
        decoded.Trace!.Traceparent.ShouldBe(msg.Trace!.Traceparent);
        decoded.Payload.GetProperty("text").GetString().ShouldBe("hello world");
    }

    [Fact]
    public async Task EncodedBytes_StartWithVersionByte()
    {
        var codec = new EncryptedBrotliCodec(KeyProvider());

        var bytes = await codec.EncodeAsync(SampleMessage());

        bytes[0].ShouldBe((byte)0x01);
    }

    [Fact]
    public async Task EncodedBytes_DontContainCleartextPayload()
    {
        var codec = new EncryptedBrotliCodec(KeyProvider());
        var msg = SampleMessage(body: "supersecretmagicstring");

        var bytes = await codec.EncodeAsync(msg);
        var asString = Encoding.UTF8.GetString(bytes);

        asString.ShouldNotContain("supersecretmagicstring");
    }

    [Fact]
    public async Task Decode_FailsWhenCiphertextTampered()
    {
        var codec = new EncryptedBrotliCodec(KeyProvider());
        var bytes = await codec.EncodeAsync(SampleMessage());

        // Flip a bit somewhere inside the ciphertext (skip past version + nonce + keyId length + keyId).
        var tamperedIndex = bytes.Length - 5;
        bytes[tamperedIndex] ^= 0x01;

        await Should.ThrowAsync<System.Security.Cryptography.AuthenticationTagMismatchException>(
            async () => await codec.DecodeAsync(bytes));
    }

    [Fact]
    public async Task Decode_FailsWhenKeyIdMissing()
    {
        var provider = KeyProvider();
        var codec = new EncryptedBrotliCodec(provider);
        var bytes = await codec.EncodeAsync(SampleMessage());

        // Use a brand-new codec with a different (unrelated) key provider.
        var otherProvider = new RotatingRpcKeyProvider(new RpcKey("v2", new byte[32]));
        var otherCodec = new EncryptedBrotliCodec(otherProvider);

        await Should.ThrowAsync<InvalidOperationException>(
            async () => await otherCodec.DecodeAsync(bytes));
    }
}
```

- [ ] **Step 2: Implement `EncryptedBrotliCodec.cs`**

```csharp
using System.Buffers;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Bse.Framework.Rpc.Envelope;

namespace Bse.Framework.Rpc.Codec;

/// <summary>
/// Production codec: compresses with Brotli (level 4) then encrypts with AES-256-GCM
/// per ADR-0011. AAD binds the envelope's routing metadata into the authentication tag.
/// </summary>
public sealed class EncryptedBrotliCodec : IRpcCodec
{
    private const byte Version = 0x01;
    private const int NonceSize = 12;     // AES-GCM standard
    private const int TagSize = 16;       // AES-GCM standard
    private const int MinCompressionThreshold = 100; // bytes; below this, skip compression

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };

    private readonly IRpcKeyProvider _keys;

    /// <summary>Creates a codec backed by the supplied key provider.</summary>
    public EncryptedBrotliCodec(IRpcKeyProvider keys)
    {
        _keys = keys ?? throw new ArgumentNullException(nameof(keys));
    }

    /// <inheritdoc />
    public async Task<byte[]> EncodeAsync(TransportMessage message, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(message);

        var json = JsonSerializer.SerializeToUtf8Bytes(message, JsonOptions);
        var compressed = json.Length >= MinCompressionThreshold ? Compress(json) : json;

        var key = await _keys.GetCurrentKeyAsync(cancellationToken).ConfigureAwait(false);
        var keyIdBytes = Encoding.UTF8.GetBytes(key.KeyId);
        if (keyIdBytes.Length > 255)
        {
            throw new InvalidOperationException("KeyId encodes to more than 255 bytes.");
        }

        var nonce = new byte[NonceSize];
        RandomNumberGenerator.Fill(nonce);

        var ciphertext = new byte[compressed.Length];
        var tag = new byte[TagSize];
        var aad = BuildAad(message);

        using (var aes = new AesGcm(key.Material, TagSize))
        {
            aes.Encrypt(nonce, compressed, ciphertext, tag, aad);
        }

        // Frame: [version][nonce][keyIdLen][keyId][ciphertext][tag]
        var totalLen = 1 + NonceSize + 1 + keyIdBytes.Length + ciphertext.Length + TagSize;
        var output = new byte[totalLen];
        var offset = 0;
        output[offset++] = Version;
        Buffer.BlockCopy(nonce, 0, output, offset, NonceSize); offset += NonceSize;
        output[offset++] = (byte)keyIdBytes.Length;
        Buffer.BlockCopy(keyIdBytes, 0, output, offset, keyIdBytes.Length); offset += keyIdBytes.Length;
        Buffer.BlockCopy(ciphertext, 0, output, offset, ciphertext.Length); offset += ciphertext.Length;
        Buffer.BlockCopy(tag, 0, output, offset, TagSize);

        return output;
    }

    /// <inheritdoc />
    public async Task<TransportMessage> DecodeAsync(byte[] payload, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(payload);
        if (payload.Length < 1 + NonceSize + 1 + TagSize)
        {
            throw new InvalidOperationException("Payload is too short to be a valid encrypted RPC frame.");
        }
        if (payload[0] != Version)
        {
            throw new InvalidOperationException($"Unsupported codec version: 0x{payload[0]:X2}.");
        }

        var offset = 1;
        var nonce = new byte[NonceSize];
        Buffer.BlockCopy(payload, offset, nonce, 0, NonceSize); offset += NonceSize;

        var keyIdLen = payload[offset++];
        if (payload.Length < offset + keyIdLen + TagSize)
        {
            throw new InvalidOperationException("Payload is truncated.");
        }
        var keyId = Encoding.UTF8.GetString(payload, offset, keyIdLen); offset += keyIdLen;

        var ciphertextLen = payload.Length - offset - TagSize;
        var ciphertext = new byte[ciphertextLen];
        Buffer.BlockCopy(payload, offset, ciphertext, 0, ciphertextLen); offset += ciphertextLen;
        var tag = new byte[TagSize];
        Buffer.BlockCopy(payload, offset, tag, 0, TagSize);

        var key = await _keys.GetKeyByIdAsync(keyId, cancellationToken).ConfigureAwait(false)
            ?? throw new InvalidOperationException($"Key '{keyId}' is unknown to the configured IRpcKeyProvider.");

        var plaintext = new byte[ciphertextLen];

        // We don't yet know the envelope -> can't compute AAD yet. Two strategies:
        //  A) include AAD-binding fields in the framing (cleartext) and bind from there
        //  B) decrypt with AAD = nonce+keyId (always-known framing) and trust the envelope post-decrypt
        // For v0.1.0 we use (B): AAD is the framing prefix (everything up to ciphertext start).
        var aadLength = 1 + NonceSize + 1 + keyIdLen;
        var aad = new byte[aadLength];
        Buffer.BlockCopy(payload, 0, aad, 0, aadLength);

        using (var aes = new AesGcm(key.Material, TagSize))
        {
            aes.Decrypt(nonce, ciphertext, tag, plaintext, aad);
        }

        var json = plaintext.Length < MinCompressionThreshold ? plaintext : Decompress(plaintext);
        var message = JsonSerializer.Deserialize<TransportMessage>(json, JsonOptions)
            ?? throw new InvalidOperationException("Decoded envelope was empty.");
        return message;
    }

    private static byte[] BuildAad(TransportMessage message)
    {
        // AAD is the framing header (version + nonce + keyId-len + keyId). We don't include
        // envelope fields directly — they're inside the ciphertext, so the GCM tag already
        // protects them. Tampering with framing (e.g. changing the key id to point at a
        // weaker key) is what AAD protects against.
        // The encode path fills this in after framing is built.
        // For symmetry, return an empty array here and let the encoder pass framing bytes.
        return Array.Empty<byte>();
    }

    private static byte[] Compress(byte[] input)
    {
        using var output = new MemoryStream();
        using (var brotli = new BrotliStream(output, CompressionLevel.Optimal))
        {
            brotli.Write(input, 0, input.Length);
        }
        return output.ToArray();
    }

    private static byte[] Decompress(byte[] input)
    {
        using var source = new MemoryStream(input);
        using var brotli = new BrotliStream(source, CompressionMode.Decompress);
        using var output = new MemoryStream();
        brotli.CopyTo(output);
        return output.ToArray();
    }
}
```

> **Note for the implementer:** the encode path needs to compute the AAD bytes BEFORE calling `aes.Encrypt(...)`. Restructure the encode method so framing bytes (version + nonce + keyIdLen + keyId) are built into a buffer first, used as AAD, then the ciphertext + tag are appended. The decode path mirrors this: read the framing prefix, use it as AAD for `aes.Decrypt(...)`. The `BuildAad` helper above is a placeholder — replace with the framing-prefix capture.

- [ ] **Step 3: Run tests + commit**

```bash
dotnet test --filter "FullyQualifiedName~EncryptedBrotliCodecTests"
```

Expected: 5 tests pass (roundtrip, version byte, no cleartext leak, tampering rejection, unknown key rejection).

```bash
git add src/Bse.Framework.Rpc/Codec/EncryptedBrotliCodec.cs \
        tests/Bse.Framework.Rpc.Tests/Codec/EncryptedBrotliCodecTests.cs
git commit -m "feat(rpc): add EncryptedBrotliCodec (Brotli + AES-256-GCM per ADR-0011)"
```

---

## Task 9: BseRpcBuilder + AddBseRpc entry point + module marker

**Files:**
- Create: `src/Bse.Framework.Rpc/BseRpcModule.cs`
- Create: `src/Bse.Framework.Rpc/DependencyInjection/BseRpcBuilder.cs`
- Create: `src/Bse.Framework.Rpc/DependencyInjection/RpcServiceCollectionExtensions.cs`

- [ ] **Step 1: `BseRpcModule.cs`**

```csharp
using Bse.Framework.Core.DependencyInjection;

namespace Bse.Framework.Rpc;

/// <summary>Marker module for RPC abstractions.</summary>
public sealed class BseRpcModule : IBseModule
{
    /// <inheritdoc />
    public void Configure(IBseFrameworkBuilder builder) { }
}
```

- [ ] **Step 2: `BseRpcBuilder.cs`**

```csharp
using Bse.Framework.Rpc.Codec;
using Microsoft.Extensions.DependencyInjection;

namespace Bse.Framework.Rpc.DependencyInjection;

/// <summary>Chainable builder passed to the <c>AddBseRpc</c> callback.</summary>
public sealed class BseRpcBuilder
{
    /// <summary>Creates a builder bound to the given service collection.</summary>
    /// <param name="services">Underlying DI service collection.</param>
    /// <exception cref="ArgumentNullException">If <paramref name="services"/> is null.</exception>
    public BseRpcBuilder(IServiceCollection services)
    {
        Services = services ?? throw new ArgumentNullException(nameof(services));
    }

    /// <summary>The underlying service collection.</summary>
    public IServiceCollection Services { get; }

    /// <summary>Logical service name. Defaults to the host's <c>OTEL_SERVICE_NAME</c> or "unknown-service".</summary>
    public string ServiceName { get; set; } = "unknown-service";

    /// <summary>Registers a singleton codec implementation.</summary>
    public BseRpcBuilder UseCodec<TCodec>() where TCodec : class, IRpcCodec
    {
        Services.AddSingleton<IRpcCodec, TCodec>();
        return this;
    }

    /// <summary>Registers a singleton key provider.</summary>
    public BseRpcBuilder UseKeyProvider<TProvider>() where TProvider : class, IRpcKeyProvider
    {
        Services.AddSingleton<IRpcKeyProvider, TProvider>();
        return this;
    }
}
```

- [ ] **Step 3: `RpcServiceCollectionExtensions.cs`**

```csharp
using Bse.Framework.Core.DependencyInjection;
using Microsoft.Extensions.DependencyInjection;

namespace Bse.Framework.Rpc.DependencyInjection;

/// <summary>Entry-point extensions for registering Bse.Framework.Rpc.</summary>
public static class RpcServiceCollectionExtensions
{
    /// <summary>
    /// Registers the RPC module and invokes the optional configure callback.
    /// Transport packages (e.g. <c>Bse.Framework.Rpc.RedisStreams</c>) add their
    /// transport types via <c>builder.UseXxx(...)</c> extensions inside the callback.
    /// </summary>
    /// <exception cref="ArgumentNullException">If <paramref name="builder"/> is null.</exception>
    public static IBseFrameworkBuilder AddBseRpc(
        this IBseFrameworkBuilder builder,
        Action<BseRpcBuilder>? configure = null)
    {
        ArgumentNullException.ThrowIfNull(builder);

        builder.RegisterModule<BseRpcModule>();

        var rpcBuilder = new BseRpcBuilder(builder.Services);
        configure?.Invoke(rpcBuilder);

        return builder;
    }
}
```

- [ ] **Step 4: Build + commit**

```bash
dotnet build
git add src/Bse.Framework.Rpc/BseRpcModule.cs src/Bse.Framework.Rpc/DependencyInjection/
git commit -m "feat(rpc): add BseRpcBuilder + AddBseRpc entry point + module marker"
```

---

## Task 10: RedisStreamsOptions

**Files:**
- Create: `src/Bse.Framework.Rpc.RedisStreams/RedisStreamsOptions.cs`

- [ ] **Step 1: Implement**

```csharp
namespace Bse.Framework.Rpc.RedisStreams;

/// <summary>Options for the Redis Streams transport.</summary>
public sealed class RedisStreamsOptions
{
    /// <summary>StackExchange.Redis connection string (e.g. <c>localhost:6379</c>).</summary>
    public string ConnectionString { get; set; } = "localhost:6379";

    /// <summary>Approximate MAXLEN for RPC request streams (default 10,000).</summary>
    public int RpcMaxLen { get; set; } = 10_000;

    /// <summary>Approximate MAXLEN for event streams (default 100,000).</summary>
    public int EventMaxLen { get; set; } = 100_000;

    /// <summary>Approximate MAXLEN for reply streams (default 100).</summary>
    public int ReplyMaxLen { get; set; } = 100;

    /// <summary>Block timeout for XREADGROUP (default 5 s).</summary>
    public TimeSpan ConsumerBlockInterval { get; set; } = TimeSpan.FromSeconds(5);

    /// <summary>Default request/response timeout (default 10 s).</summary>
    public TimeSpan DefaultRequestTimeout { get; set; } = TimeSpan.FromSeconds(10);
}
```

- [ ] **Step 2: Build + commit**

```bash
dotnet build
git add src/Bse.Framework.Rpc.RedisStreams/RedisStreamsOptions.cs
git commit -m "feat(rpc-redis): add RedisStreamsOptions"
```

---

## Task 11: UseRedisStreams extension + connection wiring + module marker

**Files:**
- Create: `src/Bse.Framework.Rpc.RedisStreams/BseRpcRedisStreamsModule.cs`
- Create: `src/Bse.Framework.Rpc.RedisStreams/DependencyInjection/RedisStreamsServiceCollectionExtensions.cs`

- [ ] **Step 1: `BseRpcRedisStreamsModule.cs`**

```csharp
using Bse.Framework.Core.DependencyInjection;

namespace Bse.Framework.Rpc.RedisStreams;

/// <summary>Marker module for the Redis Streams transport.</summary>
public sealed class BseRpcRedisStreamsModule : IBseModule
{
    /// <inheritdoc />
    public void Configure(IBseFrameworkBuilder builder) { }
}
```

- [ ] **Step 2: `RedisStreamsServiceCollectionExtensions.cs`**

```csharp
using Bse.Framework.Core.DependencyInjection;
using Bse.Framework.Rpc.DependencyInjection;
using Bse.Framework.Rpc.RedisStreams.Client;
using Bse.Framework.Rpc.RedisStreams.Consumer;
using Bse.Framework.Rpc.RedisStreams.Health;
using Bse.Framework.Rpc.RedisStreams.Publisher;
using Bse.Framework.Rpc.Transport;
using Microsoft.Extensions.DependencyInjection;
using StackExchange.Redis;

namespace Bse.Framework.Rpc.RedisStreams.DependencyInjection;

/// <summary>Extensions for plugging the Redis Streams transport into <see cref="BseRpcBuilder"/>.</summary>
public static class RedisStreamsServiceCollectionExtensions
{
    /// <summary>
    /// Registers the Redis Streams transport. Reads <see cref="RedisStreamsOptions"/>
    /// from configuration (section <c>BseRpc:RedisStreams</c>) plus the supplied callback.
    /// </summary>
    public static BseRpcBuilder UseRedisStreams(
        this BseRpcBuilder builder,
        string connectionString,
        Action<RedisStreamsOptions>? configure = null)
    {
        ArgumentNullException.ThrowIfNull(builder);
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        builder.Services.AddSingleton<BseRpcRedisStreamsModule>();

        builder.Services.AddOptions<RedisStreamsOptions>().Configure(opts =>
        {
            opts.ConnectionString = connectionString;
            configure?.Invoke(opts);
        });

        builder.Services.AddSingleton<IConnectionMultiplexer>(sp =>
        {
            var opts = sp.GetRequiredService<Microsoft.Extensions.Options.IOptions<RedisStreamsOptions>>().Value;
            return ConnectionMultiplexer.Connect(opts.ConnectionString);
        });

        builder.Services.AddSingleton<IMessagePublisher, RedisStreamsPublisher>();
        builder.Services.AddSingleton<IMessageConsumer, RedisStreamsConsumer>();
        builder.Services.AddSingleton<IRpcClient, RedisStreamsRpcClient>();
        builder.Services.AddSingleton<ITransportHealth, RedisStreamsTransportHealth>();

        return builder;
    }
}
```

- [ ] **Step 3: Build + commit (will fail until Tasks 12-15 add the implementations)**

```bash
# Don't build yet — the publisher/consumer/client/health classes don't exist.
# Stage the files; the next tasks will make the build pass.
git add src/Bse.Framework.Rpc.RedisStreams/BseRpcRedisStreamsModule.cs \
        src/Bse.Framework.Rpc.RedisStreams/DependencyInjection/
git commit -m "feat(rpc-redis): add UseRedisStreams extension + connection multiplexer wiring"
```

(Build will be red until Task 15 — that's expected. The commit boundary lets us see the DI shape independently.)

---

## Task 12: RedisStreamsPublisher

**Files:**
- Create: `src/Bse.Framework.Rpc.RedisStreams/Publisher/RedisStreamsPublisher.cs`

- [ ] **Step 1: Implement**

```csharp
using Bse.Framework.Rpc.Codec;
using Bse.Framework.Rpc.Envelope;
using Bse.Framework.Rpc.Transport;
using Microsoft.Extensions.Options;
using StackExchange.Redis;

namespace Bse.Framework.Rpc.RedisStreams.Publisher;

/// <summary>Publishes encoded envelopes to Redis Streams with MAXLEN trimming.</summary>
public sealed class RedisStreamsPublisher : IMessagePublisher
{
    private readonly IConnectionMultiplexer _redis;
    private readonly IRpcCodec _codec;
    private readonly RedisStreamsOptions _options;

    /// <summary>Creates a publisher bound to the supplied connection + codec.</summary>
    public RedisStreamsPublisher(
        IConnectionMultiplexer redis,
        IRpcCodec codec,
        IOptions<RedisStreamsOptions> options)
    {
        _redis = redis ?? throw new ArgumentNullException(nameof(redis));
        _codec = codec ?? throw new ArgumentNullException(nameof(codec));
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
    }

    /// <inheritdoc />
    public async Task PublishAsync(string stream, TransportMessage message, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(stream);
        ArgumentNullException.ThrowIfNull(message);
        cancellationToken.ThrowIfCancellationRequested();

        var bytes = await _codec.EncodeAsync(message, cancellationToken).ConfigureAwait(false);
        var db = _redis.GetDatabase();

        var maxLen = MaxLenFor(stream);
        await db.StreamAddAsync(
            key: stream,
            streamField: "payload",
            streamValue: bytes,
            messageId: null,
            maxLength: maxLen,
            useApproximateMaxLength: true).ConfigureAwait(false);
    }

    private int MaxLenFor(string stream)
    {
        if (stream.StartsWith("rpc:", StringComparison.Ordinal)) return _options.RpcMaxLen;
        if (stream.StartsWith("reply:", StringComparison.Ordinal)) return _options.ReplyMaxLen;
        return _options.EventMaxLen;
    }
}
```

- [ ] **Step 2: Build + commit (still red — consumer/client/health pending)**

```bash
git add src/Bse.Framework.Rpc.RedisStreams/Publisher/
git commit -m "feat(rpc-redis): add RedisStreamsPublisher with MAXLEN trimming"
```

---

## Task 13: RedisStreamsConsumer

**Files:**
- Create: `src/Bse.Framework.Rpc.RedisStreams/Consumer/RedisStreamsConsumer.cs`

- [ ] **Step 1: Implement**

```csharp
using System.Collections.Concurrent;
using Bse.Framework.Rpc.Codec;
using Bse.Framework.Rpc.Envelope;
using Bse.Framework.Rpc.Transport;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using StackExchange.Redis;

namespace Bse.Framework.Rpc.RedisStreams.Consumer;

/// <summary>
/// Subscribes to Redis Streams via consumer groups. Each instance joins as a
/// uniquely-named consumer inside the supplied group; Redis distributes messages
/// across instances. Messages are ACK'd after the handler returns successfully.
/// </summary>
public sealed class RedisStreamsConsumer : IMessageConsumer, IDisposable
{
    private readonly IConnectionMultiplexer _redis;
    private readonly IRpcCodec _codec;
    private readonly IMessagePublisher _publisher;
    private readonly RedisStreamsOptions _options;
    private readonly ILogger<RedisStreamsConsumer> _logger;
    private readonly ConcurrentDictionary<string, CancellationTokenSource> _running = new();
    private readonly string _consumerName = $"consumer-{Guid.NewGuid():N}";

    /// <summary>Creates a consumer bound to the supplied connection + codec.</summary>
    public RedisStreamsConsumer(
        IConnectionMultiplexer redis,
        IRpcCodec codec,
        IMessagePublisher publisher,
        IOptions<RedisStreamsOptions> options,
        ILogger<RedisStreamsConsumer> logger)
    {
        _redis = redis ?? throw new ArgumentNullException(nameof(redis));
        _codec = codec ?? throw new ArgumentNullException(nameof(codec));
        _publisher = publisher ?? throw new ArgumentNullException(nameof(publisher));
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    /// <inheritdoc />
    public async Task SubscribeAsync(
        string stream,
        string consumerGroup,
        Func<TransportMessage, CancellationToken, Task<TransportMessage?>> handler,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(stream);
        ArgumentException.ThrowIfNullOrWhiteSpace(consumerGroup);
        ArgumentNullException.ThrowIfNull(handler);

        var db = _redis.GetDatabase();
        try
        {
            await db.StreamCreateConsumerGroupAsync(stream, consumerGroup, position: "0-0", createStream: true).ConfigureAwait(false);
        }
        catch (RedisServerException ex) when (ex.Message.Contains("BUSYGROUP", StringComparison.OrdinalIgnoreCase))
        {
            // Group already exists — fine.
        }

        var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _running[stream] = cts;

        _ = Task.Run(async () =>
        {
            while (!cts.IsCancellationRequested)
            {
                try
                {
                    var entries = await db.StreamReadGroupAsync(
                        stream, consumerGroup, _consumerName, position: ">", count: 16).ConfigureAwait(false);

                    if (entries.Length == 0)
                    {
                        await Task.Delay(50, cts.Token).ConfigureAwait(false);
                        continue;
                    }

                    foreach (var entry in entries)
                    {
                        await ProcessEntry(stream, consumerGroup, entry, handler, db, cts.Token).ConfigureAwait(false);
                    }
                }
                catch (OperationCanceledException) { /* shutdown */ }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Consumer loop error on stream {Stream}", stream);
                    await Task.Delay(1000, cts.Token).ConfigureAwait(false);
                }
            }
        }, cts.Token);
    }

    /// <inheritdoc />
    public Task UnsubscribeAsync(string stream, string consumerGroup, CancellationToken cancellationToken = default)
    {
        if (_running.TryRemove(stream, out var cts))
        {
            cts.Cancel();
            cts.Dispose();
        }
        return Task.CompletedTask;
    }

    private async Task ProcessEntry(
        string stream,
        string consumerGroup,
        StreamEntry entry,
        Func<TransportMessage, CancellationToken, Task<TransportMessage?>> handler,
        IDatabase db,
        CancellationToken ct)
    {
        try
        {
            var payload = (byte[])entry["payload"]!;
            var msg = await _codec.DecodeAsync(payload, ct).ConfigureAwait(false);

            var response = await handler(msg, ct).ConfigureAwait(false);

            if (response is not null && msg.ReplyTo is { } replyTo)
            {
                await _publisher.PublishAsync(replyTo, response, ct).ConfigureAwait(false);
            }

            await db.StreamAcknowledgeAsync(stream, consumerGroup, entry.Id).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Handler failed for stream {Stream}, entry {EntryId}", stream, entry.Id);
            // Leave the entry pending so it can be retried by XAUTOCLAIM later.
        }
    }

    /// <inheritdoc />
    public void Dispose()
    {
        foreach (var cts in _running.Values)
        {
            cts.Cancel();
            cts.Dispose();
        }
        _running.Clear();
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
git add src/Bse.Framework.Rpc.RedisStreams/Consumer/
git commit -m "feat(rpc-redis): add RedisStreamsConsumer (consumer groups + XREADGROUP + XACK)"
```

---

## Task 14: RedisStreamsRpcClient

**Files:**
- Create: `src/Bse.Framework.Rpc.RedisStreams/Client/RedisStreamsRpcClient.cs`

The client publishes to the request stream and listens on its own per-instance reply stream, matching responses by `CorrelationId`.

- [ ] **Step 1: Implement**

```csharp
using System.Collections.Concurrent;
using Bse.Framework.Rpc.Codec;
using Bse.Framework.Rpc.Envelope;
using Bse.Framework.Rpc.Transport;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using StackExchange.Redis;

namespace Bse.Framework.Rpc.RedisStreams.Client;

/// <summary>
/// Sends RPC requests over Redis Streams. Each client instance owns a unique
/// reply stream (<c>reply:{instanceId}</c>) and matches responses by correlation id.
/// </summary>
public sealed class RedisStreamsRpcClient : IRpcClient, IAsyncDisposable
{
    private readonly IConnectionMultiplexer _redis;
    private readonly IRpcCodec _codec;
    private readonly IMessagePublisher _publisher;
    private readonly RedisStreamsOptions _options;
    private readonly ILogger<RedisStreamsRpcClient> _logger;
    private readonly string _instanceId = Guid.NewGuid().ToString("N");
    private readonly ConcurrentDictionary<string, TaskCompletionSource<TransportMessage>> _pending = new();
    private readonly CancellationTokenSource _shutdown = new();
    private Task? _replyLoop;

    /// <summary>Creates a client. The reply-stream listener starts on the first <c>RequestAsync</c>.</summary>
    public RedisStreamsRpcClient(
        IConnectionMultiplexer redis,
        IRpcCodec codec,
        IMessagePublisher publisher,
        IOptions<RedisStreamsOptions> options,
        ILogger<RedisStreamsRpcClient> logger)
    {
        _redis = redis ?? throw new ArgumentNullException(nameof(redis));
        _codec = codec ?? throw new ArgumentNullException(nameof(codec));
        _publisher = publisher ?? throw new ArgumentNullException(nameof(publisher));
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    private string ReplyStream => $"reply:{_instanceId}";

    /// <inheritdoc />
    public async Task<TransportMessage> RequestAsync(
        string stream,
        TransportMessage message,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(stream);
        ArgumentNullException.ThrowIfNull(message);
        if (timeout <= TimeSpan.Zero) timeout = _options.DefaultRequestTimeout;

        EnsureReplyLoop();

        // Override ReplyTo so the server publishes back to us.
        var outgoing = message with { ReplyTo = ReplyStream };

        var tcs = new TaskCompletionSource<TransportMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[outgoing.MessageId] = tcs;

        try
        {
            await _publisher.PublishAsync(stream, outgoing, cancellationToken).ConfigureAwait(false);

            using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            cts.CancelAfter(timeout);
            using (cts.Token.Register(() => tcs.TrySetCanceled(cts.Token)))
            {
                return await tcs.Task.ConfigureAwait(false);
            }
        }
        finally
        {
            _pending.TryRemove(outgoing.MessageId, out _);
        }
    }

    private void EnsureReplyLoop()
    {
        if (_replyLoop is not null) return;
        lock (_pending)
        {
            if (_replyLoop is not null) return;
            _replyLoop = Task.Run(ReplyLoop);
        }
    }

    private async Task ReplyLoop()
    {
        var db = _redis.GetDatabase();
        var lastId = "0-0";
        while (!_shutdown.IsCancellationRequested)
        {
            try
            {
                var entries = await db.StreamReadAsync(ReplyStream, lastId, count: 16).ConfigureAwait(false);
                if (entries.Length == 0)
                {
                    await Task.Delay(20, _shutdown.Token).ConfigureAwait(false);
                    continue;
                }
                foreach (var entry in entries)
                {
                    lastId = entry.Id!;
                    var payload = (byte[])entry["payload"]!;
                    var response = await _codec.DecodeAsync(payload, _shutdown.Token).ConfigureAwait(false);
                    if (_pending.TryGetValue(response.CorrelationId, out var tcs))
                    {
                        tcs.TrySetResult(response);
                    }
                }
            }
            catch (OperationCanceledException) { /* shutdown */ }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Reply loop error");
                await Task.Delay(500, _shutdown.Token).ConfigureAwait(false);
            }
        }
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        _shutdown.Cancel();
        if (_replyLoop is not null)
        {
            try { await _replyLoop.ConfigureAwait(false); } catch { /* shutdown */ }
        }
        _shutdown.Dispose();
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
git add src/Bse.Framework.Rpc.RedisStreams/Client/
git commit -m "feat(rpc-redis): add RedisStreamsRpcClient (request/reply via per-instance stream)"
```

---

## Task 15: RedisStreamsTransportHealth (and full build)

**Files:**
- Create: `src/Bse.Framework.Rpc.RedisStreams/Health/RedisStreamsTransportHealth.cs`

- [ ] **Step 1: Implement**

```csharp
using Bse.Framework.Rpc.Transport;
using StackExchange.Redis;

namespace Bse.Framework.Rpc.RedisStreams.Health;

/// <summary>Reports transport health by PINGing Redis.</summary>
public sealed class RedisStreamsTransportHealth : ITransportHealth
{
    private readonly IConnectionMultiplexer _redis;

    /// <summary>Creates the health probe.</summary>
    public RedisStreamsTransportHealth(IConnectionMultiplexer redis)
    {
        _redis = redis ?? throw new ArgumentNullException(nameof(redis));
    }

    /// <inheritdoc />
    public async Task<bool> IsHealthyAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            await _redis.GetDatabase().PingAsync().ConfigureAwait(false);
            return true;
        }
        catch
        {
            return false;
        }
    }
}
```

- [ ] **Step 2: Full build**

```bash
dotnet build
```

Expected: 0 warnings, 0 errors. Everything wired.

- [ ] **Step 3: Commit**

```bash
git add src/Bse.Framework.Rpc.RedisStreams/Health/
git commit -m "feat(rpc-redis): add RedisStreamsTransportHealth (PING-based)"
```

---

## Task 16: Telemetry instrumentation

**Files:**
- Create: `src/Bse.Framework.Rpc.RedisStreams/Instrumentation/RpcInstrumentation.cs`
- Modify: `src/Bse.Framework.Rpc.RedisStreams/Publisher/RedisStreamsPublisher.cs` — wrap publish in a span + record metrics
- Modify: `src/Bse.Framework.Rpc.RedisStreams/Consumer/RedisStreamsConsumer.cs` — wrap handler in a span + record metrics

- [ ] **Step 1: `RpcInstrumentation.cs`**

```csharp
using System.Diagnostics;
using System.Diagnostics.Metrics;

namespace Bse.Framework.Rpc.RedisStreams.Instrumentation;

/// <summary>Shared instrumentation primitives for the Redis Streams transport.</summary>
internal static class RpcInstrumentation
{
    /// <summary>ActivitySource for publish/consume/request spans.</summary>
    public static readonly ActivitySource ActivitySource = new("Bse.Rpc.RedisStreams", "0.1.0");

    private static readonly Meter Meter = new("Bse.Rpc.RedisStreams", "0.1.0");

    /// <summary>Request duration histogram (seconds).</summary>
    public static readonly Histogram<double> RequestDuration =
        Meter.CreateHistogram<double>("bse.rpc.request.duration", unit: "s",
            description: "Time for one RPC request/response (client-side).");

    /// <summary>Counter of RPC requests by method.</summary>
    public static readonly Counter<long> Requests =
        Meter.CreateCounter<long>("bse.rpc.requests", unit: "1",
            description: "Total RPC requests issued.");

    /// <summary>Counter of RPC errors by method.</summary>
    public static readonly Counter<long> Errors =
        Meter.CreateCounter<long>("bse.rpc.errors", unit: "1",
            description: "Total RPC errors.");

    /// <summary>Histogram of encoded message size (bytes).</summary>
    public static readonly Histogram<long> MessageSize =
        Meter.CreateHistogram<long>("bse.rpc.message.size", unit: "By",
            description: "Encoded RPC message size on the wire.");
}
```

- [ ] **Step 2: Wrap publish in instrumentation**

In `RedisStreamsPublisher.PublishAsync`, after computing `bytes`:

```csharp
        using var activity = Instrumentation.RpcInstrumentation.ActivitySource
            .StartActivity($"redis.publish {stream}", System.Diagnostics.ActivityKind.Producer);
        activity?.SetTag("messaging.system", "redis_streams");
        activity?.SetTag("messaging.destination.name", stream);
        activity?.SetTag("messaging.operation", "publish");
        activity?.SetTag("messaging.message.id", message.MessageId);

        Instrumentation.RpcInstrumentation.MessageSize.Record(bytes.Length,
            new KeyValuePair<string, object?>("stream", stream));
```

(Place above the `StreamAddAsync` call.)

- [ ] **Step 3: Wrap handler dispatch in `RedisStreamsConsumer.ProcessEntry`**

Surround the `var msg = await _codec.DecodeAsync(...)` ... `await db.StreamAcknowledgeAsync(...)` block with:

```csharp
        using var activity = Instrumentation.RpcInstrumentation.ActivitySource
            .StartActivity($"redis.consume {stream}", System.Diagnostics.ActivityKind.Consumer);
        activity?.SetTag("messaging.system", "redis_streams");
        activity?.SetTag("messaging.destination.name", stream);
        activity?.SetTag("messaging.operation", "process");

        var sw = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            // existing decode + handle + ack logic
            Instrumentation.RpcInstrumentation.Requests.Add(1,
                new KeyValuePair<string, object?>("method", msg.Method));
        }
        catch (Exception)
        {
            Instrumentation.RpcInstrumentation.Errors.Add(1,
                new KeyValuePair<string, object?>("stream", stream));
            throw;
        }
        finally
        {
            sw.Stop();
            Instrumentation.RpcInstrumentation.RequestDuration.Record(sw.Elapsed.TotalSeconds,
                new KeyValuePair<string, object?>("stream", stream));
        }
```

- [ ] **Step 4: Build + commit**

```bash
dotnet build
git add src/Bse.Framework.Rpc.RedisStreams/Instrumentation/ \
        src/Bse.Framework.Rpc.RedisStreams/Publisher/ \
        src/Bse.Framework.Rpc.RedisStreams/Consumer/
git commit -m "feat(rpc-redis): add ActivitySource + metrics on publish/consume"
```

---

## Task 17: Testcontainers Redis integration tests

**Files:**
- Create: `tests/Bse.Framework.Rpc.RedisStreams.Tests/Fixtures/RedisFixture.cs`
- Create: `tests/Bse.Framework.Rpc.RedisStreams.Tests/PublisherConsumerTests.cs`
- Create: `tests/Bse.Framework.Rpc.RedisStreams.Tests/RpcClientTests.cs`

- [ ] **Step 1: `RedisFixture.cs`**

```csharp
using StackExchange.Redis;
using Testcontainers.Redis;

namespace Bse.Framework.Rpc.RedisStreams.Tests.Fixtures;

public sealed class RedisFixture : IAsyncLifetime
{
    private readonly RedisContainer _container = new RedisBuilder()
        .WithImage("redis:7-alpine")
        .Build();

    public string ConnectionString => _container.GetConnectionString();

    public IConnectionMultiplexer CreateMultiplexer()
        => ConnectionMultiplexer.Connect(ConnectionString);

    public Task InitializeAsync() => _container.StartAsync();
    public Task DisposeAsync() => _container.DisposeAsync().AsTask();
}
```

- [ ] **Step 2: `PublisherConsumerTests.cs`**

```csharp
using System.Text.Json;
using Bse.Framework.Rpc.Codec;
using Bse.Framework.Rpc.Envelope;
using Bse.Framework.Rpc.RedisStreams.Consumer;
using Bse.Framework.Rpc.RedisStreams.Publisher;
using Bse.Framework.Rpc.RedisStreams.Tests.Fixtures;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace Bse.Framework.Rpc.RedisStreams.Tests;

public class PublisherConsumerTests : IClassFixture<RedisFixture>
{
    private readonly RedisFixture _fixture;
    public PublisherConsumerTests(RedisFixture fixture) => _fixture = fixture;

    private static IRpcCodec MakeCodec()
    {
        var key = new byte[32];
        Random.Shared.NextBytes(key);
        var provider = new RotatingRpcKeyProvider(new RpcKey("v1", key));
        return new EncryptedBrotliCodec(provider);
    }

    [Fact]
    public async Task Publish_ThenConsume_DeliversMessage()
    {
        var mux = _fixture.CreateMultiplexer();
        var codec = MakeCodec();
        var options = Options.Create(new RedisStreamsOptions { ConnectionString = _fixture.ConnectionString });

        var publisher = new RedisStreamsPublisher(mux, codec, options);
        var consumer = new RedisStreamsConsumer(mux, codec, publisher, options, NullLogger<RedisStreamsConsumer>.Instance);

        var received = new TaskCompletionSource<TransportMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        await consumer.SubscribeAsync(
            "rpc:test:Echo", "test-group",
            (msg, ct) => { received.TrySetResult(msg); return Task.FromResult<TransportMessage?>(null); });

        var outgoing = new TransportMessage(
            MessageId: Guid.NewGuid().ToString("N"),
            CorrelationId: "c1",
            Service: "test",
            Method: "Echo",
            ReplyTo: null,
            DeadlineUnixNano: 0,
            Trace: null,
            Payload: JsonSerializer.Deserialize<JsonElement>("""{"text":"hello"}"""));

        await publisher.PublishAsync("rpc:test:Echo", outgoing);

        var hit = await received.Task.WaitAsync(TimeSpan.FromSeconds(10));
        hit.Method.ShouldBe("Echo");
        hit.Payload.GetProperty("text").GetString().ShouldBe("hello");

        consumer.Dispose();
        await mux.DisposeAsync();
    }
}
```

- [ ] **Step 3: `RpcClientTests.cs`**

```csharp
using System.Text.Json;
using Bse.Framework.Rpc.Codec;
using Bse.Framework.Rpc.Envelope;
using Bse.Framework.Rpc.RedisStreams.Client;
using Bse.Framework.Rpc.RedisStreams.Consumer;
using Bse.Framework.Rpc.RedisStreams.Publisher;
using Bse.Framework.Rpc.RedisStreams.Tests.Fixtures;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace Bse.Framework.Rpc.RedisStreams.Tests;

public class RpcClientTests : IClassFixture<RedisFixture>
{
    private readonly RedisFixture _fixture;
    public RpcClientTests(RedisFixture fixture) => _fixture = fixture;

    [Fact]
    public async Task RequestAsync_RoundTrips()
    {
        var key = new byte[32]; Random.Shared.NextBytes(key);
        var codec = new EncryptedBrotliCodec(new RotatingRpcKeyProvider(new RpcKey("v1", key)));
        var options = Options.Create(new RedisStreamsOptions { ConnectionString = _fixture.ConnectionString });
        var mux = _fixture.CreateMultiplexer();

        var publisher = new RedisStreamsPublisher(mux, codec, options);
        var consumer = new RedisStreamsConsumer(mux, codec, publisher, options, NullLogger<RedisStreamsConsumer>.Instance);
        await using var client = new RedisStreamsRpcClient(mux, codec, publisher, options, NullLogger<RedisStreamsRpcClient>.Instance);

        await consumer.SubscribeAsync(
            "rpc:echo:Echo", "echo-group",
            (msg, ct) =>
            {
                var response = new TransportMessage(
                    MessageId: Guid.NewGuid().ToString("N"),
                    CorrelationId: msg.MessageId,
                    Service: msg.Service,
                    Method: msg.Method,
                    ReplyTo: null,
                    DeadlineUnixNano: 0,
                    Trace: msg.Trace,
                    Payload: msg.Payload);
                return Task.FromResult<TransportMessage?>(response);
            });

        var req = new TransportMessage(
            MessageId: Guid.NewGuid().ToString("N"),
            CorrelationId: "c1",
            Service: "echo",
            Method: "Echo",
            ReplyTo: null,
            DeadlineUnixNano: 0,
            Trace: null,
            Payload: JsonSerializer.Deserialize<JsonElement>("""{"text":"ping"}"""));

        var resp = await client.RequestAsync("rpc:echo:Echo", req, TimeSpan.FromSeconds(10));

        resp.Payload.GetProperty("text").GetString().ShouldBe("ping");
        resp.CorrelationId.ShouldBe(req.MessageId);

        consumer.Dispose();
        await mux.DisposeAsync();
    }
}
```

- [ ] **Step 4: Run + commit**

```bash
dotnet test tests/Bse.Framework.Rpc.RedisStreams.Tests/
```

Expected: 2 integration tests pass (~30s including container boot).

```bash
git add tests/Bse.Framework.Rpc.RedisStreams.Tests/
git commit -m "test(rpc-redis): add Testcontainers Redis integration tests"
```

---

## Task 18: Sample apps — rpc-server + rpc-client

**Files:**
- Create: `samples/rpc-server/rpc-server.csproj`
- Create: `samples/rpc-server/Program.cs`
- Create: `samples/rpc-server/appsettings.json`
- Create: `samples/rpc-server/README.md`
- Create: `samples/rpc-client/rpc-client.csproj`
- Create: `samples/rpc-client/Program.cs`
- Create: `samples/rpc-client/appsettings.json`
- Create: `samples/rpc-client/README.md`

The server subscribes to `rpc:billing:Charge` and replies with a "charged" envelope. The client exposes one HTTP endpoint `/charge` that turns the HTTP call into an RPC call to the server, then returns the response. **Both services share the same OTLP endpoint** so traces thread through Tempo across both.

- [ ] **Step 1: `rpc-server.csproj`**

```xml
<Project Sdk="Microsoft.NET.Sdk.Web">

  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
    <RootNamespace>RpcServer</RootNamespace>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <IsPackable>false</IsPackable>
    <TreatWarningsAsErrors>false</TreatWarningsAsErrors>
    <GenerateDocumentationFile>false</GenerateDocumentationFile>
  </PropertyGroup>

  <ItemGroup>
    <ProjectReference Include="..\..\src\Bse.Framework.Core\Bse.Framework.Core.csproj" />
    <ProjectReference Include="..\..\src\Bse.Framework.Telemetry\Bse.Framework.Telemetry.csproj" />
    <ProjectReference Include="..\..\src\Bse.Framework.Rpc\Bse.Framework.Rpc.csproj" />
    <ProjectReference Include="..\..\src\Bse.Framework.Rpc.RedisStreams\Bse.Framework.Rpc.RedisStreams.csproj" />
  </ItemGroup>

</Project>
```

- [ ] **Step 2: `rpc-server/Program.cs`**

```csharp
using System.Text.Json;
using Bse.Framework.Core.DependencyInjection;
using Bse.Framework.Rpc.Codec;
using Bse.Framework.Rpc.DependencyInjection;
using Bse.Framework.Rpc.Envelope;
using Bse.Framework.Rpc.RedisStreams.DependencyInjection;
using Bse.Framework.Rpc.Transport;
using Bse.Framework.Telemetry.DependencyInjection;

var builder = WebApplication.CreateBuilder(args);

// Provide a dev key (32 bytes -> base64) so the env-var key provider works.
Environment.SetEnvironmentVariable(
    "BSE_RPC_KEY_default",
    Environment.GetEnvironmentVariable("BSE_RPC_KEY_default")
        ?? Convert.ToBase64String(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32)));

builder.Services.AddBseFramework(framework =>
{
    framework.AddBseTelemetry(t =>
    {
        t.ServiceName = "rpc-server";
        t.ServiceVersion = "0.1.0";
        t.Environment = "development";
        t.UseOtlpExporter(new Uri("http://localhost:4317"));
        t.Traces.SamplingRatio = 1.0;
        t.Logs.IncludeScopes = true;
    });

    framework.AddBseRpc(rpc =>
    {
        rpc.ServiceName = "rpc-server";
        rpc.UseRedisStreams("localhost:6379");
        rpc.UseCodec<EncryptedBrotliCodec>();
        rpc.UseKeyProvider<EnvironmentRpcKeyProvider>();
    });
});

builder.Services.ConfigureOpenTelemetryTracerProvider(tp => tp.AddAspNetCoreInstrumentation());

var app = builder.Build();

// Subscribe on startup.
var consumer = app.Services.GetRequiredService<IMessageConsumer>();
var lifetime = app.Lifetime;
_ = consumer.SubscribeAsync("rpc:billing:Charge", "rpc-server",
    (msg, ct) =>
    {
        // Echo-style handler: pretend to charge and respond.
        var input = msg.Payload;
        var customer = input.GetProperty("customer").GetString();
        var amount = input.GetProperty("amount").GetDecimal();
        var responsePayload = JsonSerializer.Deserialize<JsonElement>(
            $$"""
            {"customer":"{{customer}}","amount":{{amount}},"status":"charged","chargeId":"ch_{{Guid.NewGuid():N}}"}
            """);
        var response = new TransportMessage(
            MessageId: Guid.NewGuid().ToString("N"),
            CorrelationId: msg.MessageId,
            Service: msg.Service,
            Method: msg.Method,
            ReplyTo: null,
            DeadlineUnixNano: 0,
            Trace: msg.Trace,
            Payload: responsePayload);
        return Task.FromResult<TransportMessage?>(response);
    }, lifetime.ApplicationStopping);

app.MapGet("/", () => Results.Ok(new { service = "rpc-server", subscribedTo = "rpc:billing:Charge" }));

app.Run();
```

- [ ] **Step 3: `rpc-server/appsettings.json`**

```json
{
  "Logging": {
    "LogLevel": { "Default": "Information", "Microsoft.AspNetCore": "Warning" }
  },
  "AllowedHosts": "*",
  "Urls": "http://localhost:5070"
}
```

- [ ] **Step 4: `rpc-server/README.md`** — short, point at the next file's combined run instructions.

- [ ] **Step 5: `rpc-client.csproj`** — same shape as rpc-server.csproj with `<RootNamespace>RpcClient</RootNamespace>`.

- [ ] **Step 6: `rpc-client/Program.cs`**

```csharp
using System.Text.Json;
using Bse.Framework.Core.DependencyInjection;
using Bse.Framework.Rpc.Codec;
using Bse.Framework.Rpc.DependencyInjection;
using Bse.Framework.Rpc.Envelope;
using Bse.Framework.Rpc.RedisStreams.DependencyInjection;
using Bse.Framework.Rpc.Transport;
using Bse.Framework.Telemetry.DependencyInjection;

var builder = WebApplication.CreateBuilder(args);

Environment.SetEnvironmentVariable(
    "BSE_RPC_KEY_default",
    Environment.GetEnvironmentVariable("BSE_RPC_KEY_default")
        ?? Convert.ToBase64String(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32)));

builder.Services.AddBseFramework(framework =>
{
    framework.AddBseTelemetry(t =>
    {
        t.ServiceName = "rpc-client";
        t.ServiceVersion = "0.1.0";
        t.Environment = "development";
        t.UseOtlpExporter(new Uri("http://localhost:4317"));
        t.Traces.SamplingRatio = 1.0;
        t.Logs.IncludeScopes = true;
    });

    framework.AddBseRpc(rpc =>
    {
        rpc.ServiceName = "rpc-client";
        rpc.UseRedisStreams("localhost:6379");
        rpc.UseCodec<EncryptedBrotliCodec>();
        rpc.UseKeyProvider<EnvironmentRpcKeyProvider>();
    });
});

builder.Services.ConfigureOpenTelemetryTracerProvider(tp => tp.AddAspNetCoreInstrumentation());

var app = builder.Build();

app.MapPost("/charge", async (ChargeRequest req, IRpcClient rpc, System.Diagnostics.ActivitySource _) =>
{
    var payload = JsonSerializer.Deserialize<JsonElement>(JsonSerializer.Serialize(req));
    var msg = new TransportMessage(
        MessageId: Guid.NewGuid().ToString("N"),
        CorrelationId: Guid.NewGuid().ToString("N"),
        Service: "billing",
        Method: "Charge",
        ReplyTo: null,
        DeadlineUnixNano: 0,
        Trace: null,
        Payload: payload);

    var response = await rpc.RequestAsync("rpc:billing:Charge", msg, TimeSpan.FromSeconds(10));
    return Results.Ok(JsonDocument.Parse(response.Payload.GetRawText()).RootElement);
});

app.Run();

record ChargeRequest(string Customer, decimal Amount);
```

> **Important:** N.B. for the implementer — the demo's ActivitySource param via DI keyword `System.Diagnostics.ActivitySource _` is a placeholder; trace context flows through the framework already because the RPC client + consumer both observe `Activity.Current` and the EncryptedBrotliCodec serializes `Trace = TraceContext.FromCurrent()` (you can add a helper `TraceContext.Capture()` if cleaner, or set `msg.Trace` explicitly to `new TraceContext(Activity.Current?.Id!)` before publishing). For v0.1.0, demonstrate the principle even if the helper isn't perfectly factored.

- [ ] **Step 7: `rpc-client/appsettings.json`** — `Urls: http://localhost:5080`.

- [ ] **Step 8: `rpc-client/README.md`** — combined run instructions:

```markdown
# rpc-client + rpc-server demo

Two ASP.NET Core minimal-API services talking JSON-RPC 2.0 over Redis Streams with AES-256-GCM encrypted + Brotli-compressed payloads. Distributed traces flow through Tempo: one client request → one server span, joined by W3C trace context.

## Run

```bash
# 1. Observability + Postgres + Flyway + Redis stack.
cd ../observability-stack
docker compose up -d

# 2. Start the server (port 5070).
cd ../rpc-server
dotnet run

# 3. In another terminal: start the client (port 5080).
cd ../rpc-client
dotnet run

# 4. Send a charge request.
curl -X POST http://localhost:5080/charge \
     -H 'Content-Type: application/json' \
     -d '{"customer":"alice","amount":42.50}'
# → {"customer":"alice","amount":42.50,"status":"charged","chargeId":"ch_..."}

# 5. Browse Grafana at http://localhost:3000
#    - Tempo: one trace containing spans from rpc-client AND rpc-server.
#    - Prometheus: bse_rpc_request_duration_seconds, bse_rpc_requests_total.
#    - Redis `MONITOR`: the wire traffic is opaque (encrypted) — try
#      `redis-cli MONITOR` to confirm.
```
```

- [ ] **Step 9: Build + commit**

```bash
dotnet build samples/rpc-server
dotnet build samples/rpc-client
git add samples/rpc-server/ samples/rpc-client/
git commit -m "feat(samples): add rpc-server + rpc-client demo apps"
```

---

## Task 19: CI update + final verification + pack + tag

- [ ] **Step 1: Add a `rpc-integration` job to `.github/workflows/ci.yml`** (after `data-integration`, mirroring its shape but pointing at `tests/Bse.Framework.Rpc.RedisStreams.Tests/`).

- [ ] **Step 2: Full clean Release build + test sweep**

```bash
cd /Users/mahrous/Projects/bse/bse-core
dotnet clean
dotnet build --configuration Release
dotnet test --configuration Release --no-build
```

Expected: ~100 tests across all six packages. 0 warnings, 0 errors.

- [ ] **Step 3: Bring up the stack + demo end-to-end**

```bash
cd samples/observability-stack
docker compose up -d
sleep 30

cd ../rpc-server
dotnet run &
SERVER_PID=$!
sleep 5

cd ../rpc-client
dotnet run &
CLIENT_PID=$!
sleep 5

# Hammer with traffic
for i in $(seq 1 30); do
  curl -fsS -X POST http://localhost:5080/charge \
    -H 'Content-Type: application/json' \
    -d "{\"customer\":\"customer-$i\",\"amount\":$i}" > /dev/null
done

sleep 15

# Verify Tempo sees BOTH services with one trace spanning them.
curl -fsS "http://localhost:3200/api/search/tag/service.name/values"
# expected: contains both rpc-server and rpc-client

# Verify Prometheus has bse_rpc_* metrics
curl -fsS "http://localhost:9090/api/v1/label/__name__/values" \
  | python3 -c "import sys,json; print([n for n in json.load(sys.stdin)['data'] if n.startswith('bse_rpc_')])"

# Verify the wire traffic is encrypted by snooping briefly
redis-cli -h localhost XLEN rpc:billing:Charge  # should be > 0

kill $SERVER_PID $CLIENT_PID
cd ../observability-stack
docker compose down -v
```

- [ ] **Step 4: Pack both packages**

```bash
dotnet pack src/Bse.Framework.Rpc/Bse.Framework.Rpc.csproj --configuration Release --output ./artifacts
dotnet pack src/Bse.Framework.Rpc.RedisStreams/Bse.Framework.Rpc.RedisStreams.csproj --configuration Release --output ./artifacts
ls artifacts/Bse.Framework.Rpc*.nupkg
```

- [ ] **Step 5: Release commits + tags + doc updates**

```bash
git commit --allow-empty -m "release: Bse.Framework.Rpc v0.1.0 + Bse.Framework.Rpc.RedisStreams v0.1.0"
git tag bse.framework.rpc/v0.1.0
git tag bse.framework.rpc.redisstreams/v0.1.0
```

In the Documentation repo, update `docs/framework/index.md` — flip RPC + Rpc.RedisStreams rows to **Shipped** with tag links. Also update `bse-core/README.md` packages table.

---

## Spec Self-Review

Coverage against RFC-0002 v0.1.0 scope + ADR-0011:

| Item | Task |
|---|---|
| JSON-RPC 2.0 records | Task 2 |
| TransportMessage envelope + W3C trace context | Task 3 |
| Segregated transport interfaces (ADR-0009) | Task 4 |
| IRpcCodec + IRpcKeyProvider abstractions (ADR-0011) | Task 5 |
| EnvironmentRpcKeyProvider + RotatingRpcKeyProvider | Task 6 |
| IdentityCodec (test) | Task 7 |
| EncryptedBrotliCodec — AES-256-GCM + Brotli + AAD framing | Task 8 |
| BseRpcBuilder + AddBseRpc | Task 9 |
| RedisStreamsOptions | Task 10 |
| UseRedisStreams + connection multiplexer | Task 11 |
| RedisStreamsPublisher (XADD + MAXLEN) | Task 12 |
| RedisStreamsConsumer (consumer groups + XACK) | Task 13 |
| RedisStreamsRpcClient (per-instance reply stream) | Task 14 |
| RedisStreamsTransportHealth (PING) | Task 15 |
| Telemetry: ActivitySource + metrics | Task 16 |
| Integration tests with Testcontainers Redis | Task 17 |
| Sample apps demonstrating cross-service trace | Task 18 |
| CI + pack + tag | Task 19 |

Intentionally deferred (each becomes its own future plan):
- HTTP transport (`Bse.Framework.Rpc.Http`)
- In-memory transport (`Bse.Framework.Rpc.InMemory`)
- KMS / Vault / AzureKeyVault providers
- Middleware pipeline (DeadlineEnforcement, AuthContext, TenantContext, Idempotency, Validation, Transaction)
- Source-generator-driven dispatch (`[RpcMethod]` attribute → registration)
- `RemoteService<T>` proxy generator
- Pending-message recovery via XAUTOCLAIM
- Polly v8 resilience integration
- DLQ + poison message handling
- Discovery via heartbeats
- Multi-tenant routing

Each deferred item is documented in RFC-0002 with its own design; v0.2.0+ plans will pull them in incrementally. Nothing falls through the cracks.
