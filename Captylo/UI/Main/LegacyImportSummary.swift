import Foundation

/// Texts of the "Import ze starego VocaType" row. Counts use labels ("Transkrypcje: 10 258")
/// so no Polish plural form can come out wrong.
enum LegacyImportSummary {
    /// "Transkrypcje: 10 258 · słowa: 525 tys. · nagrania: 10 397"
    static func found(_ report: LegacyImportReport, locale: Locale = AppLocale.current) -> String {
        let rows = number(report.importableRows, locale: locale)
        let words = compactNumber(report.wordsFound, locale: locale)
        let recordings = number(report.recordingsFound, locale: locale)
        return String(localized: "Transkrypcje: \(rows) · słowa: \(words) · nagrania: \(recordings)")
    }

    /// "Dodane wpisy: 9 452 · z AI: 2 600 · nagrania: 9 430 · pominięte: 806"
    static func result(_ report: LegacyImportReport, locale: Locale = AppLocale.current) -> String {
        let added = number(report.imported, locale: locale)
        let ai = number(report.withAI, locale: locale)
        let audio = number(report.audioLinked, locale: locale)
        let skipped = number(
            report.skippedExisting + report.skippedDuplicate + report.skippedEmpty + report.skippedPrewarm,
            locale: locale
        )
        return String(localized: "Dodane wpisy: \(added) · z AI: \(ai) · nagrania: \(audio) · pominięte: \(skipped)")
    }

    /// Recordings that could not come over, nil when every one did.
    static func audioNote(_ report: LegacyImportReport, locale: Locale = AppLocale.current) -> String? {
        let without = report.audioMissing + report.audioNotLinkable + report.audioSkippedByRetention
        guard without > 0 else { return nil }
        return String(localized: "Wpisy bez nagrania (brak pliku, inny dysk lub limit usuwania): \(number(without, locale: locale))")
    }

    /// "Zaimportowano 26 wrz 2026, 14:03"
    static func importedAt(_ date: Date, locale: Locale = AppLocale.current) -> String {
        let text = date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
        return String(localized: "Zaimportowano \(text)")
    }

    /// "Importuję: 1 000 z 10 258"
    static func progress(processed: Int, total: Int, locale: Locale = AppLocale.current) -> String {
        String(localized: "Importuję: \(number(processed, locale: locale)) z \(number(total, locale: locale))")
    }

    // MARK: Numbers

    /// Grouped whole number ("10 258").
    static func number(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Up to 9 999 as is, then whole thousands ("525 tys."), then millions with one decimal.
    static func compactNumber(_ value: Int, locale: Locale) -> String {
        if value >= 1_000_000 {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 1
            let millions = formatter.string(from: NSNumber(value: Double(value) / 1_000_000)) ?? String(value / 1_000_000)
            return String(localized: "\(millions) mln")
        }
        if value >= 10_000 {
            let thousands = number(Int((Double(value) / 1_000).rounded()), locale: locale)
            return String(localized: "\(thousands) tys.")
        }
        return number(value, locale: locale)
    }
}
