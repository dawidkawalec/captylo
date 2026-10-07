import Foundation

/// Screens `--design-preview <target>` can show (docs/design/dusk-glass.md, `scripts/snap.sh`).
enum DesignPreviewTarget: String, CaseIterable, Sendable {
    case widgetCompact = "widget-compact"
    /// Compact widget recording with a rewrite mode on ("Po angielsku" under the waveform).
    case widgetCompactMode = "widget-compact-mode"
    case widgetExpanded = "widget-expanded"
    case widgetTranscribing = "widget-transcribing"
    /// Compact widget polishing with an AI mode ("Poprawiam z AI · Uporządkuj myśli").
    case widgetEnhancing = "widget-enhancing"
    case onboardingWelcome = "onboarding-welcome"
    case onboardingPermissions = "onboarding-permissions"
    case onboardingModel = "onboarding-model"
    case onboardingShortcut = "onboarding-shortcut"
    case onboardingTryIt = "onboarding-tryit"
    case mainPulpit = "main-pulpit"
    /// Spotkania with three sample meetings, the newest (AI notes, named speakers) selected.
    case mainSpotkania = "main-spotkania"
    /// Notatki with sample notes (one with a recording, one tidied by AI, one failed recording).
    case mainNotatki = "main-notatki"
    case mainHistoria = "main-historia"
    case mainPlik = "main-plik"
    case mainSlownik = "main-slownik"
    case mainModele = "main-modele"
    case mainUstawienia = "main-ustawienia"
    /// Every Glass component over the dusk wallpaper (the catalog in dusk-glass.md).
    case glassGallery = "glass-gallery"
    /// The "Popraw" panel (⌃⌥⌘P) with a fix that will be learned as a rule.
    case correction = "popraw"

    /// Space separated list for error messages.
    static var listing: String {
        allCases.map(\.rawValue).joined(separator: " ")
    }

    enum Kind: Equatable, Sendable {
        case widget(expanded: Bool, state: WidgetDebugState)
        case onboarding(OnboardingStep)
        case main(MainSection)
        case gallery
        case correction
    }

    var kind: Kind {
        switch self {
        case .widgetCompact, .widgetCompactMode: return .widget(expanded: false, state: .recording)
        case .widgetExpanded: return .widget(expanded: true, state: .recording)
        case .widgetTranscribing: return .widget(expanded: false, state: .transcribing)
        case .widgetEnhancing: return .widget(expanded: false, state: .enhancing)
        case .onboardingWelcome: return .onboarding(.welcome)
        case .onboardingPermissions: return .onboarding(.permissions)
        case .onboardingModel: return .onboarding(.model)
        case .onboardingShortcut: return .onboarding(.shortcut)
        case .onboardingTryIt: return .onboarding(.tryIt)
        case .mainPulpit: return .main(.pulpit)
        case .mainSpotkania: return .main(.spotkania)
        case .mainNotatki: return .main(.notatki)
        case .mainHistoria: return .main(.historia)
        case .mainPlik: return .main(.plik)
        case .mainSlownik: return .main(.slownik)
        case .mainModele: return .main(.modele)
        case .mainUstawienia: return .main(.ustawienia)
        case .glassGallery: return .gallery
        case .correction: return .correction
        }
    }

    /// AI mode the demo widget starts with; nil keeps the demo default (Czyszczenie).
    var widgetAIModeID: UUID? {
        self == .widgetCompactMode ? BuiltInAIModes.englishID : nil
    }

    /// Widget targets are captured with the window shadow (`snap.sh` leaves out `-o`).
    var isWidget: Bool {
        if case .widget = kind { return true }
        return false
    }
}
