import Foundation

/// Widget state for `--show-widget` screenshots.
enum WidgetDebugState: String, CaseIterable, Sendable {
    case recording
    case transcribing
    case enhancing
}

/// Headless CLI flags kept in Release (docs/architecture.md "Debug CLI flags").
enum DebugCommand: Sendable, Equatable {
    /// `--transcribe <file> [--ai] [--language pl] [--engine parakeet|cloud]`. `language` is the raw
    /// flag value (nil = use the app setting; "auto" is passed through and mapped by the runner);
    /// `engine` nil = the app setting (`--engine parakeet` never reads the Keychain without `--ai`).
    case transcribe(url: URL, ai: Bool, language: String?, engine: STTEngine? = nil)
    /// `--show-widget <recording|transcribing|enhancing>`
    case showWidget(WidgetDebugState)
    /// `--check`
    case check
    /// `--reset-onboarding`
    case resetOnboarding
    /// `--open-section <pulpit|spotkania|historia|plik|slownik|modele|ustawienia>` (hidden, for screenshots):
    /// a normal GUI launch that skips the onboarding and opens the main window on that section.
    case openSection(MainSection)
    /// `--design-preview <target>` (hidden, for design screenshots, see `DesignPreviewTarget`):
    /// one screen on fake data with no services (no hotkey tap, audio, model, store on disk).
    /// The raw target is kept as typed ("" when missing) so a typo fails loudly in the runner
    /// instead of falling through to a normal GUI launch with a second hotkey tap.
    case designPreview(String)
    /// `--import-legacy [--dry-run]`: imports the old VocaType history into the data folder
    /// (`CAPTYLO_DATA_DIR` or the real one) and prints the report; a dry run writes nothing.
    case importLegacy(dryRun: Bool)
    /// `--ax-probe [--show-text]` (hidden, self-learning spike): prints one JSON line whenever the
    /// focused text field changes (app, role, length, selection) until killed. The field text is
    /// printed only with `--show-text`, so a pasted probe log never carries it by accident.
    case axProbe(showText: Bool)
    /// `--watch-paste <text>` (hidden, self-learning check): pastes the text into the focused
    /// field like a dictation, watches it for edits and prints what was learned. Use with
    /// `CAPTYLO_DATA_DIR` so the learning lands in a scratch folder.
    case watchPaste(String)
    /// `--meeting-from-files <me-audio> <them-audio>`: the meeting transcription pipeline on two files
    /// instead of live capture (no mic, no system audio tap, in-memory store). `me` stands for the
    /// mic track and `them` for the system track; both start at meeting time 0.
    case meetingFromFiles(me: URL, them: URL)

    static let primaryFlags: [String] = [
        "--transcribe", "--show-widget", "--check", "--reset-onboarding", "--open-section", "--design-preview", "--import-legacy",
        "--ax-probe", "--watch-paste", "--meeting-from-files",
    ]

    /// Headless commands never start the services; all but `--open-section` go to `DebugRunner`.
    /// `--design-preview` shows windows too, but on fake services, so it counts as headless.
    var isHeadless: Bool {
        if case .openSection = self { return false }
        return true
    }

    /// Parses `CommandLine.arguments`. Tokens before the first known flag (the executable path,
    /// Xcode's own arguments) are ignored. Returns nil when no flag is present or it is malformed.
    static func parse(_ args: [String]) -> DebugCommand? {
        guard let start = args.firstIndex(where: { primaryFlags.contains($0) }) else { return nil }
        let rest = Array(args[(start + 1)...])
        switch args[start] {
        case "--check":
            return .check
        case "--reset-onboarding":
            return .resetOnboarding
        case "--show-widget":
            guard let raw = rest.first, let state = WidgetDebugState(rawValue: raw) else { return nil }
            return .showWidget(state)
        case "--open-section":
            // Accepts the raw value with or without Polish diacritics ("slownik", "Słownik").
            guard let raw = rest.first else { return nil }
            let key = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .replacingOccurrences(of: "ł", with: "l")
            guard let section = MainSection(rawValue: key) else { return nil }
            return .openSection(section)
        case "--design-preview":
            guard let raw = rest.first, !raw.hasPrefix("--") else { return .designPreview("") }
            return .designPreview(raw.lowercased())
        case "--import-legacy":
            return .importLegacy(dryRun: rest.contains("--dry-run"))
        case "--ax-probe":
            return .axProbe(showText: rest.contains("--show-text"))
        case "--watch-paste":
            guard let text = rest.first, !text.hasPrefix("--"), !text.isEmpty else { return nil }
            return .watchPaste(text)
        case "--transcribe":
            guard let path = rest.first, !path.hasPrefix("--"), !path.isEmpty else { return nil }
            var ai = false
            var language: String?
            var engine: STTEngine?
            var index = 1
            while index < rest.count {
                switch rest[index] {
                case "--ai":
                    ai = true
                case "--language":
                    guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--") else { return nil }
                    language = rest[index + 1]
                    index += 1
                case "--engine":
                    guard index + 1 < rest.count else { return nil }
                    switch rest[index + 1].lowercased() {
                    case "parakeet", "local": engine = .parakeet
                    case "cloud", "elevenlabs": engine = .elevenLabs
                    default: return nil
                    }
                    index += 1
                default:
                    break
                }
                index += 1
            }
            return .transcribe(url: fileURL(path), ai: ai, language: language, engine: engine)
        case "--meeting-from-files":
            let paths = rest.prefix(2)
            guard paths.count == 2, paths.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("--") }) else { return nil }
            return .meetingFromFiles(me: fileURL(paths[paths.startIndex]), them: fileURL(paths[paths.startIndex + 1]))
        default:
            return nil
        }
    }

    /// A file URL for a path typed on the command line (`~` expanded).
    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

/// Executes a parsed command headless: prints JSON to stdout and returns the exit code.
/// Wired by the integrator (`AppState.debugRunner`).
@MainActor
protocol DebugCommandRunner: AnyObject {
    func run(_ command: DebugCommand) async -> Int32
}
