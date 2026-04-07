# ADR-0001: Modular NuGet Package Architecture

- **Status:** Accepted
- **Date:** 2026-04-06
- **Tags:** architecture, packaging, framework

## Context

Three existing BSE applications (Stud2, SafePack2, Orange2) duplicate massive amounts of code: BaseController, BaseResponse, GenericRepository, UnitOfWork, SecuritySystem, Tools, Shared utilities, IocConfigurator, and APIResolver. Each app has 40-240 manual service registrations and 100-449 entities. Bug fixes and improvements must be applied three times. We need a unified framework that eliminates this duplication while supporting both greenfield projects and gradual migration of the existing apps.

## Decision

Build the framework as a set of focused NuGet packages following the **modular monolith framework** pattern, with strict separation between abstractions and implementations. Each application picks only the packages it needs.

## Options Considered

### Option A: Modular NuGet Package Framework
- **Pros:** Pick-and-choose packages, source generators eliminate boilerplate, transport abstraction allows in-process or distributed deployment, migration-friendly (one package at a time), single transport abstraction for in-process, Redis, or HTTP, NuGet packages are the natural .NET distribution mechanism
- **Cons:** More packages to version and publish, source generators add build complexity

### Option B: Opinionated App Host (Aspire-Style)
- **Pros:** Extremely simple onboarding via single builder, consistent across all apps
- **Cons:** Less flexible, hard to adopt incrementally for existing apps, heavier dependency footprint even for simple services

### Option C: Code-Gen CLI (Scaffolding-First)
- **Pros:** Full visibility into generated code, easy to customize per project
- **Cons:** Generated code drifts from templates over time, framework updates require re-scaffolding, doesn't actually solve duplication (copies code instead of sharing)

## Rationale

Approach A matches the patterns already used in Myriad and caaspay-core (library frameworks, not scaffolding tools). It enables incremental migration: SafePack2 can adopt only `Bse.Framework.Auth` first to replace DES encryption, then progressively adopt more packages. Source generators give us the automation benefits of Approach C without the drift problem. Approach B can be built ON TOP of Approach A later as a convenience layer.

## Consequences

### Positive
- Eliminates massive code duplication across BSE apps
- Each app pays only for packages it uses
- Migration path is gradual (no big-bang rewrite)
- Source generators eliminate manual repository/query/registration boilerplate
- Same patterns work for new and legacy apps
- Standard NuGet versioning and distribution

### Negative
- 16 packages to maintain (vs 1 monolithic)
- Source generators require careful packaging (netstandard2.0, analyzer folder)
- Cross-package version coordination required (Directory.Build.props)
- Higher upfront investment

### Neutral
- Approach 2 (App Host) remains a future option built on top
- Each package has its own README, tests, and CI gates

## References

- ABP Framework (Volo.Abp.* package structure)
- MassTransit (transport abstraction pattern)
- Microsoft.Extensions.* (abstractions vs implementations split)
- RFC-0001: Framework Overview
