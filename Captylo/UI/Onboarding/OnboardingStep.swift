import Foundation

/// The five resumable onboarding steps (brief 1.1), persisted by raw value in
/// `AppSettings.onboardingStep` so a relaunch (for example after granting Accessibility)
/// continues where the user left off. Pure value logic; the views live in `OnboardingSteps`.
enum OnboardingStep: String, CaseIterable, Sendable, Identifiable {
    case welcome
    case permissions
    case model
    case shortcut
    case tryIt = "tryit"

    var id: String { rawValue }

    /// Resolves the persisted value; unknown or legacy strings restart at the first step.
    init(persisted rawValue: String) {
        self = OnboardingStep(rawValue: rawValue) ?? .welcome
    }

    /// Zero-based position in the flow.
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var isFirst: Bool { self == Self.allCases.first }
    var isLast: Bool { self == Self.allCases.last }

    /// The step after this one, nil on the last step.
    var next: OnboardingStep? {
        let cases = Self.allCases
        let following = index + 1
        return following < cases.count ? cases[following] : nil
    }

    /// The step before this one, nil on the first step.
    var previous: OnboardingStep? {
        index > 0 ? Self.allCases[index - 1] : nil
    }

    /// 0...1 fill of the progress bar: 1/5 on the first step, 1 on the last.
    var progress: Double {
        Double(index + 1) / Double(Self.allCases.count)
    }

    var title: String {
        switch self {
        case .welcome: return String(localized: "Witaj")
        case .permissions: return String(localized: "Uprawnienia")
        case .model: return String(localized: "Model")
        case .shortcut: return String(localized: "Skrót")
        case .tryIt: return String(localized: "Wypróbuj")
        }
    }

    var symbol: String {
        switch self {
        case .welcome: return "waveform"
        case .permissions: return "lock.shield"
        case .model: return "cpu"
        case .shortcut: return "keyboard"
        case .tryIt: return "text.cursor"
        }
    }
}
