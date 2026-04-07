# ADR-0007: Pluggable ICalendarProvider with Hijri Plugin

- **Status:** Accepted
- **Date:** 2026-04-06
- **Tags:** localization, calendar, internationalization

## Context

All three existing BSE apps (Stud2, SafePack2, Orange2) duplicate the same `Tools.cs` file containing Hijri (Islamic) calendar conversion logic, Arabic text normalization, and date formatting utilities. The Hijri calendar logic is hundreds of lines per app, with subtle bugs that get fixed in one app but not the others. The framework needs to handle Hijri dates as first-class citizens (the BSE customer base is primarily Arabic-speaking) while remaining culture-neutral at the core to support future expansion.

## Decision

Provide an **`ICalendarProvider` abstraction** in the core localization package, with **calendar implementations as separate plugin packages**. The default Gregorian provider ships with the core; the Hijri plugin is a separate `Bse.Framework.Localization.Hijri` package that opts in.

## Options Considered

### Option A: Built Into Framework Core
- **Pros:** First-class support, always available, no opt-in required
- **Cons:** Forces dependency on Hijri code for projects that don't need it, framework not culture-neutral

### Option B: Optional Plugin Package
- **Pros:** Keeps core culture-neutral, opt-in dependency
- **Cons:** No abstraction means each plugin reinvents the contract, hard to add other calendars (Persian, Buddhist, Hebrew)

### Option C: ICalendarProvider Abstraction + Hijri Plugin
- **Pros:** Core remains culture-neutral, Hijri is opt-in, extensible to other calendars (Persian, Hebrew, Buddhist), consistent contract for all calendar plugins
- **Cons:** Slightly more abstraction overhead, requires careful API design

## Rationale

The abstraction approach future-proofs the framework. BSE may expand to Persian-speaking markets (Iran), Hebrew calendars (Israel), or Buddhist calendars (Thailand). Each can implement `ICalendarProvider` without changing the core. The Hijri plugin consolidates the duplicated logic from all three existing apps into one well-tested implementation.

## Consequences

### Positive
- Eliminates duplication of Hijri logic across BSE apps
- Framework core remains culture-neutral
- Other calendars can plug in without changing the core
- Single source of truth for Hijri conversion (testable, maintainable)
- Consistent API across calendars

### Negative
- Slightly more abstraction surface
- Migration requires extracting and validating existing Hijri code
- Edge cases (leap years, calendar reform dates) need careful porting

### Neutral
- Default provider is Gregorian
- Can register multiple providers and select per-tenant

## ICalendarProvider Interface (Sketch)

```csharp
public interface ICalendarProvider
{
    string Name { get; }                            // "gregorian", "hijri", "persian"
    DateTime ToGregorian(int year, int month, int day);
    (int year, int month, int day) FromGregorian(DateTime gregorian);
    int DaysInMonth(int year, int month);
    int DaysInYear(int year);
    bool IsLeapYear(int year);
    string FormatDate(DateTime date, string format, CultureInfo culture);
}
```

## References

- RFC-0007: Localization
- ADR-0001: Modular Package Architecture
- Existing Hijri logic in Stud2/SafePack2/Orange2 `Tools.cs`
