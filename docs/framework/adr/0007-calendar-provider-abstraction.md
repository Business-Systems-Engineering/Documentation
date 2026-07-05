# ADR-0007: Pluggable ICalendarProvider

- **Status:** Accepted
- **Date:** 2026-04-06
- **Deciders:** BSE Framework Team
- **Tags:** localization, calendar, hijri

## Context

All three existing BSE apps (Stud2, SafePack2, Orange2) duplicate the same `Tools.cs` file
containing Hijri (Islamic) calendar conversion logic, Arabic text normalization, and date
formatting utilities. Bugs fixed in one app silently persist in the others. The BSE customer base
is primarily Arabic-speaking and Saudi/GCC-regulated, making Hijri dates first-class citizens
rather than an edge case.

The framework needed to:

- Consolidate duplicated Hijri logic into a single well-tested implementation.
- Keep the framework core culture-neutral so non-Arabic deployments carry no unnecessary
  dependencies.
- Store dates canonically in a single representation so equality, arithmetic, and sorting are
  calendar-agnostic.
- Allow ambient calendar selection without threading a provider through every call site.

## Decision

Provide an **`ICalendarProvider` abstraction** in `Bse.Framework.Localization` with three methods:
`ToGregorian` (calendar parts → `DateOnly`), `FromGregorian` (`DateOnly` → calendar parts tuple),
and `Format` (`DateOnly` → string in the calendar's display format). The canonical storage type
is **`BseDateOnly`** — a value type wrapping a Gregorian `DateOnly` internally — so two dates
constructed via different calendars that refer to the same moment compare equal.

The **Hijri provider** ships as a separate `Bse.Framework.Localization.Hijri` package.
`HijriCalendarProvider` wraps the BCL `UmAlQuraCalendar` (the official Saudi government calendar)
with no third-party dependencies. The static `UmAlQuraCalendar` instance is safe for concurrent
access in read-only mode.

Ambient calendar selection uses **`ICalendarContextAccessor`** (backed by `AsyncLocal<T>`,
matching the same pattern as `ITenantContextAccessor`). The default when no calendar has been
pushed is the registered `GregorianCalendarProvider`. The `CalendarRegistry` singleton indexes all
registered providers by `ICalendarProvider.Id` at construction time for O(1) lookup.

```csharp
// ICalendarProvider (Bse.Framework.Localization)
public interface ICalendarProvider
{
    string Id { get; }   // e.g. "gregorian", "umalqura"
    DateOnly ToGregorian(int calendarYear, int calendarMonth, int calendarDay);
    (int Year, int Month, int Day) FromGregorian(DateOnly gregorian);
    string Format(DateOnly gregorian);
}

// Canonical date wrapper — internally always Gregorian
public readonly record struct BseDateOnly(DateOnly Gregorian)
{
    public static BseDateOnly FromParts(ICalendarProvider calendar, int year, int month, int day);
    public (int Year, int Month, int Day) PartsIn(ICalendarProvider calendar);
    public string FormatIn(ICalendarProvider calendar);
}

// HijriCalendarProvider (Bse.Framework.Localization.Hijri)
public sealed class HijriCalendarProvider : ICalendarProvider
{
    private static readonly UmAlQuraCalendar _calendar = new();
    public string Id => "umalqura";
    public DateOnly ToGregorian(int y, int m, int d)
        => DateOnly.FromDateTime(_calendar.ToDateTime(y, m, d, 0, 0, 0, 0));
    public (int Year, int Month, int Day) FromGregorian(DateOnly gregorian) { ... }
    public string Format(DateOnly gregorian) { ... }   // → "1446-09-15" style
}
```

## Options Considered

### Option A: Store per-calendar dates natively
- **Pros:** Display is trivial; no conversion on read.
- **Cons:** Equality and arithmetic across calendar systems are ambiguous; DB column type and
  sorting semantics become calendar-dependent; migrations become complex when switching calendars.

### Option B: Hard-code Gregorian only
- **Pros:** Simple; no abstraction overhead.
- **Cons:** Forces Hijri conversion into application code, repeating the existing duplication
  problem; no extensibility to Persian, Hebrew, or Buddhist calendars.

### Option C: Canonical Gregorian storage + pluggable providers (chosen)
- **Pros:** Equality, arithmetic, and sorting are calendar-agnostic; BCL `DateOnly` is the storage
  type (no custom DB type); additional calendars plug in via `ICalendarProvider` without touching
  the core; core package carries no Hijri dependency.
- **Cons:** Conversion cost on every display/input; `BseDateOnly` is a new wrapper type teams must
  adopt; slightly more abstraction surface.

## Rationale

Canonical Gregorian storage eliminates the fundamental problem of multi-calendar arithmetic:
`BseDateOnly` comparisons and LINQ queries work correctly regardless of which calendar was used to
construct the value. The `ICalendarProvider` abstraction future-proofs expansion to Persian
(Iran), Hebrew (Israel), and Buddhist (Thailand) markets — each implements the same three-method
interface without any framework changes. The Hijri package consolidates the duplicated `Tools.cs`
logic from all three legacy apps into one BCL-backed, thread-safe implementation with a single
test suite.

`ICalendarContextAccessor`'s `AsyncLocal` ambient pattern means calendar selection propagates
through async continuations without parameter threading, consistent with how
`ITenantContextAccessor` works.

## Consequences

### Positive
- Eliminates duplication of Hijri logic across Stud2, SafePack2, and Orange2.
- Framework core (`Bse.Framework.Localization`) carries no Hijri-specific dependency.
- Other calendar systems plug in via `ICalendarProvider` without any framework change.
- `BseDateOnly` equality is always calendar-agnostic — safe to use as a dictionary key or in
  LINQ `Where` clauses.
- `HijriCalendarProvider` depends only on `UmAlQuraCalendar` from `System.Globalization` — zero
  additional NuGet packages.

### Negative
- Teams must adopt `BseDateOnly` and `ICalendarProvider` rather than raw `DateOnly`.
- Display and input paths require a conversion call (`FormatIn`, `FromParts`).
- Edge cases in `UmAlQuraCalendar` (calendar reform boundaries, leap-year rules) are inherited
  from the BCL and must be documented.

### Neutral
- Default provider is `GregorianCalendarProvider` (Id `"gregorian"`).
- Multiple providers can coexist and be selected per-tenant or per-request via
  `ICalendarContextAccessor.Push(provider)`.
- `CalendarRegistry` resolves providers by Id with last-registration-wins semantics, consistent
  with DI enumerable resolution order.

## References

- RFC-0007: Localization
- ADR-0001: Modular Package Architecture
- [`Bse.Framework.Localization/ICalendarProvider.cs`]
- [`Bse.Framework.Localization/BseDateOnly.cs`]
- [`Bse.Framework.Localization/CalendarRegistry.cs`]
- [`Bse.Framework.Localization.Hijri/HijriCalendarProvider.cs`]
- [`Bse.Framework.Localization/Accessor/ICalendarContextAccessor.cs`]
