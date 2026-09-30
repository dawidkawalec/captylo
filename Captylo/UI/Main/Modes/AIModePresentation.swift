import Foundation

// Labels of the "Tryby AI" UI (Modele screen and the mode editor sheet).

extension AIModeKind {
    /// Chip and segment title: "Czyszczenie" / "Przeróbka".
    var title: String {
        switch self {
        case .cleanup: return String(localized: "Czyszczenie")
        case .rewrite: return String(localized: "Przeróbka")
        }
    }

    /// One line under the "Rodzaj" picker of the editor.
    var explanation: String {
        switch self {
        case .cleanup:
            return String(localized: "Tylko poprawia: ten sam język i sens, długość zbliżona do dyktatu. Do 3 słów AI jest pomijane.")
        case .rewrite:
            return String(localized: "Przerabia tekst: tłumaczy, porządkuje, zmienia formę. Odrzucana jest tylko pusta lub ucięta odpowiedź.")
        }
    }

    var symbol: String {
        switch self {
        case .cleanup: return "checkmark.seal"
        case .rewrite: return "arrow.triangle.2.circlepath"
        }
    }
}

extension AIMode {
    /// "6 s", "2,5 s" (numbers in the UI language).
    static func secondsLabel(_ seconds: Double) -> String {
        let value = seconds.formatted(.number.precision(.fractionLength(0...1)).locale(AppLocale.current))
        return String(localized: "\(value) s")
    }

    /// "limit 6 s" under the name of a mode row.
    var limitLabel: String {
        let value = clampedDeadlineSeconds.formatted(.number.precision(.fractionLength(0...1)).locale(AppLocale.current))
        return String(localized: "limit \(value) s")
    }

    /// The shipped version of a built-in mode, nil for the user's own.
    var shippedVersion: AIMode? {
        builtInKey.flatMap { BuiltInAIModes.mode(forKey: $0) }
    }
}
