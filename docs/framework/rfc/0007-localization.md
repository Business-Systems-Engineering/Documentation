# RFC-0007: Localization and Calendars

- **Status:** Implemented
- **Date:** 2026-07-05
- **Authors:** BSE Framework Team
- **Related ADRs:** ADR-0007
- **Related RFCs:** RFC-0001

---

## Abstract

This document is the as-built specification for the BSE localization subsystem. It covers the
`ICalendarProvider` abstraction, the two built-in implementations (Gregorian and Umm al-Qura
Hijri), the `BseDateOnly` value type that stores dates in canonical Gregorian form while
supporting per-call display in any registered calendar, the `CalendarRegistry` singleton that
provides O(1) provider lookup by identifier, and the `AsyncLocalCalendarContextAccessor` that
propagates an ambient calendar through async continuations without thread affinity. The design
draws on `System.Globalization.UmAlQuraCalendar` from the BCL and `System.DateOnly` from .NET 6+;
no third-party calendar library is required.

---

## Motivation

All three existing BSE applications (Stud2, SafePack2, Orange2) contain a copy of the same
`Tools.cs` file that re-implements Gregorian-Hijri conversion. Bug fixes and algorithm corrections
applied to one app do not propagate to the others, and the duplicated code has drifted. The BSE
customer base is primarily Arabic-speaking; Hijri date support is mandatory for date display,
document printing, and search filtering. The framework needs:

- A single, tested implementation of Umm al-Qura conversion to replace all three copies.
- A calendar-agnostic date type that keeps equality and arithmetic correct across calendar systems.
- An ambient calendar scope that lets middleware and handler code read "today in the tenant's
  calendar" without threading a provider through every call site.
- An open extension point so future calendars (Persian Solar Hijri, Hebrew, Buddhist) can be
  added as NuGet packages without modifying the core.

---

## Goals

- `ICalendarProvider` as the single seam between the framework and any calendar system.
- `BseDateOnly` stores dates in canonical Gregorian form so equality, comparison, and arithmetic
  are unambiguous across calendar systems.
- `HijriCalendarProvider` wraps the BCL `UmAlQuraCalendar` -- no external dependency, full BCL
  support range honoured.
- `CalendarRegistry` resolves any registered provider by string identifier in O(1) time.
- `AsyncLocalCalendarContextAccessor` propagates the active calendar through async continuations
  and isolates sibling tasks from one another.
- DI registration follows the framework's `AddBse*` builder pattern; the Hijri provider is opt-in
  via a separate NuGet package and a single `AddHijri()` call.
- Zero metrics, tracing, or logging emitted by the localization layer -- it is a pure computation
  library.

## Non-Goals

- Message and string localization (`IStringLocalizer<T>`, resource files, `.resx`). This package
  is calendars only; string localization is a separate concern.
- Calendar arithmetic in non-Gregorian systems (month addition, week-of-year calculation). Only
  round-trip conversion and ISO-style formatting are provided.
- Arabic text normalization and number/currency formatting -- those utilities remain in application
  code until a dedicated package is designed.
- Per-tenant automatic calendar injection from tenancy metadata. The `ICalendarContextAccessor`
  is the mechanism; wiring it to tenant properties is an application or future middleware concern.

---

## Design

### Overview

The subsystem is split into two NuGet packages that map to two C# projects:

| Package | Contents |
|---|---|
| `Bse.Framework.Localization` | `ICalendarProvider`, `BseDateOnly`, `GregorianCalendarProvider`, `CalendarRegistry`, `ICalendarContextAccessor`, `AsyncLocalCalendarContextAccessor`, DI extensions |
| `Bse.Framework.Localization.Hijri` | `HijriCalendarProvider`, `AddHijri()` DI extension |

`Bse.Framework.Localization.Hijri` depends on `Bse.Framework.Localization` and
`Microsoft.NETCore.App` only. No third-party packages are introduced by either project.

---

### ICalendarProvider

```csharp
// Bse.Framework.Localization.ICalendarProvider
public interface ICalendarProvider
{
    // Registry key; e.g. "gregorian", "umalqura".
    string Id { get; }

    // Converts calendar-system parts to a canonical Gregorian DateOnly.
    DateOnly ToGregorian(int calendarYear, int calendarMonth, int calendarDay);

    // Converts a Gregorian DateOnly to (Year, Month, Day) in this calendar system.
    (int Year, int Month, int Day) FromGregorian(DateOnly gregorian);

    // Formats a Gregorian date using this calendar's ISO-style representation (yyyy-MM-dd).
    string Format(DateOnly gregorian);
}
```

The contract is intentionally minimal. Implementations are not required to support month names,
week numbers, or leap-year predicates -- those can be layered on concrete types as needed. The
`Id` property doubles as the `CalendarRegistry` lookup key and must be stable across restarts.

---

### BseDateOnly

```csharp
// Bse.Framework.Localization.BseDateOnly
public readonly record struct BseDateOnly(DateOnly Gregorian)
{
    // UTC wall-clock date expressed as BseDateOnly.
    public static BseDateOnly UtcToday => new(DateOnly.FromDateTime(DateTime.UtcNow));

    // Constructs from calendar-system parts; conversion is delegated to the provider.
    public static BseDateOnly FromParts(ICalendarProvider calendar, int year, int month, int day);

    // Returns (Year, Month, Day) expressed in the given calendar system.
    public (int Year, int Month, int Day) PartsIn(ICalendarProvider calendar);

    // Returns the ISO-style string produced by calendar.Format.
    public string FormatIn(ICalendarProvider calendar);
}
```

`BseDateOnly` is a `readonly record struct` wrapping a single `DateOnly Gregorian` field. Because
`DateOnly` provides value equality and comparison, two `BseDateOnly` instances that represent the
same moment compare equal regardless of which calendar was used to construct them. Arithmetic is
performed directly on the underlying `DateOnly`; calendar conversion is explicit and only occurs
at the call sites of `FromParts`, `PartsIn`, and `FormatIn`.

---

### Calendar Providers

**GregorianCalendarProvider** (`Id "gregorian"`):

```csharp
// Bse.Framework.Localization.GregorianCalendarProvider
public sealed class GregorianCalendarProvider : ICalendarProvider
{
    public string Id => "gregorian";

    public DateOnly ToGregorian(int calendarYear, int calendarMonth, int calendarDay)
        => new DateOnly(calendarYear, calendarMonth, calendarDay);

    public (int Year, int Month, int Day) FromGregorian(DateOnly gregorian)
        => (gregorian.Year, gregorian.Month, gregorian.Day);

    public string Format(DateOnly gregorian)
        => gregorian.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
}
```

`DateOnly` is already proleptic Gregorian, so `ToGregorian` and `FromGregorian` are identity
operations -- no BCL `GregorianCalendar` allocation is involved.

**HijriCalendarProvider** (`Id "umalqura"`):

```csharp
// Bse.Framework.Localization.Hijri.HijriCalendarProvider
public sealed class HijriCalendarProvider : ICalendarProvider
{
    private static readonly UmAlQuraCalendar _calendar = new();

    public string Id => "umalqura";

    public DateOnly ToGregorian(int calendarYear, int calendarMonth, int calendarDay)
    {
        var dt = _calendar.ToDateTime(calendarYear, calendarMonth, calendarDay, 0, 0, 0, 0);
        return DateOnly.FromDateTime(dt);
    }

    public (int Year, int Month, int Day) FromGregorian(DateOnly gregorian)
    {
        var dt = gregorian.ToDateTime(TimeOnly.MinValue);
        return (_calendar.GetYear(dt), _calendar.GetMonth(dt), _calendar.GetDayOfMonth(dt));
    }

    public string Format(DateOnly gregorian)
    {
        var (year, month, day) = FromGregorian(gregorian);
        return $"{year:0000}-{month:00}-{day:00}";
    }
}
```

`UmAlQuraCalendar` is a BCL type (`System.Globalization`) that implements the Saudi Arabian
official Umm al-Qura algorithm. The static instance is used in read-only mode, which the BCL
guarantees is thread-safe. The format produced is ISO 8601-style in the Hijri parts, e.g.
`"1447-09-21"` for a date in Ramadan 1447.

---

### CalendarRegistry

```csharp
// Bse.Framework.Localization.CalendarRegistry (singleton)
public sealed class CalendarRegistry
{
    public CalendarRegistry(IEnumerable<ICalendarProvider> providers);

    // O(1) lookup; case-insensitive on Id.
    public bool TryGet(string id, out ICalendarProvider? provider);
}
```

The registry is built at construction time from all `ICalendarProvider` instances registered in
the DI container. Lookup is backed by a `Dictionary<string, ICalendarProvider>` with
`StringComparer.OrdinalIgnoreCase`. When two providers share an `Id`, the last one registered in
the DI container wins (consistent with `IEnumerable<T>` enumeration order for multiple singleton
registrations). The dictionary is written once and never mutated after construction, making all
concurrent `TryGet` calls allocation-free and lock-free.

---

### ICalendarContextAccessor

```csharp
// Bse.Framework.Localization.Accessor.ICalendarContextAccessor
public interface ICalendarContextAccessor
{
    // The provider active in the current async context. Never null; falls back to Gregorian.
    ICalendarProvider Current { get; }

    // Scopes calendar to the current async context.
    // Dispose the returned IDisposable to restore the previous provider.
    IDisposable Push(ICalendarProvider calendar);
}
```

The production implementation is `AsyncLocalCalendarContextAccessor`:

```csharp
// Bse.Framework.Localization.Accessor.AsyncLocalCalendarContextAccessor (singleton)
public sealed class AsyncLocalCalendarContextAccessor : ICalendarContextAccessor
{
    private static readonly AsyncLocal<ICalendarProvider?> _current = new();

    // Injected GregorianCalendarProvider is the fallback when _current.Value is null.
    public AsyncLocalCalendarContextAccessor(GregorianCalendarProvider defaultCalendar);

    public ICalendarProvider Current => _current.Value ?? _defaultCalendar;

    public IDisposable Push(ICalendarProvider calendar); // returns private RestoreScope
}
```

`AsyncLocal<T>` propagates to child tasks and async continuations while isolating siblings -- a
`Task.Run` body sees the value captured at the moment it was scheduled, not mutations made on the
calling thread after scheduling. `RestoreScope.Dispose` restores `_current.Value` to the value
it held before `Push` was called, enabling nested scopes without leakage.

---

### DI and Builder API

```csharp
// Entry point on IBseFrameworkBuilder
public static IBseFrameworkBuilder AddBseLocalization(
    this IBseFrameworkBuilder builder,
    Action<BseLocalizationBuilder>? configure = null);

// Registrations performed by AddBseLocalization (in order):
//   services.AddSingleton<GregorianCalendarProvider>()
//   services.AddSingleton<ICalendarProvider>(sp => sp.GetRequiredService<GregorianCalendarProvider>())
//   services.TryAddSingleton<CalendarRegistry>()
//   services.TryAddSingleton<ICalendarContextAccessor, AsyncLocalCalendarContextAccessor>()
//   configure?.Invoke(new BseLocalizationBuilder(builder))

// BseLocalizationBuilder -- registers additional ICalendarProvider singletons
public BseLocalizationBuilder AddCalendar<TCalendar>()
    where TCalendar : class, ICalendarProvider;

// AddHijri() -- extension method from Bse.Framework.Localization.Hijri
public static BseLocalizationBuilder AddHijri(this BseLocalizationBuilder builder);
```

`GregorianCalendarProvider` is registered both as a concrete type and as `ICalendarProvider` so
that `AsyncLocalCalendarContextAccessor` can accept it as a typed constructor parameter (avoiding
`IEnumerable<ICalendarProvider>` resolution ambiguity at injection time) while still appearing in
the registry enumeration. `AddCalendar<T>` uses `AddSingleton` -- not `TryAddSingleton` -- so
all calls accumulate in the `IEnumerable<ICalendarProvider>` that `CalendarRegistry` enumerates.

A typical registration for a service that requires Hijri date display:

```csharp
builder.Services.AddBseFramework(framework =>
{
    framework.AddBseLocalization(loc => loc.AddHijri());
});
```

A service that only needs Gregorian (the default) requires no configure callback:

```csharp
framework.AddBseLocalization();
```

---

### Data Flow

The following illustrates a Gregorian date stored as `BseDateOnly` and displayed in the ambient
calendar (Hijri, pushed by middleware before the handler runs):

```
1. Entity persists a DateOnly in UTC Gregorian:
       DateOnly stored = new DateOnly(2026, 3, 20)   // 20 Mar 2026

2. Domain model wraps it:
       BseDateOnly value = new BseDateOnly(stored)

3. Middleware pushes the tenant's calendar before the handler runs:
       using var scope = accessor.Push(hijriProvider);

4. Handler reads the ambient calendar and formats for display:
       ICalendarProvider cal = accessor.Current;     // HijriCalendarProvider
       string displayed = value.FormatIn(cal);       // "1447-09-21"

5. Middleware disposes the scope -- accessor.Current reverts to GregorianCalendarProvider.
```

Equality and comparisons between two `BseDateOnly` values at step 4 remain purely Gregorian and
are unaffected by the ambient calendar scope.

---

### Performance Considerations

- `CalendarRegistry.TryGet` is an `OrdinalIgnoreCase` dictionary lookup -- O(1), no allocation.
- `AsyncLocalCalendarContextAccessor.Current` reads a single `AsyncLocal<T>` slot -- O(1).
- `HijriCalendarProvider` uses a static `UmAlQuraCalendar` instance; conversion is backed by the
  BCL's internally cached look-up table and is O(1) per call.
- `BseDateOnly.FormatIn` allocates one string per call (the formatted output). There is no
  intermediate `StringBuilder` or additional heap allocation beyond the return value.

### Security Considerations

No cryptographic operations or user-supplied data is evaluated by the calendar layer. Calendar
identifiers sourced from external input (e.g. a tenant configuration property) must be resolved
through `CalendarRegistry.TryGet`; an unknown identifier returns `false` and callers should fall
back to Gregorian rather than throwing, to prevent a misconfigured tenant from blocking all date
operations.

### Observability

The localization package emits no metrics, traces, or log entries. Calendar conversion operations
are too fast and too frequent to instrument at the framework level. Application code may
instrument its own date-formatting paths as needed using the framework's telemetry primitives
(see RFC-0005).

---

### Testing Strategy

- **`Bse.Framework.Localization.Tests`** -- unit tests covering `BseDateOnly` construction,
  equality, and round-trip (`FromParts` -> `PartsIn` returns original parts); `GregorianCalendarProvider`
  format and conversion identity; `CalendarRegistry` case-insensitive lookup and last-wins
  collision behaviour; `AsyncLocalCalendarContextAccessor` push/restore nesting and async
  propagation isolation (parallel tasks do not observe each other's pushed providers); DI builder
  registration order and `TryAdd` idempotency.
- **`Bse.Framework.Localization.Hijri.Tests`** -- unit tests covering `HijriCalendarProvider`
  conversion against a set of known Gregorian-Hijri reference pairs, `Format` output shape,
  thread-safety of the static `UmAlQuraCalendar` instance, and `AddHijri()` DI registration.
  `BseDateOnlyHijriTests` exercises `FromParts` and `FormatIn` end-to-end against the Hijri
  provider.
- No integration tests are required; all operations are pure computation with no I/O.

---

## Migration Path

**From ad-hoc Hijri conversion in `Tools.cs`:**

1. Add a package reference to `Bse.Framework.Localization.Hijri`.
2. Call `AddBseLocalization(loc => loc.AddHijri())` in the host setup.
3. Replace `Tools.GetHijriDate(date)` call sites. Given an existing Gregorian `DateOnly`:
   ```csharp
   var value = new BseDateOnly(gregorianDateOnly);
   var (year, month, day) = value.PartsIn(hijriProvider);
   string formatted = value.FormatIn(hijriProvider); // "yyyy-MM-dd" in Hijri parts
   ```
4. To construct from Hijri parts (e.g. user input):
   ```csharp
   BseDateOnly value = BseDateOnly.FromParts(hijriProvider, 1447, 9, 15);
   ```
5. Delete the old Hijri logic from `Tools.cs` after verifying conversion parity against the
   existing known-good test vectors.

**From `DateTime`-based Hijri code:** wrap the Gregorian `DateTime` as
`DateOnly.FromDateTime(dt)` before constructing `BseDateOnly`. The type does not wrap `DateTime`
directly; callers extract the `DateOnly` component first.

---

## Open Questions

**Per-tenant ambient calendar injection.** Wiring `ICalendarContextAccessor.Push` to a tenant's
configured calendar identifier (stored in tenancy metadata as a string key) is a middleware or
pipeline concern. No built-in middleware exists yet; teams that need it can implement a thin
middleware or `IRpcEnvelopeScope` that resolves the provider from `CalendarRegistry` and calls
`Push` for the lifetime of the request.

**Additional calendar systems.** `HijriCalendarProvider` is the only non-Gregorian provider
shipped. The `AddCalendar<T>()` extension point is the designated seam for future packages.
`System.Globalization` ships `PersianCalendar`, `HebrewCalendar`, and `ThaiBuddhistCalendar`
which could each be wrapped in a dedicated plugin package using the same pattern.

**String and message localization.** This package covers calendars only. A future
`Bse.Framework.Localization.Strings` package backed by standard `IStringLocalizer<T>` is the
natural extension but has not been designed. The two concerns are intentionally decoupled:
calendar-aware date formatting does not require localized strings, and vice versa.

---

## References

- [System.Globalization.UmAlQuraCalendar (.NET)](https://learn.microsoft.com/en-us/dotnet/api/system.globalization.umalquracalendar)
- [System.DateOnly (.NET 6+)](https://learn.microsoft.com/en-us/dotnet/api/system.dateonly)
- [AsyncLocal\<T\> -- value propagation through async continuations](https://learn.microsoft.com/en-us/dotnet/api/system.threading.asynclocal-1)
- ADR-0007: Localization and Calendar Abstractions
- RFC-0001: Framework Overview and In-Memory Testing Rig
- RFC-0006: Multi-Tenancy (ambient context pattern reused by `ICalendarContextAccessor`)
