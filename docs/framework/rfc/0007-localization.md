# RFC-0007: Localization

- **Status:** Approved
- **Date:** 2026-04-06
- **Related ADRs:** ADR-0007
- **Related RFCs:** RFC-0001

## Abstract

The framework provides a pluggable `ICalendarProvider` abstraction in the core localization package, with calendar implementations as separate plugin packages. The default Gregorian provider ships with the core; the Hijri (Islamic) calendar plugin is a separate `Bse.Framework.Localization.Hijri` package. The design consolidates the duplicated Hijri conversion logic across Stud2, SafePack2, and Orange2 into a single tested implementation, while keeping the framework core culture-neutral and extensible to other calendars (Persian, Hebrew, Buddhist).

## Motivation

All three existing BSE apps duplicate the same `Tools.cs` file containing:
- Hijri (Islamic) calendar conversion logic (Gregorian ↔ Hijri)
- Arabic text normalization (e.g., normalizing Alif variants, removing diacritics)
- Date formatting utilities
- Number formatting

This logic is hundreds of lines per app. Bug fixes get applied in one app but not the others. The BSE customer base is primarily Arabic-speaking, so Hijri date support is mandatory.

The framework needs to handle Hijri dates as first-class citizens while remaining culture-neutral at the core to support future expansion (Persian for Iran, Hebrew for Israel, Buddhist for Thailand).

## Goals

- Single source of truth for Hijri conversion (consolidated from three apps)
- Culture-neutral core framework
- Extensible to other calendars without changing the core
- Consistent API across all calendar implementations
- Per-tenant calendar selection (some tenants use Gregorian only, others Hijri-first)
- Arabic text utilities consolidated
- Date formatting integrated with .NET's `CultureInfo` system

## Non-Goals

- Replacing .NET's `System.Globalization` (we wrap it where useful)
- Full i18n string translation (separate concern, use `IStringLocalizer<T>`)
- Calendar arithmetic in arbitrary calendars (just conversion + display)

## Design

### Bse.Framework.Localization (Core Abstractions)

```csharp
public interface ICalendarProvider
{
    string Name { get; }                    // "gregorian", "hijri", "persian"
    string DisplayName { get; }             // "Gregorian Calendar", "Islamic Calendar"

    // Conversion
    DateTime ToGregorian(int year, int month, int day);
    DateTime ToGregorian(int year, int month, int day, int hour, int minute, int second);
    (int year, int month, int day) FromGregorian(DateTime gregorian);
    CalendarDate FromGregorianAsDate(DateTime gregorian);

    // Calendar info
    int DaysInMonth(int year, int month);
    int DaysInYear(int year);
    int MonthsInYear(int year);
    bool IsLeapYear(int year);
    int GetWeekOfYear(int year, int month, int day);
    DayOfWeek GetDayOfWeek(int year, int month, int day);

    // Formatting
    string FormatDate(DateTime date, string format, CultureInfo culture);
    string FormatDate(CalendarDate date, string format, CultureInfo culture);

    // Month/day names
    string GetMonthName(int month, CultureInfo culture);
    string GetAbbreviatedMonthName(int month, CultureInfo culture);
    string GetDayName(DayOfWeek day, CultureInfo culture);
}

public record CalendarDate(string Calendar, int Year, int Month, int Day);

public interface ICalendarRegistry
{
    ICalendarProvider GetProvider(string calendarName);
    ICalendarProvider GetDefault();
    IEnumerable<ICalendarProvider> GetAllProviders();
}
```

### Default Gregorian Provider (Built-In)

The core package ships with `GregorianCalendarProvider`, which delegates to .NET's `System.Globalization.GregorianCalendar`. Always available, always registered.

### Bse.Framework.Localization.Hijri (Plugin)

Optional NuGet package providing `HijriCalendarProvider`. Wraps .NET's `System.Globalization.HijriCalendar` and `UmAlQuraCalendar` (for Saudi Arabia's official Um Al-Qura calendar).

```csharp
services.AddBseLocalization(loc => {
    loc.UseHijri();
    loc.UseHijri(adjustment: 0);  // Hijri adjustment (-2 to +2 days for moon sighting)
});
```

The package consolidates:
- Hijri ↔ Gregorian conversion (algorithmic + Um Al-Qura table-based)
- Arabic month names (محرم، صفر، ربيع الأول...)
- Hijri date formatting (e.g., "15 رمضان 1447")
- Hijri week-of-year calculation
- Leap year handling for Hijri
- Edge cases (calendar reform dates, missing days)

### Per-Tenant Calendar Selection

Tenants can specify their default calendar:

```csharp
services.AddBseMultiTenancy(tenancy => {
    tenancy.PerTenantOptions<LocalizationOptions>((options, tenantInfo) => {
        options.DefaultCalendar = tenantInfo.Properties["Calendar"]?.ToString() ?? "gregorian";
        options.DefaultCulture = tenantInfo.Properties["Culture"]?.ToString() ?? "en-US";
    });
});
```

Different tenants can use different calendars without code changes.

### JSON Serialization

`CalendarDate` serializes as a structured object:

```json
{
  "calendar": "hijri",
  "year": 1447,
  "month": 9,
  "day": 15
}
```

A custom `JsonConverter<CalendarDate>` handles serialization. The framework also provides converters for `DateTime` that include both Gregorian and Hijri representations when configured per-tenant:

```json
{
  "gregorian": "2026-04-06",
  "hijri": {
    "year": 1447,
    "month": 9,
    "day": 15
  }
}
```

### Model Binding

ASP.NET Core model binders convert query/form/JSON Hijri dates to .NET `DateTime`:

```csharp
[HttpGet]
public IActionResult GetTransactions(
    [FromQuery] DateTime fromDate,   // Auto-converts Hijri input to Gregorian
    [FromQuery] DateTime toDate)
{
    // Logic uses Gregorian internally, formats Hijri for display
}
```

### Arabic Text Utilities

The Hijri package also includes Arabic text utilities consolidated from the three apps:

```csharp
public interface IArabicTextNormalizer
{
    string Normalize(string input);              // Normalizes Alif variants, removes diacritics
    string RemoveDiacritics(string input);       // Removes Tashkeel
    string NormalizeAlif(string input);          // أ إ آ → ا
    string NormalizeYa(string input);            // ي ى → ي
    string NormalizeTaMarbuta(string input);     // ة → ه (search-friendly)
    bool IsArabic(string input);
}
```

### Number Formatting

Eastern Arabic numerals (٠١٢٣٤٥٦٧٨٩) vs Western Arabic numerals (0123456789):

```csharp
public interface INumberFormatter
{
    string Format(decimal value, NumberStyle style);
    decimal Parse(string input);
}

public enum NumberStyle
{
    Western,        // 0123456789
    EasternArabic   // ٠١٢٣٤٥٦٧٨٩
}
```

### Money Formatting

Arabic-aware currency formatting:
```csharp
public interface IMoneyFormatter
{
    string Format(decimal amount, string currencyCode, CultureInfo culture);
    // EGP: "1,234.56 ج.م" (ar-EG)
    // SAR: "1,234.56 ر.س" (ar-SA)
}
```

### Configuration

```csharp
services.AddBseLocalization(loc => {
    loc.DefaultCalendar = "gregorian";   // or "hijri"
    loc.DefaultCulture = "ar-SA";
    loc.UseHijri(adjustment: 0);          // Register Hijri provider
});
```

### Extension Methods (Convenience)

```csharp
// Easy conversion from anywhere
public static class DateTimeExtensions
{
    public static CalendarDate ToHijri(this DateTime date)
        => HijriCalendarProvider.Instance.FromGregorianAsDate(date);

    public static DateTime FromHijri(int year, int month, int day)
        => HijriCalendarProvider.Instance.ToGregorian(year, month, day);
}

// Usage:
var today = DateTime.UtcNow;
var hijri = today.ToHijri();
Console.WriteLine($"{hijri.Day} {hijri.Month} {hijri.Year}");  // "15 9 1447"
```

## Migration Path

### Phase 1: Replace `Tools.cs` Hijri Logic

1. Add `Bse.Framework.Localization.Hijri` package to existing app
2. Replace `Tools.GetHijriDate(...)` calls with `IHijriCalendarProvider.FromGregorian(...)`
3. Delete old Hijri code from `Tools.cs`
4. Run regression tests to verify identical output

### Phase 2: Replace Arabic Text Utilities

1. Replace `Tools.NormalizeArabic(...)` with `IArabicTextNormalizer.Normalize(...)`
2. Delete old Arabic utilities from `Tools.cs`

### Phase 3: Adopt Per-Tenant Calendar

1. Add `Calendar` property to tenant config
2. Tenants can configure Hijri-first or Gregorian-first display
3. Update API responses to include both representations when needed

## Performance Considerations

- All calendar providers are thread-safe singletons
- Conversion operations are O(1) for Gregorian, O(1) for algorithmic Hijri, O(log n) for table-based Um Al-Qura
- Month/day names cached per culture
- No allocations on the hot path

## Testing Strategy

- Unit tests with thousands of known Gregorian↔Hijri conversion pairs
- Edge cases: leap years, month boundaries, calendar reform dates
- Property-based tests: round-trip conversion always returns original
- Cross-validate algorithmic Hijri against Um Al-Qura table
- Test against existing app logic to ensure migration parity

## Future Work

- `Bse.Framework.Localization.Persian` (Iranian Solar Hijri calendar)
- `Bse.Framework.Localization.Hebrew`
- `Bse.Framework.Localization.Buddhist`
- Full string localization via `IStringLocalizer<T>` integration
- Per-tenant resource files for translated strings

## References

- ADR-0007
- .NET `System.Globalization.HijriCalendar`
- .NET `System.Globalization.UmAlQuraCalendar`
- Existing Hijri logic in Stud2/SafePack2/Orange2 `Tools.cs`
