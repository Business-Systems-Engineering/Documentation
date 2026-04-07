# Bse.Framework.Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the foundation NuGet package `Bse.Framework.Core` that all other framework packages depend on, providing DI extensions, exception types, Result types, time/ID abstractions, logging scope helpers, sensitive data redaction, health check aggregation, graceful shutdown coordination, and Problem Details exception handling.

**Architecture:** A single .NET 8/9 NuGet package with focused subdirectories per concern (Exceptions, Results, DependencyInjection, Time, Identity, Logging, Health, Shutdown, ExceptionHandling). Follows Microsoft.Extensions.* abstractions pattern. TDD throughout — every public type has unit tests written first. Centralized package management via Directory.Packages.props. CI runs tests on every push.

**Tech Stack:**
- .NET 8 (LTS) and .NET 9 (multi-target)
- xUnit v2 for tests
- Shouldly for assertions (MIT-licensed, fluent style)
- NSubstitute for mocking
- Microsoft.Extensions.* (DependencyInjection, Logging, Configuration, Hosting, Diagnostics.HealthChecks)
- Microsoft.AspNetCore.Mvc.Core (for ProblemDetails)
- Centralized package management (Directory.Packages.props)
- GitHub Actions CI

**Repository Layout (after this plan):**
```
bse-framework/
├── .editorconfig
├── .gitignore
├── Directory.Build.props
├── Directory.Packages.props
├── BseFramework.sln
├── nuget.config
├── README.md
├── LICENSE
├── .github/
│   └── workflows/
│       └── ci.yml
├── src/
│   └── Bse.Framework.Core/
│       ├── Bse.Framework.Core.csproj
│       ├── README.md
│       ├── DependencyInjection/
│       │   ├── BseFrameworkBuilder.cs
│       │   ├── IBseFrameworkBuilder.cs
│       │   ├── IBseModule.cs
│       │   └── ServiceCollectionExtensions.cs
│       ├── Exceptions/
│       │   ├── BseException.cs
│       │   ├── BseValidationException.cs
│       │   ├── BseNotFoundException.cs
│       │   ├── BseConfigurationException.cs
│       │   └── BseConcurrencyException.cs
│       ├── Results/
│       │   ├── Error.cs
│       │   ├── Result.cs
│       │   └── ResultT.cs
│       ├── Time/
│       │   ├── ISystemClock.cs
│       │   └── SystemClock.cs
│       ├── Identity/
│       │   ├── IGuidGenerator.cs
│       │   └── SequentialGuidGenerator.cs
│       ├── Logging/
│       │   ├── BseLogScopes.cs
│       │   └── LoggerExtensions.cs
│       ├── Redaction/
│       │   ├── ISensitiveDataRedactor.cs
│       │   ├── DefaultRedactor.cs
│       │   └── RedactionRule.cs
│       ├── Health/
│       │   ├── BseHealthCheckExtensions.cs
│       │   └── HealthEndpointConfiguration.cs
│       ├── Shutdown/
│       │   ├── IGracefulShutdownCoordinator.cs
│       │   ├── IShutdownParticipant.cs
│       │   ├── GracefulShutdownCoordinator.cs
│       │   └── GracefulShutdownOptions.cs
│       └── ExceptionHandling/
│           ├── BseProblemDetailsFactory.cs
│           ├── BseExceptionHandlerMiddleware.cs
│           └── ErrorCodeMappings.cs
└── tests/
    └── Bse.Framework.Core.Tests/
        ├── Bse.Framework.Core.Tests.csproj
        ├── DependencyInjection/
        │   ├── BseFrameworkBuilderTests.cs
        │   └── ServiceCollectionExtensionsTests.cs
        ├── Exceptions/
        │   ├── BseExceptionTests.cs
        │   └── BseValidationExceptionTests.cs
        ├── Results/
        │   ├── ResultTests.cs
        │   └── ResultTTests.cs
        ├── Time/
        │   └── SystemClockTests.cs
        ├── Identity/
        │   └── SequentialGuidGeneratorTests.cs
        ├── Logging/
        │   └── BseLogScopesTests.cs
        ├── Redaction/
        │   └── DefaultRedactorTests.cs
        ├── Health/
        │   └── BseHealthCheckExtensionsTests.cs
        ├── Shutdown/
        │   └── GracefulShutdownCoordinatorTests.cs
        └── ExceptionHandling/
            ├── BseProblemDetailsFactoryTests.cs
            └── BseExceptionHandlerMiddlewareTests.cs
```

---

## Task 1: Create Repository Skeleton

**Files:**
- Create: `/Users/mahrous/Projects/bse-framework/.gitignore`
- Create: `/Users/mahrous/Projects/bse-framework/.editorconfig`
- Create: `/Users/mahrous/Projects/bse-framework/README.md`
- Create: `/Users/mahrous/Projects/bse-framework/LICENSE`
- Create: `/Users/mahrous/Projects/bse-framework/nuget.config`

- [ ] **Step 1: Create the repository directory and initialize git**

```bash
mkdir -p /Users/mahrous/Projects/bse-framework
cd /Users/mahrous/Projects/bse-framework
git init
```

- [ ] **Step 2: Create .gitignore**

Create `/Users/mahrous/Projects/bse-framework/.gitignore`:

```gitignore
# .NET build outputs
bin/
obj/
*.user
*.suo
.vs/
.vscode/
artifacts/

# Test results
TestResults/
coverage/
*.coverage
*.coveragexml

# OS
.DS_Store
Thumbs.db

# IDE
.idea/
*.swp
*.swo

# NuGet
*.nupkg
*.snupkg
packages/
.nuget/

# Secrets
*.pfx
*.snk
secrets.json
appsettings.*.json
!appsettings.json
!appsettings.Development.json
```

- [ ] **Step 3: Create .editorconfig**

Create `/Users/mahrous/Projects/bse-framework/.editorconfig`:

```ini
root = true

[*]
indent_style = space
indent_size = 4
end_of_line = lf
charset = utf-8
trim_trailing_whitespace = true
insert_final_newline = true

[*.{json,yml,yaml,md}]
indent_size = 2

[*.cs]
# C# coding conventions
csharp_style_var_for_built_in_types = true:suggestion
csharp_style_var_when_type_is_apparent = true:suggestion
csharp_style_var_elsewhere = true:suggestion
csharp_new_line_before_open_brace = all
csharp_new_line_before_else = true
csharp_new_line_before_catch = true
csharp_new_line_before_finally = true
csharp_indent_case_contents = true
csharp_indent_switch_labels = true
csharp_space_after_cast = false
csharp_space_after_keywords_in_control_flow_statements = true

# Naming
dotnet_naming_rule.private_fields_underscore.severity = warning
dotnet_naming_rule.private_fields_underscore.symbols = private_fields
dotnet_naming_rule.private_fields_underscore.style = underscore_prefix
dotnet_naming_symbols.private_fields.applicable_kinds = field
dotnet_naming_symbols.private_fields.applicable_accessibilities = private
dotnet_naming_style.underscore_prefix.required_prefix = _
dotnet_naming_style.underscore_prefix.capitalization = camel_case

# Quality rules
dotnet_diagnostic.CA1707.severity = none      # Identifiers should not contain underscores (allowed in tests)
dotnet_diagnostic.CA1062.severity = warning   # Validate arguments
dotnet_diagnostic.CA2007.severity = none      # ConfigureAwait (not needed in app code)
```

- [ ] **Step 4: Create README.md**

Create `/Users/mahrous/Projects/bse-framework/README.md`:

```markdown
# Bse.Framework

A modular .NET 8/9 framework for building distributed multi-tenant web APIs and microservices.

## Documentation

Full design documentation lives at `/Users/mahrous/Projects/bse/Documentation/bse-framework/`.

## Packages

- **Bse.Framework.Core** — DI, configuration, logging, base types, health checks, graceful shutdown
- More packages coming (see design docs)

## Building

```bash
dotnet build
dotnet test
```

## License

See LICENSE file.
```

- [ ] **Step 5: Create LICENSE (MIT)**

Create `/Users/mahrous/Projects/bse-framework/LICENSE`:

```
MIT License

Copyright (c) 2026 BSE

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 6: Create nuget.config**

Create `/Users/mahrous/Projects/bse-framework/nuget.config`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />
  </packageSources>
</configuration>
```

- [ ] **Step 7: Commit**

```bash
cd /Users/mahrous/Projects/bse-framework
git add .
git commit -m "chore: initialize repository with .gitignore, .editorconfig, README, LICENSE"
```

---

## Task 2: Set Up MSBuild Centralized Configuration

**Files:**
- Create: `/Users/mahrous/Projects/bse-framework/Directory.Build.props`
- Create: `/Users/mahrous/Projects/bse-framework/Directory.Packages.props`

- [ ] **Step 1: Create Directory.Build.props**

Create `/Users/mahrous/Projects/bse-framework/Directory.Build.props`:

```xml
<Project>

  <PropertyGroup>
    <TargetFrameworks>net8.0;net9.0</TargetFrameworks>
    <LangVersion>latest</LangVersion>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
    <EnforceCodeStyleInBuild>true</EnforceCodeStyleInBuild>
    <AnalysisLevel>latest-recommended</AnalysisLevel>
    <EnableNETAnalyzers>true</EnableNETAnalyzers>
    <DebugType>portable</DebugType>
    <DebugSymbols>true</DebugSymbols>
    <EmbedUntrackedSources>true</EmbedUntrackedSources>
    <PublishRepositoryUrl>true</PublishRepositoryUrl>
    <IncludeSymbols>true</IncludeSymbols>
    <SymbolPackageFormat>snupkg</SymbolPackageFormat>
  </PropertyGroup>

  <PropertyGroup>
    <Authors>BSE</Authors>
    <Company>BSE</Company>
    <Product>Bse.Framework</Product>
    <Copyright>Copyright (c) 2026 BSE</Copyright>
    <PackageLicenseExpression>MIT</PackageLicenseExpression>
    <PackageProjectUrl>https://github.com/bse/bse-framework</PackageProjectUrl>
    <RepositoryUrl>https://github.com/bse/bse-framework</RepositoryUrl>
    <RepositoryType>git</RepositoryType>
    <Version>0.1.0</Version>
    <AssemblyVersion>0.1.0.0</AssemblyVersion>
    <FileVersion>0.1.0.0</FileVersion>
  </PropertyGroup>

</Project>
```

- [ ] **Step 2: Create Directory.Packages.props**

Create `/Users/mahrous/Projects/bse-framework/Directory.Packages.props`:

```xml
<Project>

  <PropertyGroup>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
    <CentralPackageTransitivePinningEnabled>true</CentralPackageTransitivePinningEnabled>
  </PropertyGroup>

  <ItemGroup Label="Microsoft.Extensions">
    <PackageVersion Include="Microsoft.Extensions.DependencyInjection" Version="9.0.0" />
    <PackageVersion Include="Microsoft.Extensions.DependencyInjection.Abstractions" Version="9.0.0" />
    <PackageVersion Include="Microsoft.Extensions.Logging" Version="9.0.0" />
    <PackageVersion Include="Microsoft.Extensions.Logging.Abstractions" Version="9.0.0" />
    <PackageVersion Include="Microsoft.Extensions.Configuration" Version="9.0.0" />
    <PackageVersion Include="Microsoft.Extensions.Configuration.Abstractions" Version="9.0.0" />
    <PackageVersion Include="Microsoft.Extensions.Configuration.Binder" Version="9.0.0" />
    <PackageVersion Include="Microsoft.Extensions.Options" Version="9.0.0" />
    <PackageVersion Include="Microsoft.Extensions.Options.ConfigurationExtensions" Version="9.0.0" />
    <PackageVersion Include="Microsoft.Extensions.Hosting" Version="9.0.0" />
    <PackageVersion Include="Microsoft.Extensions.Hosting.Abstractions" Version="9.0.0" />
    <PackageVersion Include="Microsoft.Extensions.Diagnostics.HealthChecks" Version="9.0.0" />
    <PackageVersion Include="Microsoft.Extensions.Diagnostics.HealthChecks.Abstractions" Version="9.0.0" />
  </ItemGroup>

  <ItemGroup Label="ASP.NET Core">
    <PackageVersion Include="Microsoft.AspNetCore.Mvc.Core" Version="2.3.0" />
    <PackageVersion Include="Microsoft.AspNetCore.Diagnostics.HealthChecks" Version="2.3.0" />
  </ItemGroup>

  <ItemGroup Label="Source Linking">
    <PackageVersion Include="Microsoft.SourceLink.GitHub" Version="8.0.0" />
  </ItemGroup>

  <ItemGroup Label="Testing">
    <PackageVersion Include="Microsoft.NET.Test.Sdk" Version="17.12.0" />
    <PackageVersion Include="xunit" Version="2.9.2" />
    <PackageVersion Include="xunit.runner.visualstudio" Version="2.8.2" />
    <PackageVersion Include="Shouldly" Version="4.3.0" />
    <PackageVersion Include="NSubstitute" Version="5.3.0" />
    <PackageVersion Include="coverlet.collector" Version="6.0.4" />
  </ItemGroup>

</Project>
```

- [ ] **Step 3: Commit**

```bash
git add Directory.Build.props Directory.Packages.props
git commit -m "build: add centralized MSBuild configuration"
```

---

## Task 3: Create the Solution and Core Project

**Files:**
- Create: `/Users/mahrous/Projects/bse-framework/BseFramework.sln`
- Create: `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Bse.Framework.Core.csproj`
- Create: `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/README.md`

- [ ] **Step 1: Create the solution file**

```bash
cd /Users/mahrous/Projects/bse-framework
dotnet new sln -n BseFramework
```

Verify with: `ls BseFramework.sln` (should exist).

- [ ] **Step 2: Create the Core project**

```bash
mkdir -p src/Bse.Framework.Core
cd src/Bse.Framework.Core
dotnet new classlib -n Bse.Framework.Core --output . --framework net8.0
rm Class1.cs
cd ../..
```

- [ ] **Step 3: Replace the auto-generated csproj with explicit content**

Overwrite `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Bse.Framework.Core.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <RootNamespace>Bse.Framework.Core</RootNamespace>
    <AssemblyName>Bse.Framework.Core</AssemblyName>
    <PackageId>Bse.Framework.Core</PackageId>
    <Description>Foundation package for Bse.Framework: DI, configuration, logging, base types, health checks, graceful shutdown.</Description>
    <PackageTags>bse;framework;core;dependency-injection;health-checks</PackageTags>
    <PackageReadmeFile>README.md</PackageReadmeFile>
    <GenerateDocumentationFile>true</GenerateDocumentationFile>
  </PropertyGroup>

  <ItemGroup>
    <None Include="README.md" Pack="true" PackagePath="\" />
  </ItemGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.Extensions.DependencyInjection.Abstractions" />
    <PackageReference Include="Microsoft.Extensions.Logging.Abstractions" />
    <PackageReference Include="Microsoft.Extensions.Configuration.Abstractions" />
    <PackageReference Include="Microsoft.Extensions.Options" />
    <PackageReference Include="Microsoft.Extensions.Hosting.Abstractions" />
    <PackageReference Include="Microsoft.Extensions.Diagnostics.HealthChecks.Abstractions" />
    <PackageReference Include="Microsoft.Extensions.Diagnostics.HealthChecks" />
    <PackageReference Include="Microsoft.AspNetCore.Mvc.Core" />
    <PackageReference Include="Microsoft.SourceLink.GitHub" PrivateAssets="All" />
  </ItemGroup>

</Project>
```

- [ ] **Step 4: Create the package README**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/README.md`:

```markdown
# Bse.Framework.Core

Foundation package for Bse.Framework. Provides:

- Base exception types (`BseException`, `BseValidationException`, `BseNotFoundException`, `BseConfigurationException`, `BseConcurrencyException`)
- Result types (`Result`, `Result<T>`, `Error`)
- Time abstractions (`ISystemClock`)
- ID generation (`IGuidGenerator`, `SequentialGuidGenerator`)
- DI builder pattern (`BseFrameworkBuilder`, `IBseModule`)
- Logging scope helpers
- Sensitive data redaction
- Health check aggregation
- Graceful shutdown coordination
- Problem Details exception handling middleware

## Installation

```bash
dotnet add package Bse.Framework.Core
```

## Quick Start

```csharp
services.AddBseFramework(framework =>
{
    framework.AddHealthChecks();
    framework.AddGracefulShutdown();
    framework.AddProblemDetailsExceptionHandling();
});

app.UseBseExceptionHandler();
app.MapBseHealthChecks();
```
```

- [ ] **Step 5: Add the project to the solution**

```bash
cd /Users/mahrous/Projects/bse-framework
dotnet sln add src/Bse.Framework.Core/Bse.Framework.Core.csproj
```

- [ ] **Step 6: Build to verify it compiles**

```bash
dotnet build
```

Expected: Build succeeded with 0 errors and 0 warnings.

- [ ] **Step 7: Commit**

```bash
git add BseFramework.sln src/Bse.Framework.Core/
git commit -m "feat(core): scaffold Bse.Framework.Core project"
```

---

## Task 4: Create the Test Project

**Files:**
- Create: `/Users/mahrous/Projects/bse-framework/tests/Bse.Framework.Core.Tests/Bse.Framework.Core.Tests.csproj`

- [ ] **Step 1: Create the test project**

```bash
cd /Users/mahrous/Projects/bse-framework
mkdir -p tests/Bse.Framework.Core.Tests
cd tests/Bse.Framework.Core.Tests
dotnet new xunit -n Bse.Framework.Core.Tests --output . --framework net8.0
rm UnitTest1.cs
cd ../..
```

- [ ] **Step 2: Replace the test csproj**

Overwrite `/Users/mahrous/Projects/bse-framework/tests/Bse.Framework.Core.Tests/Bse.Framework.Core.Tests.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <RootNamespace>Bse.Framework.Core.Tests</RootNamespace>
    <AssemblyName>Bse.Framework.Core.Tests</AssemblyName>
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
    <ProjectReference Include="..\..\src\Bse.Framework.Core\Bse.Framework.Core.csproj" />
  </ItemGroup>

  <ItemGroup>
    <Using Include="Xunit" />
    <Using Include="Shouldly" />
    <Using Include="NSubstitute" />
  </ItemGroup>

</Project>
```

- [ ] **Step 3: Add the test project to the solution**

```bash
cd /Users/mahrous/Projects/bse-framework
dotnet sln add tests/Bse.Framework.Core.Tests/Bse.Framework.Core.Tests.csproj
```

- [ ] **Step 4: Build to verify it compiles**

```bash
dotnet build
```

Expected: Build succeeded with 0 errors and 0 warnings.

- [ ] **Step 5: Run tests to verify the test runner works**

```bash
dotnet test
```

Expected: Test run successful with 0 tests (none defined yet).

- [ ] **Step 6: Commit**

```bash
git add tests/
git commit -m "test(core): scaffold test project"
```

---

## Task 5: BseException Base Class

**Files:**
- Create: `src/Bse.Framework.Core/Exceptions/BseException.cs`
- Test: `tests/Bse.Framework.Core.Tests/Exceptions/BseExceptionTests.cs`

- [ ] **Step 1: Write the failing test**

Create `/Users/mahrous/Projects/bse-framework/tests/Bse.Framework.Core.Tests/Exceptions/BseExceptionTests.cs`:

```csharp
using Bse.Framework.Core.Exceptions;

namespace Bse.Framework.Core.Tests.Exceptions;

public class BseExceptionTests
{
    [Fact]
    public void Constructor_WithMessage_SetsMessage()
    {
        var ex = new TestBseException("something failed");

        ex.Message.ShouldBe("something failed");
    }

    [Fact]
    public void Constructor_WithMessageAndInner_SetsBoth()
    {
        var inner = new InvalidOperationException("inner");
        var ex = new TestBseException("outer", inner);

        ex.Message.ShouldBe("outer");
        ex.InnerException.ShouldBe(inner);
    }

    [Fact]
    public void ErrorCode_WhenNotSet_DefaultsToTypeName()
    {
        var ex = new TestBseException("msg");

        ex.ErrorCode.ShouldBe("TestBseException");
    }

    [Fact]
    public void Data_AllowsSettingArbitraryKeys()
    {
        var ex = new TestBseException("msg");

        ex.WithData("tenantId", "tenant-a")
          .WithData("userId", 42);

        ex.Data["tenantId"].ShouldBe("tenant-a");
        ex.Data["userId"].ShouldBe(42);
    }

    [Fact]
    public void WithData_ReturnsSameInstance_ForChaining()
    {
        var ex = new TestBseException("msg");

        var result = ex.WithData("key", "value");

        result.ShouldBeSameAs(ex);
    }

    private sealed class TestBseException : BseException
    {
        public TestBseException(string message) : base(message) { }
        public TestBseException(string message, Exception inner) : base(message, inner) { }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/mahrous/Projects/bse-framework
dotnet test --filter "FullyQualifiedName~BseExceptionTests"
```

Expected: FAIL — `BseException` type does not exist.

- [ ] **Step 3: Implement BseException**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Exceptions/BseException.cs`:

```csharp
namespace Bse.Framework.Core.Exceptions;

/// <summary>
/// Base class for all framework-defined exceptions.
/// Provides an error code and a fluent way to attach contextual data.
/// </summary>
public abstract class BseException : Exception
{
    protected BseException(string message) : base(message)
    {
    }

    protected BseException(string message, Exception innerException) : base(message, innerException)
    {
    }

    /// <summary>
    /// Stable identifier for this exception type. Defaults to the runtime type name
    /// but can be overridden in derived types.
    /// </summary>
    public virtual string ErrorCode => GetType().Name;

    /// <summary>
    /// Attaches a key/value pair to <see cref="Exception.Data"/> and returns this instance
    /// for fluent chaining.
    /// </summary>
    public BseException WithData(string key, object? value)
    {
        Data[key] = value;
        return this;
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
dotnet test --filter "FullyQualifiedName~BseExceptionTests"
```

Expected: PASS — 5 tests passing.

- [ ] **Step 5: Commit**

```bash
git add src/Bse.Framework.Core/Exceptions/BseException.cs tests/Bse.Framework.Core.Tests/Exceptions/BseExceptionTests.cs
git commit -m "feat(core): add BseException base class"
```

---

## Task 6: Specialized Exception Types

**Files:**
- Create: `src/Bse.Framework.Core/Exceptions/BseValidationException.cs`
- Create: `src/Bse.Framework.Core/Exceptions/BseNotFoundException.cs`
- Create: `src/Bse.Framework.Core/Exceptions/BseConfigurationException.cs`
- Create: `src/Bse.Framework.Core/Exceptions/BseConcurrencyException.cs`
- Test: `tests/Bse.Framework.Core.Tests/Exceptions/BseValidationExceptionTests.cs`

- [ ] **Step 1: Write the failing tests for BseValidationException**

Create `/Users/mahrous/Projects/bse-framework/tests/Bse.Framework.Core.Tests/Exceptions/BseValidationExceptionTests.cs`:

```csharp
using Bse.Framework.Core.Exceptions;

namespace Bse.Framework.Core.Tests.Exceptions;

public class BseValidationExceptionTests
{
    [Fact]
    public void Constructor_WithSingleError_PopulatesErrors()
    {
        var ex = new BseValidationException("Email", "Email is required");

        ex.Errors.ShouldContainKey("Email");
        ex.Errors["Email"].ShouldContain("Email is required");
    }

    [Fact]
    public void Constructor_WithMultipleErrors_PopulatesErrors()
    {
        var errors = new Dictionary<string, string[]>
        {
            ["Email"] = new[] { "required", "must be valid email" },
            ["Age"] = new[] { "must be positive" }
        };

        var ex = new BseValidationException(errors);

        ex.Errors.Count.ShouldBe(2);
        ex.Errors["Email"].Length.ShouldBe(2);
        ex.Errors["Age"].Length.ShouldBe(1);
    }

    [Fact]
    public void ErrorCode_IsValidationError()
    {
        var ex = new BseValidationException("Field", "Error");

        ex.ErrorCode.ShouldBe("ValidationError");
    }

    [Fact]
    public void Message_IncludesAllFieldNames()
    {
        var errors = new Dictionary<string, string[]>
        {
            ["Email"] = new[] { "required" },
            ["Age"] = new[] { "invalid" }
        };

        var ex = new BseValidationException(errors);

        ex.Message.ShouldContain("Email");
        ex.Message.ShouldContain("Age");
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
dotnet test --filter "FullyQualifiedName~BseValidationExceptionTests"
```

Expected: FAIL — `BseValidationException` does not exist.

- [ ] **Step 3: Implement BseValidationException**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Exceptions/BseValidationException.cs`:

```csharp
using System.Collections.ObjectModel;

namespace Bse.Framework.Core.Exceptions;

/// <summary>
/// Thrown when input validation fails. Carries a per-field collection of error messages.
/// </summary>
public sealed class BseValidationException : BseException
{
    public BseValidationException(string field, string error)
        : this(new Dictionary<string, string[]> { [field] = new[] { error } })
    {
    }

    public BseValidationException(IDictionary<string, string[]> errors)
        : base(BuildMessage(errors))
    {
        Errors = new ReadOnlyDictionary<string, string[]>(
            errors.ToDictionary(kvp => kvp.Key, kvp => kvp.Value));
    }

    public IReadOnlyDictionary<string, string[]> Errors { get; }

    public override string ErrorCode => "ValidationError";

    private static string BuildMessage(IDictionary<string, string[]> errors)
    {
        var fieldNames = string.Join(", ", errors.Keys);
        return $"Validation failed for: {fieldNames}";
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

```bash
dotnet test --filter "FullyQualifiedName~BseValidationExceptionTests"
```

Expected: PASS — 4 tests passing.

- [ ] **Step 5: Implement BseNotFoundException**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Exceptions/BseNotFoundException.cs`:

```csharp
namespace Bse.Framework.Core.Exceptions;

/// <summary>
/// Thrown when an entity or resource cannot be found.
/// Carries the entity type name and identifier for diagnostics.
/// </summary>
public sealed class BseNotFoundException : BseException
{
    public BseNotFoundException(string entityType, object id)
        : base($"{entityType} with id '{id}' was not found")
    {
        EntityType = entityType;
        Id = id;
    }

    public string EntityType { get; }
    public object Id { get; }

    public override string ErrorCode => "NotFound";
}
```

- [ ] **Step 6: Implement BseConfigurationException**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Exceptions/BseConfigurationException.cs`:

```csharp
namespace Bse.Framework.Core.Exceptions;

/// <summary>
/// Thrown when framework configuration is invalid or incomplete.
/// Detected at startup; surfaces as a fail-fast error.
/// </summary>
public sealed class BseConfigurationException : BseException
{
    public BseConfigurationException(string message) : base(message) { }
    public BseConfigurationException(string message, Exception innerException)
        : base(message, innerException) { }

    public override string ErrorCode => "ConfigurationError";
}
```

- [ ] **Step 7: Implement BseConcurrencyException**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Exceptions/BseConcurrencyException.cs`:

```csharp
namespace Bse.Framework.Core.Exceptions;

/// <summary>
/// Thrown when an optimistic concurrency conflict is detected during a write.
/// </summary>
public sealed class BseConcurrencyException : BseException
{
    public BseConcurrencyException(string entityType, object id)
        : base($"Concurrency conflict for {entityType} '{id}'")
    {
        EntityType = entityType;
        Id = id;
    }

    public BseConcurrencyException(string entityType, object id, Exception innerException)
        : base($"Concurrency conflict for {entityType} '{id}'", innerException)
    {
        EntityType = entityType;
        Id = id;
    }

    public string EntityType { get; }
    public object Id { get; }

    public override string ErrorCode => "ConcurrencyConflict";
}
```

- [ ] **Step 8: Build and run all tests**

```bash
dotnet build
dotnet test
```

Expected: All tests pass.

- [ ] **Step 9: Commit**

```bash
git add src/Bse.Framework.Core/Exceptions/ tests/Bse.Framework.Core.Tests/Exceptions/
git commit -m "feat(core): add specialized exception types"
```

---

## Task 7: Error Record (for Result Types)

**Files:**
- Create: `src/Bse.Framework.Core/Results/Error.cs`

- [ ] **Step 1: Create Error record**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Results/Error.cs`:

```csharp
namespace Bse.Framework.Core.Results;

/// <summary>
/// Represents a domain error with a stable code, human-readable message,
/// and optional structured metadata.
/// </summary>
public sealed record Error(string Code, string Message, IReadOnlyDictionary<string, object>? Metadata = null)
{
    /// <summary>Sentinel value representing the absence of an error.</summary>
    public static readonly Error None = new(string.Empty, string.Empty);

    public bool IsNone => Code == string.Empty;
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
dotnet build
```

Expected: Build succeeded.

- [ ] **Step 3: Commit**

```bash
git add src/Bse.Framework.Core/Results/Error.cs
git commit -m "feat(core): add Error record for Result types"
```

---

## Task 8: Result Type (Non-Generic)

**Files:**
- Create: `src/Bse.Framework.Core/Results/Result.cs`
- Test: `tests/Bse.Framework.Core.Tests/Results/ResultTests.cs`

- [ ] **Step 1: Write the failing tests**

Create `/Users/mahrous/Projects/bse-framework/tests/Bse.Framework.Core.Tests/Results/ResultTests.cs`:

```csharp
using Bse.Framework.Core.Results;

namespace Bse.Framework.Core.Tests.Results;

public class ResultTests
{
    [Fact]
    public void Success_CreatesSuccessfulResult()
    {
        var result = Result.Success();

        result.IsSuccess.ShouldBeTrue();
        result.IsFailure.ShouldBeFalse();
        result.Error.ShouldBe(Error.None);
    }

    [Fact]
    public void Failure_CreatesFailedResult()
    {
        var error = new Error("Auth.Forbidden", "Access denied");

        var result = Result.Failure(error);

        result.IsSuccess.ShouldBeFalse();
        result.IsFailure.ShouldBeTrue();
        result.Error.ShouldBe(error);
    }

    [Fact]
    public void Failure_WithCodeAndMessage_CreatesFailedResult()
    {
        var result = Result.Failure("Auth.Forbidden", "Access denied");

        result.IsFailure.ShouldBeTrue();
        result.Error.Code.ShouldBe("Auth.Forbidden");
        result.Error.Message.ShouldBe("Access denied");
    }

    [Fact]
    public void Success_CannotHaveError()
    {
        Should.Throw<ArgumentException>(() => new Result(true, new Error("X", "Y")));
    }

    [Fact]
    public void Failure_MustHaveError()
    {
        Should.Throw<ArgumentException>(() => new Result(false, Error.None));
    }
}
```

- [ ] **Step 2: Run the tests to verify failure**

```bash
dotnet test --filter "FullyQualifiedName~ResultTests"
```

Expected: FAIL — `Result` type does not exist.

- [ ] **Step 3: Implement Result**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Results/Result.cs`:

```csharp
namespace Bse.Framework.Core.Results;

/// <summary>
/// Represents the outcome of an operation that may succeed or fail with an <see cref="Error"/>.
/// Use <see cref="Result{T}"/> when the success path produces a value.
/// </summary>
public class Result
{
    public Result(bool isSuccess, Error error)
    {
        if (isSuccess && !error.IsNone)
        {
            throw new ArgumentException("A successful result cannot carry an error.", nameof(error));
        }

        if (!isSuccess && error.IsNone)
        {
            throw new ArgumentException("A failed result must carry an error.", nameof(error));
        }

        IsSuccess = isSuccess;
        Error = error;
    }

    public bool IsSuccess { get; }
    public bool IsFailure => !IsSuccess;
    public Error Error { get; }

    public static Result Success() => new(true, Error.None);
    public static Result Failure(Error error) => new(false, error);
    public static Result Failure(string code, string message) => new(false, new Error(code, message));
}
```

- [ ] **Step 4: Run the tests to verify pass**

```bash
dotnet test --filter "FullyQualifiedName~ResultTests"
```

Expected: PASS — 5 tests passing.

- [ ] **Step 5: Commit**

```bash
git add src/Bse.Framework.Core/Results/Result.cs tests/Bse.Framework.Core.Tests/Results/ResultTests.cs
git commit -m "feat(core): add non-generic Result type"
```

---

## Task 9: Generic Result<T> Type

**Files:**
- Create: `src/Bse.Framework.Core/Results/ResultT.cs`
- Test: `tests/Bse.Framework.Core.Tests/Results/ResultTTests.cs`

- [ ] **Step 1: Write the failing tests**

Create `/Users/mahrous/Projects/bse-framework/tests/Bse.Framework.Core.Tests/Results/ResultTTests.cs`:

```csharp
using Bse.Framework.Core.Results;

namespace Bse.Framework.Core.Tests.Results;

public class ResultTTests
{
    [Fact]
    public void Success_StoresValue()
    {
        var result = Result<int>.Success(42);

        result.IsSuccess.ShouldBeTrue();
        result.Value.ShouldBe(42);
    }

    [Fact]
    public void Failure_AccessingValue_Throws()
    {
        var result = Result<int>.Failure(new Error("X", "Y"));

        Should.Throw<InvalidOperationException>(() => _ = result.Value);
    }

    [Fact]
    public void ImplicitConversion_FromValue_CreatesSuccess()
    {
        Result<string> result = "hello";

        result.IsSuccess.ShouldBeTrue();
        result.Value.ShouldBe("hello");
    }

    [Fact]
    public void ImplicitConversion_FromError_CreatesFailure()
    {
        Result<string> result = new Error("X", "Y");

        result.IsFailure.ShouldBeTrue();
        result.Error.Code.ShouldBe("X");
    }

    [Fact]
    public void Map_OnSuccess_TransformsValue()
    {
        var result = Result<int>.Success(2);

        var mapped = result.Map(x => x * 10);

        mapped.IsSuccess.ShouldBeTrue();
        mapped.Value.ShouldBe(20);
    }

    [Fact]
    public void Map_OnFailure_PropagatesError()
    {
        var error = new Error("X", "Y");
        var result = Result<int>.Failure(error);

        var mapped = result.Map(x => x * 10);

        mapped.IsFailure.ShouldBeTrue();
        mapped.Error.ShouldBe(error);
    }
}
```

- [ ] **Step 2: Run the tests to verify failure**

```bash
dotnet test --filter "FullyQualifiedName~ResultTTests"
```

Expected: FAIL — `Result<T>` does not exist.

- [ ] **Step 3: Implement Result<T>**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Results/ResultT.cs`:

```csharp
namespace Bse.Framework.Core.Results;

/// <summary>
/// Represents the outcome of an operation that yields a <typeparamref name="T"/> on success
/// or an <see cref="Error"/> on failure. Supports implicit conversion from values and errors.
/// </summary>
public sealed class Result<T> : Result
{
    private readonly T? _value;

    public Result(T value) : base(true, Error.None)
    {
        _value = value;
    }

    public Result(Error error) : base(false, error)
    {
        _value = default;
    }

    public T Value
    {
        get
        {
            if (IsFailure)
            {
                throw new InvalidOperationException(
                    $"Cannot access Value on a failed result. Error: {Error.Code} - {Error.Message}");
            }
            return _value!;
        }
    }

    public static Result<T> Success(T value) => new(value);
    public static new Result<T> Failure(Error error) => new(error);

    public static implicit operator Result<T>(T value) => new(value);
    public static implicit operator Result<T>(Error error) => new(error);

    public Result<TOut> Map<TOut>(Func<T, TOut> mapper)
    {
        return IsSuccess ? Result<TOut>.Success(mapper(Value)) : Result<TOut>.Failure(Error);
    }
}
```

- [ ] **Step 4: Run the tests to verify pass**

```bash
dotnet test --filter "FullyQualifiedName~ResultTTests"
```

Expected: PASS — 6 tests passing.

- [ ] **Step 5: Commit**

```bash
git add src/Bse.Framework.Core/Results/ResultT.cs tests/Bse.Framework.Core.Tests/Results/ResultTTests.cs
git commit -m "feat(core): add generic Result<T> with map operator"
```

---

## Task 10: ISystemClock Abstraction

**Files:**
- Create: `src/Bse.Framework.Core/Time/ISystemClock.cs`
- Create: `src/Bse.Framework.Core/Time/SystemClock.cs`
- Test: `tests/Bse.Framework.Core.Tests/Time/SystemClockTests.cs`

- [ ] **Step 1: Write the failing tests**

Create `/Users/mahrous/Projects/bse-framework/tests/Bse.Framework.Core.Tests/Time/SystemClockTests.cs`:

```csharp
using Bse.Framework.Core.Time;

namespace Bse.Framework.Core.Tests.Time;

public class SystemClockTests
{
    [Fact]
    public void UtcNow_ReturnsUtcDateTime()
    {
        var clock = new SystemClock();

        var now = clock.UtcNow;

        now.Kind.ShouldBe(DateTimeKind.Utc);
        now.ShouldBeGreaterThan(DateTime.UtcNow.AddSeconds(-1));
        now.ShouldBeLessThan(DateTime.UtcNow.AddSeconds(1));
    }

    [Fact]
    public void UtcNowOffset_ReturnsDateTimeOffset()
    {
        var clock = new SystemClock();

        var now = clock.UtcNowOffset;

        now.Offset.ShouldBe(TimeSpan.Zero);
    }
}
```

- [ ] **Step 2: Run the tests to verify failure**

```bash
dotnet test --filter "FullyQualifiedName~SystemClockTests"
```

Expected: FAIL — `SystemClock` does not exist.

- [ ] **Step 3: Implement ISystemClock**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Time/ISystemClock.cs`:

```csharp
namespace Bse.Framework.Core.Time;

/// <summary>
/// Abstraction over the system clock for testability.
/// Inject this instead of calling <see cref="DateTime.UtcNow"/> directly.
/// </summary>
public interface ISystemClock
{
    /// <summary>Current UTC time as a <see cref="DateTime"/> with <see cref="DateTimeKind.Utc"/>.</summary>
    DateTime UtcNow { get; }

    /// <summary>Current UTC time as a <see cref="DateTimeOffset"/> with zero offset.</summary>
    DateTimeOffset UtcNowOffset { get; }
}
```

- [ ] **Step 4: Implement SystemClock**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Time/SystemClock.cs`:

```csharp
namespace Bse.Framework.Core.Time;

/// <summary>Default implementation backed by <see cref="DateTime.UtcNow"/>.</summary>
public sealed class SystemClock : ISystemClock
{
    public DateTime UtcNow => DateTime.UtcNow;
    public DateTimeOffset UtcNowOffset => DateTimeOffset.UtcNow;
}
```

- [ ] **Step 5: Run the tests to verify pass**

```bash
dotnet test --filter "FullyQualifiedName~SystemClockTests"
```

Expected: PASS — 2 tests passing.

- [ ] **Step 6: Commit**

```bash
git add src/Bse.Framework.Core/Time/ tests/Bse.Framework.Core.Tests/Time/
git commit -m "feat(core): add ISystemClock and SystemClock"
```

---

## Task 11: SequentialGuidGenerator

**Files:**
- Create: `src/Bse.Framework.Core/Identity/IGuidGenerator.cs`
- Create: `src/Bse.Framework.Core/Identity/SequentialGuidGenerator.cs`
- Test: `tests/Bse.Framework.Core.Tests/Identity/SequentialGuidGeneratorTests.cs`

**Why sequential GUIDs:** Random GUIDs as primary keys cause B-tree page splits in SQL Server (worst-case insert performance). Sequential GUIDs (NEWSEQUENTIALID-style) are sortable in time order, making them friendly to clustered indexes while preserving uniqueness.

- [ ] **Step 1: Write the failing tests**

Create `/Users/mahrous/Projects/bse-framework/tests/Bse.Framework.Core.Tests/Identity/SequentialGuidGeneratorTests.cs`:

```csharp
using Bse.Framework.Core.Identity;

namespace Bse.Framework.Core.Tests.Identity;

public class SequentialGuidGeneratorTests
{
    [Fact]
    public void Create_ReturnsNonEmptyGuid()
    {
        var generator = new SequentialGuidGenerator();

        var id = generator.Create();

        id.ShouldNotBe(Guid.Empty);
    }

    [Fact]
    public void Create_GeneratesUniqueValues()
    {
        var generator = new SequentialGuidGenerator();
        var ids = new HashSet<Guid>();

        for (var i = 0; i < 1000; i++)
        {
            ids.Add(generator.Create());
        }

        ids.Count.ShouldBe(1000);
    }

    [Fact]
    public void Create_ProducesSortableValues()
    {
        // Sequential GUIDs should be roughly time-ordered.
        var generator = new SequentialGuidGenerator();
        var first = generator.Create();
        Thread.Sleep(2);
        var second = generator.Create();

        // The string comparison reflects that the time portion comes first.
        var ordered = new[] { first, second }.OrderBy(g => g).ToArray();
        ordered[0].ShouldBe(first);
    }
}
```

- [ ] **Step 2: Run the tests to verify failure**

```bash
dotnet test --filter "FullyQualifiedName~SequentialGuidGeneratorTests"
```

Expected: FAIL — `SequentialGuidGenerator` does not exist.

- [ ] **Step 3: Implement IGuidGenerator**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Identity/IGuidGenerator.cs`:

```csharp
namespace Bse.Framework.Core.Identity;

/// <summary>
/// Generates GUIDs. Inject this instead of calling <see cref="Guid.NewGuid"/> directly
/// so production code can use sequential GUIDs (B-tree friendly) while tests can use
/// deterministic generators.
/// </summary>
public interface IGuidGenerator
{
    Guid Create();
}
```

- [ ] **Step 4: Implement SequentialGuidGenerator**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Identity/SequentialGuidGenerator.cs`:

```csharp
using System.Security.Cryptography;

namespace Bse.Framework.Core.Identity;

/// <summary>
/// Produces time-ordered GUIDs whose first 8 bytes are derived from the current UTC timestamp.
/// Equivalent to SQL Server's NEWSEQUENTIALID() ordering, suitable for use as a clustered primary key.
/// Thread-safe.
/// </summary>
public sealed class SequentialGuidGenerator : IGuidGenerator
{
    public Guid Create()
    {
        var randomBytes = new byte[10];
        RandomNumberGenerator.Fill(randomBytes);

        var timestamp = DateTime.UtcNow.Ticks / 10_000L; // milliseconds
        var timestampBytes = BitConverter.GetBytes(timestamp);

        if (BitConverter.IsLittleEndian)
        {
            Array.Reverse(timestampBytes);
        }

        var guidBytes = new byte[16];
        // First 6 bytes: timestamp (high to low)
        Buffer.BlockCopy(timestampBytes, 2, guidBytes, 0, 6);
        // Remaining 10 bytes: random
        Buffer.BlockCopy(randomBytes, 0, guidBytes, 6, 10);

        return new Guid(guidBytes);
    }
}
```

- [ ] **Step 5: Run the tests to verify pass**

```bash
dotnet test --filter "FullyQualifiedName~SequentialGuidGeneratorTests"
```

Expected: PASS — 3 tests passing.

- [ ] **Step 6: Commit**

```bash
git add src/Bse.Framework.Core/Identity/ tests/Bse.Framework.Core.Tests/Identity/
git commit -m "feat(core): add SequentialGuidGenerator for B-tree friendly IDs"
```

---

## Task 12: BseFrameworkBuilder Pattern

**Files:**
- Create: `src/Bse.Framework.Core/DependencyInjection/IBseFrameworkBuilder.cs`
- Create: `src/Bse.Framework.Core/DependencyInjection/BseFrameworkBuilder.cs`
- Create: `src/Bse.Framework.Core/DependencyInjection/IBseModule.cs`
- Test: `tests/Bse.Framework.Core.Tests/DependencyInjection/BseFrameworkBuilderTests.cs`

**Why a builder:** Each framework package adds itself via `framework.AddXxx()` extension methods. The builder owns the underlying `IServiceCollection` and tracks which modules have been added so dependencies can be resolved at registration time.

- [ ] **Step 1: Write the failing tests**

Create `/Users/mahrous/Projects/bse-framework/tests/Bse.Framework.Core.Tests/DependencyInjection/BseFrameworkBuilderTests.cs`:

```csharp
using Bse.Framework.Core.DependencyInjection;
using Microsoft.Extensions.DependencyInjection;

namespace Bse.Framework.Core.Tests.DependencyInjection;

public class BseFrameworkBuilderTests
{
    [Fact]
    public void Constructor_StoresServiceCollection()
    {
        var services = new ServiceCollection();

        var builder = new BseFrameworkBuilder(services);

        builder.Services.ShouldBe(services);
    }

    [Fact]
    public void HasModule_ReturnsFalse_WhenModuleNotAdded()
    {
        var builder = new BseFrameworkBuilder(new ServiceCollection());

        builder.HasModule<TestModule>().ShouldBeFalse();
    }

    [Fact]
    public void RegisterModule_TracksModule()
    {
        var builder = new BseFrameworkBuilder(new ServiceCollection());

        builder.RegisterModule<TestModule>();

        builder.HasModule<TestModule>().ShouldBeTrue();
    }

    [Fact]
    public void RegisterModule_CanBeCalledMultipleTimes_ButOnlyTracksOnce()
    {
        var builder = new BseFrameworkBuilder(new ServiceCollection());

        builder.RegisterModule<TestModule>();
        builder.RegisterModule<TestModule>();

        builder.HasModule<TestModule>().ShouldBeTrue();
    }

    private sealed class TestModule : IBseModule
    {
        public void Configure(IBseFrameworkBuilder builder) { }
    }
}
```

- [ ] **Step 2: Run the tests to verify failure**

```bash
dotnet test --filter "FullyQualifiedName~BseFrameworkBuilderTests"
```

Expected: FAIL — types do not exist.

- [ ] **Step 3: Implement IBseFrameworkBuilder**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/DependencyInjection/IBseFrameworkBuilder.cs`:

```csharp
using Microsoft.Extensions.DependencyInjection;

namespace Bse.Framework.Core.DependencyInjection;

/// <summary>
/// Builder used to compose framework features into an <see cref="IServiceCollection"/>.
/// Framework packages add themselves via extension methods on this interface.
/// </summary>
public interface IBseFrameworkBuilder
{
    /// <summary>The underlying service collection.</summary>
    IServiceCollection Services { get; }

    /// <summary>Records that a module has been registered.</summary>
    void RegisterModule<TModule>() where TModule : IBseModule;

    /// <summary>Returns true if the given module has already been registered.</summary>
    bool HasModule<TModule>() where TModule : IBseModule;
}
```

- [ ] **Step 4: Implement IBseModule**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/DependencyInjection/IBseModule.cs`:

```csharp
namespace Bse.Framework.Core.DependencyInjection;

/// <summary>
/// Marker interface implemented by framework feature modules.
/// Modules are tracked by <see cref="IBseFrameworkBuilder"/> so dependent modules
/// can verify their prerequisites are present at registration time.
/// </summary>
public interface IBseModule
{
    /// <summary>
    /// Configures services on the supplied builder. May depend on other modules
    /// having been registered first.
    /// </summary>
    void Configure(IBseFrameworkBuilder builder);
}
```

- [ ] **Step 5: Implement BseFrameworkBuilder**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/DependencyInjection/BseFrameworkBuilder.cs`:

```csharp
using Microsoft.Extensions.DependencyInjection;

namespace Bse.Framework.Core.DependencyInjection;

/// <inheritdoc />
public sealed class BseFrameworkBuilder : IBseFrameworkBuilder
{
    private readonly HashSet<Type> _modules = new();

    public BseFrameworkBuilder(IServiceCollection services)
    {
        Services = services ?? throw new ArgumentNullException(nameof(services));
    }

    public IServiceCollection Services { get; }

    public void RegisterModule<TModule>() where TModule : IBseModule
    {
        _modules.Add(typeof(TModule));
    }

    public bool HasModule<TModule>() where TModule : IBseModule
    {
        return _modules.Contains(typeof(TModule));
    }
}
```

- [ ] **Step 6: Run the tests to verify pass**

```bash
dotnet test --filter "FullyQualifiedName~BseFrameworkBuilderTests"
```

Expected: PASS — 4 tests passing.

- [ ] **Step 7: Commit**

```bash
git add src/Bse.Framework.Core/DependencyInjection/ tests/Bse.Framework.Core.Tests/DependencyInjection/
git commit -m "feat(core): add BseFrameworkBuilder and IBseModule"
```

---

## Task 13: ServiceCollectionExtensions (AddBseFramework)

**Files:**
- Create: `src/Bse.Framework.Core/DependencyInjection/ServiceCollectionExtensions.cs`
- Test: `tests/Bse.Framework.Core.Tests/DependencyInjection/ServiceCollectionExtensionsTests.cs`

- [ ] **Step 1: Write the failing tests**

Create `/Users/mahrous/Projects/bse-framework/tests/Bse.Framework.Core.Tests/DependencyInjection/ServiceCollectionExtensionsTests.cs`:

```csharp
using Bse.Framework.Core.DependencyInjection;
using Bse.Framework.Core.Identity;
using Bse.Framework.Core.Time;
using Microsoft.Extensions.DependencyInjection;

namespace Bse.Framework.Core.Tests.DependencyInjection;

public class ServiceCollectionExtensionsTests
{
    [Fact]
    public void AddBseFramework_RegistersSystemClock()
    {
        var services = new ServiceCollection();

        services.AddBseFramework();

        var provider = services.BuildServiceProvider();
        provider.GetRequiredService<ISystemClock>().ShouldBeOfType<SystemClock>();
    }

    [Fact]
    public void AddBseFramework_RegistersGuidGenerator()
    {
        var services = new ServiceCollection();

        services.AddBseFramework();

        var provider = services.BuildServiceProvider();
        provider.GetRequiredService<IGuidGenerator>().ShouldBeOfType<SequentialGuidGenerator>();
    }

    [Fact]
    public void AddBseFramework_InvokesConfigureCallback()
    {
        var services = new ServiceCollection();
        var callbackInvoked = false;

        services.AddBseFramework(builder =>
        {
            callbackInvoked = true;
            builder.Services.ShouldBe(services);
        });

        callbackInvoked.ShouldBeTrue();
    }

    [Fact]
    public void AddBseFramework_RegistersClockAsSingleton()
    {
        var services = new ServiceCollection();
        services.AddBseFramework();

        var provider = services.BuildServiceProvider();
        var first = provider.GetRequiredService<ISystemClock>();
        var second = provider.GetRequiredService<ISystemClock>();

        first.ShouldBeSameAs(second);
    }
}
```

- [ ] **Step 2: Run the tests to verify failure**

```bash
dotnet test --filter "FullyQualifiedName~ServiceCollectionExtensionsTests"
```

Expected: FAIL — `AddBseFramework` does not exist.

- [ ] **Step 3: Implement ServiceCollectionExtensions**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/DependencyInjection/ServiceCollectionExtensions.cs`:

```csharp
using Bse.Framework.Core.Identity;
using Bse.Framework.Core.Time;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Bse.Framework.Core.DependencyInjection;

/// <summary>
/// Entry-point extensions for registering Bse.Framework features.
/// </summary>
public static class ServiceCollectionExtensions
{
    /// <summary>
    /// Registers the framework's core services and invokes the optional configure callback
    /// for additional feature modules.
    /// </summary>
    public static IServiceCollection AddBseFramework(
        this IServiceCollection services,
        Action<IBseFrameworkBuilder>? configure = null)
    {
        ArgumentNullException.ThrowIfNull(services);

        // Core abstractions are always registered as singletons.
        services.TryAddSingleton<ISystemClock, SystemClock>();
        services.TryAddSingleton<IGuidGenerator, SequentialGuidGenerator>();

        var builder = new BseFrameworkBuilder(services);
        configure?.Invoke(builder);

        return services;
    }
}
```

- [ ] **Step 4: Run the tests to verify pass**

```bash
dotnet test --filter "FullyQualifiedName~ServiceCollectionExtensionsTests"
```

Expected: PASS — 4 tests passing.

- [ ] **Step 5: Commit**

```bash
git add src/Bse.Framework.Core/DependencyInjection/ServiceCollectionExtensions.cs tests/Bse.Framework.Core.Tests/DependencyInjection/ServiceCollectionExtensionsTests.cs
git commit -m "feat(core): add AddBseFramework entry-point extension"
```

---

## Task 14: BseLogScopes Helper

**Files:**
- Create: `src/Bse.Framework.Core/Logging/BseLogScopes.cs`
- Test: `tests/Bse.Framework.Core.Tests/Logging/BseLogScopesTests.cs`

**Why:** Across the framework we need to push consistent properties (TraceId, CorrelationId, TenantId, UserId) into log scopes. This helper centralizes the property names so they match between packages.

- [ ] **Step 1: Write the failing tests**

Create `/Users/mahrous/Projects/bse-framework/tests/Bse.Framework.Core.Tests/Logging/BseLogScopesTests.cs`:

```csharp
using Bse.Framework.Core.Logging;

namespace Bse.Framework.Core.Tests.Logging;

public class BseLogScopesTests
{
    [Fact]
    public void Request_BuildsScopeDictionary_WithGivenValues()
    {
        var scope = BseLogScopes.Request(
            traceId: "trace-1",
            spanId: "span-1",
            correlationId: "corr-1",
            tenantId: "tenant-a",
            userId: "user-42");

        scope[BseLogScopes.TraceIdKey].ShouldBe("trace-1");
        scope[BseLogScopes.SpanIdKey].ShouldBe("span-1");
        scope[BseLogScopes.CorrelationIdKey].ShouldBe("corr-1");
        scope[BseLogScopes.TenantIdKey].ShouldBe("tenant-a");
        scope[BseLogScopes.UserIdKey].ShouldBe("user-42");
    }

    [Fact]
    public void Request_OmitsNullValues()
    {
        var scope = BseLogScopes.Request(
            traceId: "trace-1",
            spanId: null,
            correlationId: "corr-1",
            tenantId: null,
            userId: null);

        scope.ContainsKey(BseLogScopes.TraceIdKey).ShouldBeTrue();
        scope.ContainsKey(BseLogScopes.SpanIdKey).ShouldBeFalse();
        scope.ContainsKey(BseLogScopes.CorrelationIdKey).ShouldBeTrue();
        scope.ContainsKey(BseLogScopes.TenantIdKey).ShouldBeFalse();
        scope.ContainsKey(BseLogScopes.UserIdKey).ShouldBeFalse();
    }
}
```

- [ ] **Step 2: Run the tests to verify failure**

```bash
dotnet test --filter "FullyQualifiedName~BseLogScopesTests"
```

Expected: FAIL — `BseLogScopes` does not exist.

- [ ] **Step 3: Implement BseLogScopes**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Logging/BseLogScopes.cs`:

```csharp
namespace Bse.Framework.Core.Logging;

/// <summary>
/// Canonical scope keys and helpers for structured logging.
/// All framework packages must use these keys so log enrichment is consistent.
/// </summary>
public static class BseLogScopes
{
    public const string TraceIdKey = "TraceId";
    public const string SpanIdKey = "SpanId";
    public const string CorrelationIdKey = "CorrelationId";
    public const string TenantIdKey = "TenantId";
    public const string UserIdKey = "UserId";
    public const string ServiceKey = "Service";
    public const string MethodKey = "Method";

    /// <summary>
    /// Builds a scope dictionary suitable for <c>ILogger.BeginScope</c>.
    /// Keys whose values are <c>null</c> are omitted.
    /// </summary>
    public static Dictionary<string, object> Request(
        string? traceId,
        string? spanId,
        string? correlationId,
        string? tenantId,
        string? userId)
    {
        var scope = new Dictionary<string, object>(capacity: 5);

        if (traceId is not null) scope[TraceIdKey] = traceId;
        if (spanId is not null) scope[SpanIdKey] = spanId;
        if (correlationId is not null) scope[CorrelationIdKey] = correlationId;
        if (tenantId is not null) scope[TenantIdKey] = tenantId;
        if (userId is not null) scope[UserIdKey] = userId;

        return scope;
    }
}
```

- [ ] **Step 4: Run the tests to verify pass**

```bash
dotnet test --filter "FullyQualifiedName~BseLogScopesTests"
```

Expected: PASS — 2 tests passing.

- [ ] **Step 5: Commit**

```bash
git add src/Bse.Framework.Core/Logging/ tests/Bse.Framework.Core.Tests/Logging/
git commit -m "feat(core): add BseLogScopes for canonical structured log keys"
```

---

## Task 15: Sensitive Data Redaction

**Files:**
- Create: `src/Bse.Framework.Core/Redaction/RedactionRule.cs`
- Create: `src/Bse.Framework.Core/Redaction/ISensitiveDataRedactor.cs`
- Create: `src/Bse.Framework.Core/Redaction/DefaultRedactor.cs`
- Test: `tests/Bse.Framework.Core.Tests/Redaction/DefaultRedactorTests.cs`

- [ ] **Step 1: Write the failing tests**

Create `/Users/mahrous/Projects/bse-framework/tests/Bse.Framework.Core.Tests/Redaction/DefaultRedactorTests.cs`:

```csharp
using Bse.Framework.Core.Redaction;

namespace Bse.Framework.Core.Tests.Redaction;

public class DefaultRedactorTests
{
    [Fact]
    public void Redact_RedactsByExactKey_CaseInsensitive()
    {
        var redactor = new DefaultRedactor(new[]
        {
            new RedactionRule(KeyPattern: "password", Replacement: "***")
        });

        var result = redactor.Redact("Password", "secret123");

        result.ShouldBe("***");
    }

    [Fact]
    public void Redact_DoesNotRedact_WhenKeyDoesNotMatch()
    {
        var redactor = new DefaultRedactor(new[]
        {
            new RedactionRule(KeyPattern: "password", Replacement: "***")
        });

        var result = redactor.Redact("name", "alice");

        result.ShouldBe("alice");
    }

    [Fact]
    public void Redact_HashesValue_WhenHashStrategy()
    {
        var redactor = new DefaultRedactor(new[]
        {
            new RedactionRule(KeyPattern: "user.id", Strategy: RedactionStrategy.Hash)
        });

        var result = redactor.Redact("user.id", "alice");

        result.ShouldNotBe("alice");
        result.Length.ShouldBeGreaterThan(0);
    }

    [Fact]
    public void Redact_HashIsStable_AcrossCalls()
    {
        var redactor = new DefaultRedactor(new[]
        {
            new RedactionRule(KeyPattern: "user.id", Strategy: RedactionStrategy.Hash)
        });

        var first = redactor.Redact("user.id", "alice");
        var second = redactor.Redact("user.id", "alice");

        first.ShouldBe(second);
    }

    [Fact]
    public void Redact_MatchesByWildcardSuffix()
    {
        var redactor = new DefaultRedactor(new[]
        {
            new RedactionRule(KeyPattern: "*.password", Replacement: "***")
        });

        var result = redactor.Redact("user.password", "secret");

        result.ShouldBe("***");
    }
}
```

- [ ] **Step 2: Run the tests to verify failure**

```bash
dotnet test --filter "FullyQualifiedName~DefaultRedactorTests"
```

Expected: FAIL — types do not exist.

- [ ] **Step 3: Implement RedactionRule**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Redaction/RedactionRule.cs`:

```csharp
namespace Bse.Framework.Core.Redaction;

public enum RedactionStrategy
{
    /// <summary>Replace the value with a constant string (default: "***").</summary>
    Replace,

    /// <summary>Replace with a stable SHA-256 hash, useful for joinable telemetry.</summary>
    Hash,

    /// <summary>Drop the value entirely (returns null).</summary>
    Drop
}

/// <summary>
/// Describes how to redact a single field. <see cref="KeyPattern"/> matches the field name
/// case-insensitively. A leading "*." acts as a wildcard suffix matcher (e.g. "*.password").
/// </summary>
public sealed record RedactionRule(
    string KeyPattern,
    RedactionStrategy Strategy = RedactionStrategy.Replace,
    string Replacement = "***");
```

- [ ] **Step 4: Implement ISensitiveDataRedactor**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Redaction/ISensitiveDataRedactor.cs`:

```csharp
namespace Bse.Framework.Core.Redaction;

/// <summary>
/// Redacts sensitive values from a key/value pair before they are written to logs or traces.
/// Implementations must be thread-safe and free of side effects.
/// </summary>
public interface ISensitiveDataRedactor
{
    /// <summary>
    /// Returns the redacted form of <paramref name="value"/> for the given <paramref name="key"/>.
    /// If no rule matches, the original value is returned unchanged.
    /// </summary>
    string? Redact(string key, string value);
}
```

- [ ] **Step 5: Implement DefaultRedactor**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Redaction/DefaultRedactor.cs`:

```csharp
using System.Security.Cryptography;
using System.Text;

namespace Bse.Framework.Core.Redaction;

/// <summary>
/// Rule-based redactor. Rules are evaluated in order; the first match wins.
/// </summary>
public sealed class DefaultRedactor : ISensitiveDataRedactor
{
    private readonly IReadOnlyList<RedactionRule> _rules;

    public DefaultRedactor(IEnumerable<RedactionRule> rules)
    {
        _rules = rules?.ToList() ?? throw new ArgumentNullException(nameof(rules));
    }

    public string? Redact(string key, string value)
    {
        ArgumentNullException.ThrowIfNull(key);
        ArgumentNullException.ThrowIfNull(value);

        foreach (var rule in _rules)
        {
            if (Matches(rule.KeyPattern, key))
            {
                return rule.Strategy switch
                {
                    RedactionStrategy.Replace => rule.Replacement,
                    RedactionStrategy.Hash => Hash(value),
                    RedactionStrategy.Drop => null,
                    _ => rule.Replacement
                };
            }
        }

        return value;
    }

    private static bool Matches(string pattern, string key)
    {
        if (pattern.StartsWith("*.", StringComparison.Ordinal))
        {
            var suffix = pattern[1..]; // ".password"
            return key.EndsWith(suffix, StringComparison.OrdinalIgnoreCase);
        }

        return string.Equals(pattern, key, StringComparison.OrdinalIgnoreCase);
    }

    private static string Hash(string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        var hash = SHA256.HashData(bytes);
        return Convert.ToHexString(hash)[..16].ToLowerInvariant();
    }
}
```

- [ ] **Step 6: Run the tests to verify pass**

```bash
dotnet test --filter "FullyQualifiedName~DefaultRedactorTests"
```

Expected: PASS — 5 tests passing.

- [ ] **Step 7: Commit**

```bash
git add src/Bse.Framework.Core/Redaction/ tests/Bse.Framework.Core.Tests/Redaction/
git commit -m "feat(core): add sensitive data redactor with replace/hash/drop strategies"
```

---

## Task 16: GracefulShutdown Coordinator

**Files:**
- Create: `src/Bse.Framework.Core/Shutdown/IShutdownParticipant.cs`
- Create: `src/Bse.Framework.Core/Shutdown/IGracefulShutdownCoordinator.cs`
- Create: `src/Bse.Framework.Core/Shutdown/GracefulShutdownOptions.cs`
- Create: `src/Bse.Framework.Core/Shutdown/GracefulShutdownCoordinator.cs`
- Test: `tests/Bse.Framework.Core.Tests/Shutdown/GracefulShutdownCoordinatorTests.cs`

**Why:** Each framework package (RPC, Data, Telemetry) has its own shutdown work — drain consumers, flush metrics, complete in-flight transactions. The coordinator orchestrates them in reverse-registration order with a global timeout.

- [ ] **Step 1: Write the failing tests**

Create `/Users/mahrous/Projects/bse-framework/tests/Bse.Framework.Core.Tests/Shutdown/GracefulShutdownCoordinatorTests.cs`:

```csharp
using Bse.Framework.Core.Shutdown;
using Microsoft.Extensions.Options;

namespace Bse.Framework.Core.Tests.Shutdown;

public class GracefulShutdownCoordinatorTests
{
    private static IOptions<GracefulShutdownOptions> Options(TimeSpan timeout) =>
        Microsoft.Extensions.Options.Options.Create(new GracefulShutdownOptions { Timeout = timeout });

    [Fact]
    public async Task ShutdownAsync_InvokesAllParticipants_InReverseRegistrationOrder()
    {
        var calls = new List<string>();
        var coord = new GracefulShutdownCoordinator(Options(TimeSpan.FromSeconds(5)));

        coord.Register(new TestParticipant("A", calls));
        coord.Register(new TestParticipant("B", calls));
        coord.Register(new TestParticipant("C", calls));

        await coord.ShutdownAsync(CancellationToken.None);

        calls.ShouldBe(new[] { "C", "B", "A" });
    }

    [Fact]
    public async Task ShutdownAsync_RespectsTimeout()
    {
        var coord = new GracefulShutdownCoordinator(Options(TimeSpan.FromMilliseconds(100)));

        coord.Register(new SlowParticipant(TimeSpan.FromSeconds(5)));

        var sw = System.Diagnostics.Stopwatch.StartNew();
        await coord.ShutdownAsync(CancellationToken.None);
        sw.Stop();

        sw.Elapsed.ShouldBeLessThan(TimeSpan.FromSeconds(2));
    }

    [Fact]
    public async Task ShutdownAsync_ContinuesAfterParticipantThrows()
    {
        var calls = new List<string>();
        var coord = new GracefulShutdownCoordinator(Options(TimeSpan.FromSeconds(5)));

        coord.Register(new TestParticipant("A", calls));
        coord.Register(new ThrowingParticipant());
        coord.Register(new TestParticipant("C", calls));

        await coord.ShutdownAsync(CancellationToken.None);

        calls.ShouldContain("A");
        calls.ShouldContain("C");
    }

    private sealed class TestParticipant : IShutdownParticipant
    {
        private readonly string _name;
        private readonly List<string> _calls;
        public TestParticipant(string name, List<string> calls) { _name = name; _calls = calls; }
        public string Name => _name;
        public Task ShutdownAsync(CancellationToken ct)
        {
            lock (_calls) { _calls.Add(_name); }
            return Task.CompletedTask;
        }
    }

    private sealed class SlowParticipant : IShutdownParticipant
    {
        private readonly TimeSpan _delay;
        public SlowParticipant(TimeSpan delay) { _delay = delay; }
        public string Name => "Slow";
        public async Task ShutdownAsync(CancellationToken ct)
        {
            try { await Task.Delay(_delay, ct); } catch (OperationCanceledException) { }
        }
    }

    private sealed class ThrowingParticipant : IShutdownParticipant
    {
        public string Name => "Throwing";
        public Task ShutdownAsync(CancellationToken ct)
            => throw new InvalidOperationException("boom");
    }
}
```

- [ ] **Step 2: Run the tests to verify failure**

```bash
dotnet test --filter "FullyQualifiedName~GracefulShutdownCoordinatorTests"
```

Expected: FAIL — types do not exist.

- [ ] **Step 3: Implement IShutdownParticipant**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Shutdown/IShutdownParticipant.cs`:

```csharp
namespace Bse.Framework.Core.Shutdown;

/// <summary>
/// Implemented by services that need to perform cleanup work during graceful shutdown.
/// Examples: drain consumer queues, flush metric exporters, finish in-flight transactions.
/// </summary>
public interface IShutdownParticipant
{
    /// <summary>Human-readable name shown in shutdown logs.</summary>
    string Name { get; }

    /// <summary>
    /// Performs shutdown work. The supplied cancellation token fires when the global
    /// shutdown timeout expires; participants must respect it and abandon work.
    /// </summary>
    Task ShutdownAsync(CancellationToken cancellationToken);
}
```

- [ ] **Step 4: Implement IGracefulShutdownCoordinator**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Shutdown/IGracefulShutdownCoordinator.cs`:

```csharp
namespace Bse.Framework.Core.Shutdown;

/// <summary>
/// Coordinates graceful shutdown across multiple framework packages.
/// Participants are invoked in reverse-registration order so that downstream
/// dependencies (e.g. logging, metrics) are torn down last.
/// </summary>
public interface IGracefulShutdownCoordinator
{
    /// <summary>Adds a participant to the shutdown chain.</summary>
    void Register(IShutdownParticipant participant);

    /// <summary>
    /// Invokes every participant. The configured timeout limits total shutdown time.
    /// Exceptions thrown by individual participants are caught and logged so the
    /// chain continues.
    /// </summary>
    Task ShutdownAsync(CancellationToken cancellationToken);
}
```

- [ ] **Step 5: Implement GracefulShutdownOptions**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Shutdown/GracefulShutdownOptions.cs`:

```csharp
namespace Bse.Framework.Core.Shutdown;

/// <summary>
/// Options controlling graceful shutdown behavior.
/// </summary>
public sealed class GracefulShutdownOptions
{
    /// <summary>
    /// Maximum total time allowed for all participants combined. Defaults to 30 seconds,
    /// matching Kubernetes' default <c>terminationGracePeriodSeconds</c>.
    /// </summary>
    public TimeSpan Timeout { get; set; } = TimeSpan.FromSeconds(30);
}
```

- [ ] **Step 6: Implement GracefulShutdownCoordinator**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Shutdown/GracefulShutdownCoordinator.cs`:

```csharp
using Microsoft.Extensions.Options;

namespace Bse.Framework.Core.Shutdown;

/// <inheritdoc />
public sealed class GracefulShutdownCoordinator : IGracefulShutdownCoordinator
{
    private readonly List<IShutdownParticipant> _participants = new();
    private readonly GracefulShutdownOptions _options;
    private readonly object _lock = new();

    public GracefulShutdownCoordinator(IOptions<GracefulShutdownOptions> options)
    {
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
    }

    public void Register(IShutdownParticipant participant)
    {
        ArgumentNullException.ThrowIfNull(participant);
        lock (_lock)
        {
            _participants.Add(participant);
        }
    }

    public async Task ShutdownAsync(CancellationToken cancellationToken)
    {
        IShutdownParticipant[] snapshot;
        lock (_lock)
        {
            snapshot = _participants.AsEnumerable().Reverse().ToArray();
        }

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(_options.Timeout);

        foreach (var participant in snapshot)
        {
            if (timeoutCts.IsCancellationRequested)
            {
                break;
            }

            try
            {
                await participant.ShutdownAsync(timeoutCts.Token).ConfigureAwait(false);
            }
            catch (Exception)
            {
                // Swallow per participant — ILogger is wired in by hosting integration in Task 19.
                // We never let one participant block the rest.
            }
        }
    }
}
```

- [ ] **Step 7: Run the tests to verify pass**

```bash
dotnet test --filter "FullyQualifiedName~GracefulShutdownCoordinatorTests"
```

Expected: PASS — 3 tests passing.

- [ ] **Step 8: Commit**

```bash
git add src/Bse.Framework.Core/Shutdown/ tests/Bse.Framework.Core.Tests/Shutdown/
git commit -m "feat(core): add graceful shutdown coordinator with reverse-order participants"
```

---

## Task 17: Health Check Aggregation

**Files:**
- Create: `src/Bse.Framework.Core/Health/HealthEndpointConfiguration.cs`
- Create: `src/Bse.Framework.Core/Health/BseHealthCheckExtensions.cs`
- Test: `tests/Bse.Framework.Core.Tests/Health/BseHealthCheckExtensionsTests.cs`

**Why:** Each package registers its own health checks. The framework provides a single `AddBseHealthChecks` method that wires up the standard `/health/live` and `/health/ready` endpoints with consistent JSON output and tag-based filtering.

- [ ] **Step 1: Write the failing tests**

Create `/Users/mahrous/Projects/bse-framework/tests/Bse.Framework.Core.Tests/Health/BseHealthCheckExtensionsTests.cs`:

```csharp
using Bse.Framework.Core.DependencyInjection;
using Bse.Framework.Core.Health;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace Bse.Framework.Core.Tests.Health;

public class BseHealthCheckExtensionsTests
{
    [Fact]
    public void AddBseHealthChecks_RegistersHealthCheckService()
    {
        var services = new ServiceCollection();

        services.AddBseFramework(framework =>
        {
            framework.AddBseHealthChecks();
        });

        var provider = services.BuildServiceProvider();
        provider.GetService<HealthCheckService>().ShouldNotBeNull();
    }

    [Fact]
    public void AddBseHealthChecks_AllowsAddingChecksViaCallback()
    {
        var services = new ServiceCollection();
        var checkInvoked = false;

        services.AddBseFramework(framework =>
        {
            framework.AddBseHealthChecks(builder =>
            {
                builder.AddCheck("test", () =>
                {
                    checkInvoked = true;
                    return HealthCheckResult.Healthy();
                });
            });
        });

        var provider = services.BuildServiceProvider();
        var service = provider.GetRequiredService<HealthCheckService>();

        service.CheckHealthAsync().GetAwaiter().GetResult();
        checkInvoked.ShouldBeTrue();
    }

    [Fact]
    public void HealthEndpointConfiguration_HasDefaultPaths()
    {
        var config = new HealthEndpointConfiguration();

        config.LivePath.ShouldBe("/health/live");
        config.ReadyPath.ShouldBe("/health/ready");
    }

    [Fact]
    public void HealthEndpointConfiguration_HasDefaultTags()
    {
        var config = new HealthEndpointConfiguration();

        config.LiveTag.ShouldBe("live");
        config.ReadyTag.ShouldBe("ready");
    }
}
```

- [ ] **Step 2: Run the tests to verify failure**

```bash
dotnet test --filter "FullyQualifiedName~BseHealthCheckExtensionsTests"
```

Expected: FAIL — types do not exist.

- [ ] **Step 3: Implement HealthEndpointConfiguration**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Health/HealthEndpointConfiguration.cs`:

```csharp
namespace Bse.Framework.Core.Health;

/// <summary>
/// Configures the URL paths and check tags used by the framework's standard health endpoints.
/// </summary>
public sealed class HealthEndpointConfiguration
{
    /// <summary>Path used for liveness probes (default <c>/health/live</c>).</summary>
    public string LivePath { get; set; } = "/health/live";

    /// <summary>Path used for readiness probes (default <c>/health/ready</c>).</summary>
    public string ReadyPath { get; set; } = "/health/ready";

    /// <summary>Tag identifying liveness checks (default <c>live</c>).</summary>
    public string LiveTag { get; set; } = "live";

    /// <summary>Tag identifying readiness checks (default <c>ready</c>).</summary>
    public string ReadyTag { get; set; } = "ready";
}
```

- [ ] **Step 4: Implement BseHealthCheckExtensions**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Health/BseHealthCheckExtensions.cs`:

```csharp
using Bse.Framework.Core.DependencyInjection;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Bse.Framework.Core.Health;

/// <summary>
/// Adds aggregated health check support to a Bse.Framework application.
/// </summary>
public static class BseHealthCheckExtensions
{
    public static IBseFrameworkBuilder AddBseHealthChecks(
        this IBseFrameworkBuilder builder,
        Action<IHealthChecksBuilder>? configure = null)
    {
        ArgumentNullException.ThrowIfNull(builder);

        builder.Services.TryAddSingleton<HealthEndpointConfiguration>();
        var healthChecksBuilder = builder.Services.AddHealthChecks();
        configure?.Invoke(healthChecksBuilder);

        return builder;
    }
}
```

- [ ] **Step 5: Run the tests to verify pass**

```bash
dotnet test --filter "FullyQualifiedName~BseHealthCheckExtensionsTests"
```

Expected: PASS — 4 tests passing.

- [ ] **Step 6: Commit**

```bash
git add src/Bse.Framework.Core/Health/ tests/Bse.Framework.Core.Tests/Health/
git commit -m "feat(core): add aggregated health check registration"
```

---

## Task 18: ErrorCodeMappings (HTTP Status Mapping)

**Files:**
- Create: `src/Bse.Framework.Core/ExceptionHandling/ErrorCodeMappings.cs`

**Why:** When the exception handler middleware turns an exception into a Problem Details response, it needs a stable mapping from `BseException.ErrorCode` to HTTP status code. Centralizing this map keeps middleware testable.

- [ ] **Step 1: Implement ErrorCodeMappings**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/ExceptionHandling/ErrorCodeMappings.cs`:

```csharp
using Bse.Framework.Core.Exceptions;

namespace Bse.Framework.Core.ExceptionHandling;

/// <summary>
/// Maps framework exception types and error codes to HTTP status codes
/// for use by <see cref="BseExceptionHandlerMiddleware"/>.
/// </summary>
public static class ErrorCodeMappings
{
    public static int GetStatusCode(BseException exception)
    {
        ArgumentNullException.ThrowIfNull(exception);

        return exception switch
        {
            BseValidationException => 400,
            BseNotFoundException => 404,
            BseConcurrencyException => 409,
            BseConfigurationException => 500,
            _ => 500
        };
    }

    public static string GetTitle(BseException exception)
    {
        ArgumentNullException.ThrowIfNull(exception);

        return exception switch
        {
            BseValidationException => "Validation failed",
            BseNotFoundException => "Resource not found",
            BseConcurrencyException => "Concurrency conflict",
            BseConfigurationException => "Configuration error",
            _ => "An unexpected error occurred"
        };
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
dotnet build
```

Expected: Build succeeded.

- [ ] **Step 3: Commit**

```bash
git add src/Bse.Framework.Core/ExceptionHandling/ErrorCodeMappings.cs
git commit -m "feat(core): add error code to HTTP status mappings"
```

---

## Task 19: BseProblemDetailsFactory

**Files:**
- Create: `src/Bse.Framework.Core/ExceptionHandling/BseProblemDetailsFactory.cs`
- Test: `tests/Bse.Framework.Core.Tests/ExceptionHandling/BseProblemDetailsFactoryTests.cs`

**Why:** Centralized factory that turns any `BseException` (or generic `Exception`) into a Problem Details (RFC 9457) object. Validation exceptions get the field map; not-found exceptions get type+id; everything else gets a generic problem.

- [ ] **Step 1: Write the failing tests**

Create `/Users/mahrous/Projects/bse-framework/tests/Bse.Framework.Core.Tests/ExceptionHandling/BseProblemDetailsFactoryTests.cs`:

```csharp
using Bse.Framework.Core.Exceptions;
using Bse.Framework.Core.ExceptionHandling;
using Microsoft.AspNetCore.Mvc;

namespace Bse.Framework.Core.Tests.ExceptionHandling;

public class BseProblemDetailsFactoryTests
{
    private readonly BseProblemDetailsFactory _factory = new();

    [Fact]
    public void Create_FromValidationException_ReturnsValidationProblemDetails()
    {
        var ex = new BseValidationException(new Dictionary<string, string[]>
        {
            ["Email"] = new[] { "required" }
        });

        var result = _factory.Create(ex, traceId: "trace-1");

        result.Status.ShouldBe(400);
        result.ShouldBeOfType<ValidationProblemDetails>();
        var validation = (ValidationProblemDetails)result;
        validation.Errors.ShouldContainKey("Email");
    }

    [Fact]
    public void Create_FromNotFoundException_Returns404()
    {
        var ex = new BseNotFoundException("Student", 42);

        var result = _factory.Create(ex, traceId: "trace-2");

        result.Status.ShouldBe(404);
        result.Title.ShouldBe("Resource not found");
        result.Extensions["errorCode"].ShouldBe("NotFound");
    }

    [Fact]
    public void Create_FromUnknownException_Returns500()
    {
        var ex = new InvalidOperationException("boom");

        var result = _factory.Create(ex, traceId: "trace-3");

        result.Status.ShouldBe(500);
        result.Title.ShouldBe("An unexpected error occurred");
    }

    [Fact]
    public void Create_IncludesTraceIdInExtensions()
    {
        var ex = new BseNotFoundException("Student", 1);

        var result = _factory.Create(ex, traceId: "trace-xyz");

        result.Extensions["traceId"].ShouldBe("trace-xyz");
    }

    [Fact]
    public void Create_DoesNotIncludeStackTrace_ByDefault()
    {
        var ex = new InvalidOperationException("boom");

        var result = _factory.Create(ex, traceId: "trace-1");

        result.Detail.ShouldNotContain("at ");
    }
}
```

- [ ] **Step 2: Run the tests to verify failure**

```bash
dotnet test --filter "FullyQualifiedName~BseProblemDetailsFactoryTests"
```

Expected: FAIL — `BseProblemDetailsFactory` does not exist.

- [ ] **Step 3: Implement BseProblemDetailsFactory**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/ExceptionHandling/BseProblemDetailsFactory.cs`:

```csharp
using Bse.Framework.Core.Exceptions;
using Microsoft.AspNetCore.Mvc;

namespace Bse.Framework.Core.ExceptionHandling;

/// <summary>
/// Builds RFC 9457 Problem Details objects from exceptions.
/// Stack traces are intentionally never included; the trace identifier is enough
/// to correlate to logs/traces in observability tooling.
/// </summary>
public sealed class BseProblemDetailsFactory
{
    public ProblemDetails Create(Exception exception, string? traceId)
    {
        ArgumentNullException.ThrowIfNull(exception);

        if (exception is BseValidationException validation)
        {
            return BuildValidation(validation, traceId);
        }

        if (exception is BseException bseEx)
        {
            return BuildBse(bseEx, traceId);
        }

        return BuildUnknown(exception, traceId);
    }

    private static ValidationProblemDetails BuildValidation(BseValidationException ex, string? traceId)
    {
        var problem = new ValidationProblemDetails(ex.Errors.ToDictionary(kvp => kvp.Key, kvp => kvp.Value))
        {
            Status = 400,
            Title = ErrorCodeMappings.GetTitle(ex),
            Detail = ex.Message
        };
        problem.Extensions["errorCode"] = ex.ErrorCode;
        if (traceId is not null) problem.Extensions["traceId"] = traceId;
        return problem;
    }

    private static ProblemDetails BuildBse(BseException ex, string? traceId)
    {
        var problem = new ProblemDetails
        {
            Status = ErrorCodeMappings.GetStatusCode(ex),
            Title = ErrorCodeMappings.GetTitle(ex),
            Detail = ex.Message
        };
        problem.Extensions["errorCode"] = ex.ErrorCode;
        if (traceId is not null) problem.Extensions["traceId"] = traceId;
        return problem;
    }

    private static ProblemDetails BuildUnknown(Exception ex, string? traceId)
    {
        var problem = new ProblemDetails
        {
            Status = 500,
            Title = "An unexpected error occurred",
            Detail = ex.Message
        };
        problem.Extensions["errorCode"] = "InternalError";
        if (traceId is not null) problem.Extensions["traceId"] = traceId;
        return problem;
    }
}
```

- [ ] **Step 4: Run the tests to verify pass**

```bash
dotnet test --filter "FullyQualifiedName~BseProblemDetailsFactoryTests"
```

Expected: PASS — 5 tests passing.

- [ ] **Step 5: Commit**

```bash
git add src/Bse.Framework.Core/ExceptionHandling/BseProblemDetailsFactory.cs tests/Bse.Framework.Core.Tests/ExceptionHandling/BseProblemDetailsFactoryTests.cs
git commit -m "feat(core): add BseProblemDetailsFactory for RFC 9457 error responses"
```

---

## Task 20: BseExceptionHandlerMiddleware

**Files:**
- Create: `src/Bse.Framework.Core/ExceptionHandling/BseExceptionHandlerMiddleware.cs`
- Test: `tests/Bse.Framework.Core.Tests/ExceptionHandling/BseExceptionHandlerMiddlewareTests.cs`

**Why:** ASP.NET Core middleware that catches all exceptions, runs them through the factory, writes the JSON response, and logs the original exception. Replaces the per-controller try/catch sprinkled across the legacy apps.

- [ ] **Step 1: Add the middleware dependency**

The middleware needs `Microsoft.AspNetCore.Http.Abstractions` (already included in `Microsoft.AspNetCore.Mvc.Core`).

- [ ] **Step 2: Write the failing tests**

Create `/Users/mahrous/Projects/bse-framework/tests/Bse.Framework.Core.Tests/ExceptionHandling/BseExceptionHandlerMiddlewareTests.cs`:

```csharp
using System.Text.Json;
using Bse.Framework.Core.Exceptions;
using Bse.Framework.Core.ExceptionHandling;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bse.Framework.Core.Tests.ExceptionHandling;

public class BseExceptionHandlerMiddlewareTests
{
    [Fact]
    public async Task Invoke_PassesThrough_WhenNoException()
    {
        var middleware = new BseExceptionHandlerMiddleware(
            next: ctx => Task.CompletedTask,
            factory: new BseProblemDetailsFactory(),
            logger: NullLogger<BseExceptionHandlerMiddleware>.Instance);

        var context = new DefaultHttpContext();
        context.Response.Body = new MemoryStream();

        await middleware.InvokeAsync(context);

        context.Response.StatusCode.ShouldBe(200);
    }

    [Fact]
    public async Task Invoke_WritesProblemDetails_WhenBseExceptionThrown()
    {
        var middleware = new BseExceptionHandlerMiddleware(
            next: ctx => throw new BseNotFoundException("Student", 42),
            factory: new BseProblemDetailsFactory(),
            logger: NullLogger<BseExceptionHandlerMiddleware>.Instance);

        var context = new DefaultHttpContext();
        var body = new MemoryStream();
        context.Response.Body = body;

        await middleware.InvokeAsync(context);

        context.Response.StatusCode.ShouldBe(404);
        context.Response.ContentType.ShouldBe("application/problem+json");

        body.Position = 0;
        var json = await new StreamReader(body).ReadToEndAsync();
        var doc = JsonDocument.Parse(json);
        doc.RootElement.GetProperty("status").GetInt32().ShouldBe(404);
        doc.RootElement.GetProperty("errorCode").GetString().ShouldBe("NotFound");
    }

    [Fact]
    public async Task Invoke_WritesProblemDetails_WhenUnknownExceptionThrown()
    {
        var middleware = new BseExceptionHandlerMiddleware(
            next: ctx => throw new InvalidOperationException("boom"),
            factory: new BseProblemDetailsFactory(),
            logger: NullLogger<BseExceptionHandlerMiddleware>.Instance);

        var context = new DefaultHttpContext();
        var body = new MemoryStream();
        context.Response.Body = body;

        await middleware.InvokeAsync(context);

        context.Response.StatusCode.ShouldBe(500);
    }
}
```

- [ ] **Step 3: Run the tests to verify failure**

```bash
dotnet test --filter "FullyQualifiedName~BseExceptionHandlerMiddlewareTests"
```

Expected: FAIL — middleware does not exist.

- [ ] **Step 4: Implement BseExceptionHandlerMiddleware**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/ExceptionHandling/BseExceptionHandlerMiddleware.cs`:

```csharp
using System.Diagnostics;
using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

namespace Bse.Framework.Core.ExceptionHandling;

/// <summary>
/// Catches exceptions thrown by downstream middleware/endpoints and converts them
/// into RFC 9457 Problem Details JSON responses.
/// </summary>
public sealed class BseExceptionHandlerMiddleware
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };

    private readonly RequestDelegate _next;
    private readonly BseProblemDetailsFactory _factory;
    private readonly ILogger<BseExceptionHandlerMiddleware> _logger;

    public BseExceptionHandlerMiddleware(
        RequestDelegate next,
        BseProblemDetailsFactory factory,
        ILogger<BseExceptionHandlerMiddleware> logger)
    {
        _next = next ?? throw new ArgumentNullException(nameof(next));
        _factory = factory ?? throw new ArgumentNullException(nameof(factory));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    public async Task InvokeAsync(HttpContext context)
    {
        try
        {
            await _next(context).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            var traceId = Activity.Current?.Id ?? context.TraceIdentifier;
            _logger.LogError(ex, "Unhandled exception in request pipeline. TraceId: {TraceId}", traceId);

            var problem = _factory.Create(ex, traceId);

            context.Response.StatusCode = problem.Status ?? 500;
            context.Response.ContentType = "application/problem+json";

            var json = JsonSerializer.Serialize(problem, JsonOptions);
            await context.Response.WriteAsync(json).ConfigureAwait(false);
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify pass**

```bash
dotnet test --filter "FullyQualifiedName~BseExceptionHandlerMiddlewareTests"
```

Expected: PASS — 3 tests passing.

- [ ] **Step 6: Commit**

```bash
git add src/Bse.Framework.Core/ExceptionHandling/BseExceptionHandlerMiddleware.cs tests/Bse.Framework.Core.Tests/ExceptionHandling/BseExceptionHandlerMiddlewareTests.cs
git commit -m "feat(core): add ASP.NET Core exception handler middleware"
```

---

## Task 21: Wire Shutdown and Exception Handling into ServiceCollectionExtensions

**Files:**
- Modify: `src/Bse.Framework.Core/DependencyInjection/ServiceCollectionExtensions.cs`
- Modify: `tests/Bse.Framework.Core.Tests/DependencyInjection/ServiceCollectionExtensionsTests.cs`

- [ ] **Step 1: Write a failing test for shutdown registration**

Append to `/Users/mahrous/Projects/bse-framework/tests/Bse.Framework.Core.Tests/DependencyInjection/ServiceCollectionExtensionsTests.cs` (inside the existing class):

```csharp
    [Fact]
    public void AddBseFramework_RegistersGracefulShutdownCoordinator()
    {
        var services = new ServiceCollection();

        services.AddBseFramework();

        var provider = services.BuildServiceProvider();
        provider.GetRequiredService<Bse.Framework.Core.Shutdown.IGracefulShutdownCoordinator>()
            .ShouldBeOfType<Bse.Framework.Core.Shutdown.GracefulShutdownCoordinator>();
    }

    [Fact]
    public void AddBseFramework_RegistersProblemDetailsFactory()
    {
        var services = new ServiceCollection();

        services.AddBseFramework();

        var provider = services.BuildServiceProvider();
        provider.GetRequiredService<Bse.Framework.Core.ExceptionHandling.BseProblemDetailsFactory>()
            .ShouldNotBeNull();
    }

    [Fact]
    public void AddBseFramework_RegistersDefaultRedactor()
    {
        var services = new ServiceCollection();

        services.AddBseFramework();

        var provider = services.BuildServiceProvider();
        provider.GetRequiredService<Bse.Framework.Core.Redaction.ISensitiveDataRedactor>()
            .ShouldBeOfType<Bse.Framework.Core.Redaction.DefaultRedactor>();
    }
```

- [ ] **Step 2: Run the tests to verify failure**

```bash
dotnet test --filter "FullyQualifiedName~ServiceCollectionExtensionsTests"
```

Expected: 3 new tests fail (services not registered yet).

- [ ] **Step 3: Update ServiceCollectionExtensions to register everything**

Replace `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/DependencyInjection/ServiceCollectionExtensions.cs` with:

```csharp
using Bse.Framework.Core.ExceptionHandling;
using Bse.Framework.Core.Identity;
using Bse.Framework.Core.Redaction;
using Bse.Framework.Core.Shutdown;
using Bse.Framework.Core.Time;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Options;

namespace Bse.Framework.Core.DependencyInjection;

/// <summary>
/// Entry-point extensions for registering Bse.Framework features.
/// </summary>
public static class ServiceCollectionExtensions
{
    /// <summary>
    /// Registers the framework's core services and invokes the optional configure callback
    /// for additional feature modules.
    /// </summary>
    public static IServiceCollection AddBseFramework(
        this IServiceCollection services,
        Action<IBseFrameworkBuilder>? configure = null)
    {
        ArgumentNullException.ThrowIfNull(services);

        // Time and identity
        services.TryAddSingleton<ISystemClock, SystemClock>();
        services.TryAddSingleton<IGuidGenerator, SequentialGuidGenerator>();

        // Redaction
        services.TryAddSingleton<ISensitiveDataRedactor>(_ =>
            new DefaultRedactor(DefaultRedactionRules()));

        // Exception handling
        services.TryAddSingleton<BseProblemDetailsFactory>();

        // Shutdown coordinator
        services.AddOptions<GracefulShutdownOptions>();
        services.TryAddSingleton<IGracefulShutdownCoordinator, GracefulShutdownCoordinator>();

        var builder = new BseFrameworkBuilder(services);
        configure?.Invoke(builder);

        return services;
    }

    private static IEnumerable<RedactionRule> DefaultRedactionRules()
    {
        // Common sensitive field patterns. Consumers can override by registering
        // their own ISensitiveDataRedactor before calling AddBseFramework.
        yield return new RedactionRule(KeyPattern: "*.password");
        yield return new RedactionRule(KeyPattern: "password");
        yield return new RedactionRule(KeyPattern: "authorization");
        yield return new RedactionRule(KeyPattern: "cookie");
        yield return new RedactionRule(KeyPattern: "*.secret");
        yield return new RedactionRule(KeyPattern: "*.apiKey");
        yield return new RedactionRule(KeyPattern: "*.token");
    }
}
```

- [ ] **Step 4: Run all tests**

```bash
dotnet test
```

Expected: All tests pass (including the 3 new ones).

- [ ] **Step 5: Commit**

```bash
git add src/Bse.Framework.Core/DependencyInjection/ServiceCollectionExtensions.cs tests/Bse.Framework.Core.Tests/DependencyInjection/ServiceCollectionExtensionsTests.cs
git commit -m "feat(core): wire shutdown, problem details, and redactor into AddBseFramework"
```

---

## Task 22: Application Builder Extensions for Middleware

**Files:**
- Create: `src/Bse.Framework.Core/ExceptionHandling/ApplicationBuilderExtensions.cs`

**Why:** Consumers need a one-liner `app.UseBseExceptionHandler()` to register the middleware. This file lives next to the middleware so they evolve together.

- [ ] **Step 1: Add the dependency**

Add a reference to `Microsoft.AspNetCore.Http.Abstractions` if needed. It is already pulled in by `Microsoft.AspNetCore.Mvc.Core`. We need `Microsoft.AspNetCore.Builder.Abstractions` for `IApplicationBuilder`. Update the csproj package list — modify `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/Bse.Framework.Core.csproj`:

Inside the existing `<ItemGroup>` that references `Microsoft.AspNetCore.Mvc.Core`, add:

```xml
    <PackageReference Include="Microsoft.AspNetCore.Diagnostics.HealthChecks" />
```

And add the version to `/Users/mahrous/Projects/bse-framework/Directory.Packages.props` (already added in Task 2 — verify it's there).

- [ ] **Step 2: Implement the extensions**

Create `/Users/mahrous/Projects/bse-framework/src/Bse.Framework.Core/ExceptionHandling/ApplicationBuilderExtensions.cs`:

```csharp
using Microsoft.AspNetCore.Builder;

namespace Bse.Framework.Core.ExceptionHandling;

/// <summary>
/// Extension methods to register the framework's middleware in an ASP.NET Core pipeline.
/// </summary>
public static class ApplicationBuilderExtensions
{
    /// <summary>
    /// Adds the framework's exception handler middleware. Should be called as the first
    /// middleware in the pipeline so it catches everything downstream.
    /// </summary>
    public static IApplicationBuilder UseBseExceptionHandler(this IApplicationBuilder app)
    {
        ArgumentNullException.ThrowIfNull(app);
        return app.UseMiddleware<BseExceptionHandlerMiddleware>();
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
dotnet build
```

Expected: Build succeeded.

- [ ] **Step 4: Commit**

```bash
git add src/Bse.Framework.Core/ExceptionHandling/ApplicationBuilderExtensions.cs src/Bse.Framework.Core/Bse.Framework.Core.csproj
git commit -m "feat(core): add UseBseExceptionHandler application builder extension"
```

---

## Task 23: GitHub Actions CI

**Files:**
- Create: `/Users/mahrous/Projects/bse-framework/.github/workflows/ci.yml`

- [ ] **Step 1: Create the workflow file**

Create `/Users/mahrous/Projects/bse-framework/.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build-and-test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        dotnet: ['8.0.x', '9.0.x']
    steps:
      - uses: actions/checkout@v4

      - name: Setup .NET ${{ matrix.dotnet }}
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: ${{ matrix.dotnet }}

      - name: Restore dependencies
        run: dotnet restore

      - name: Build
        run: dotnet build --no-restore --configuration Release

      - name: Test
        run: dotnet test --no-build --configuration Release --logger "trx;LogFileName=test-results.trx" --collect:"XPlat Code Coverage"

      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: test-results-${{ matrix.dotnet }}
          path: '**/test-results.trx'

  vulnerability-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup .NET
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '9.0.x'

      - name: Restore
        run: dotnet restore

      - name: Check for vulnerable packages
        run: |
          dotnet list package --vulnerable --include-transitive 2>&1 | tee output.txt
          if grep -E "(High|Critical)" output.txt; then
            echo "Vulnerable packages found"
            exit 1
          fi
```

- [ ] **Step 2: Commit**

```bash
git add .github/
git commit -m "ci: add GitHub Actions workflow for build, test, and vulnerability scan"
```

---

## Task 24: Final Verification

- [ ] **Step 1: Clean rebuild**

```bash
cd /Users/mahrous/Projects/bse-framework
dotnet clean
dotnet build --configuration Release
```

Expected: Build succeeded with 0 warnings (`TreatWarningsAsErrors=true` in Directory.Build.props).

- [ ] **Step 2: Run all tests**

```bash
dotnet test --configuration Release
```

Expected: All tests pass. Total test count should be approximately 40 tests across:
- BseExceptionTests (5)
- BseValidationExceptionTests (4)
- ResultTests (5)
- ResultTTests (6)
- SystemClockTests (2)
- SequentialGuidGeneratorTests (3)
- BseFrameworkBuilderTests (4)
- ServiceCollectionExtensionsTests (7)
- BseLogScopesTests (2)
- DefaultRedactorTests (5)
- GracefulShutdownCoordinatorTests (3)
- BseHealthCheckExtensionsTests (4)
- BseProblemDetailsFactoryTests (5)
- BseExceptionHandlerMiddlewareTests (3)

- [ ] **Step 3: Pack the NuGet package**

```bash
dotnet pack src/Bse.Framework.Core/Bse.Framework.Core.csproj --configuration Release --output ./artifacts
```

Expected: `Bse.Framework.Core.0.1.0.nupkg` and `Bse.Framework.Core.0.1.0.snupkg` produced in `./artifacts`.

- [ ] **Step 4: Inspect the package contents**

```bash
unzip -l ./artifacts/Bse.Framework.Core.0.1.0.nupkg
```

Expected: contains `lib/net8.0/Bse.Framework.Core.dll`, `lib/net9.0/Bse.Framework.Core.dll`, `Bse.Framework.Core.nuspec`, `README.md`.

- [ ] **Step 5: Commit and tag the release**

```bash
git add artifacts/.gitignore 2>/dev/null || true
git commit --allow-empty -m "release: Bse.Framework.Core v0.1.0"
git tag bse.framework.core/v0.1.0
```

---

## Spec Self-Review (run after writing the plan)

The plan covers every Core responsibility from RFC-0001 and ADR-0001:

| Spec Item | Task |
|---|---|
| Project structure (src/, tests/, Directory.Build.props, Directory.Packages.props) | Tasks 1-4 |
| Base exception types | Tasks 5-6 |
| Result and Result<T> | Tasks 7-9 |
| ISystemClock for testable time | Task 10 |
| IGuidGenerator with B-tree friendly sequential generator | Task 11 |
| BseFrameworkBuilder + IBseModule pattern | Task 12 |
| AddBseFramework entry point with DI registration | Tasks 13, 21 |
| Logging scope helpers | Task 14 |
| Sensitive data redaction (replace/hash/drop) | Task 15 |
| Graceful shutdown coordinator | Task 16 |
| Health check aggregation | Task 17 |
| Problem Details exception handling middleware | Tasks 18-20, 22 |
| GitHub Actions CI with build, test, vulnerability scan | Task 23 |
| NuGet packaging | Tasks 3, 24 |

Items intentionally NOT in this plan (deferred to other plans):
- Multi-tenancy (RFC-0006, separate plan)
- Telemetry (RFC-0005, separate plan)
- RPC (RFC-0002, separate plan)
- Auth (RFC-0004, separate plan)
- Data access (RFC-0003, separate plan)

These are independent NuGet packages — Core is the foundation everything else builds on.
