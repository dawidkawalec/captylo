import Foundation

/// One input listed in the widget's Mikrofon menu.
struct RecorderMicrophone: Identifiable, Hashable, Sendable {
    /// Device UID.
    let id: String
    let name: String
}

/// What the expanded widget reads and changes besides the take itself: microphone, language,
/// AI mode, the two output switches and pause. Backed by `AppSettings` / `AudioDevices` /
/// `RecorderCoordinator` in the app (`RecorderAppControls`) and by in-memory state in the
/// design preview (`RecorderDemoControls`), so the preview never writes real settings.
@MainActor
protocol RecorderWidgetControls: AnyObject {
    var microphones: [RecorderMicrophone] { get }
    /// UID of the chosen input, nil for "Domyślny systemowy".
    var selectedMicrophoneID: String? { get }
    /// Name of the input the next take will use (the resolved device), nil when there is none.
    var currentMicrophoneName: String? { get }
    /// Persists the choice; nil = system default. Applies from the next take.
    func selectMicrophone(id: String?)

    /// `AppSettings.language` value: `TranscriptionLanguages.auto` or an ISO code.
    var language: String { get set }
    /// "Automatycznie kopiuj transkrypcję": the transcript stays on the clipboard
    /// (`AppSettings.restoreClipboard` inverted).
    var autoCopy: Bool { get set }
    /// "Zapisz transkrypcję po zakończeniu" (`AppSettings.saveHistory`).
    var saveTranscript: Bool { get set }

    /// "Tryb AI" menu: the modes in display order (`AppSettings.aiModes`).
    var aiModes: [AIMode] { get }
    /// The master switch (`AppSettings.aiEnabled`); false shows "Bez AI".
    var aiEnabled: Bool { get }
    /// The mode dictation uses while AI is on (`AppSettings.activeMode`).
    var activeAIMode: AIMode { get }
    /// Picks a mode (turns AI on) or, with nil, "Bez AI" (turns it off). The controller reads
    /// the mode when the take stops, so the choice applies to the running take too.
    func selectAIMode(id: UUID?)
    /// "Edytuj tryby...": opens the main window on Modele, where modes are added and edited.
    func openModes()

    /// "Pauza" / "Wznów".
    func togglePause()
}

/// Items and value of the "Tryb AI" menus (expanded widget and menu bar).
enum RecorderAIModeOptions {
    /// Value shown in the row: "Bez AI" or the active mode's name.
    @MainActor
    static func currentName(of controls: any RecorderWidgetControls) -> String {
        controls.aiEnabled ? controls.activeAIMode.name : String(localized: "Bez AI")
    }

    /// "Bez AI", then every mode, then "Edytuj tryby..."; the checkmark sits on "Bez AI" when AI
    /// is off, else on the active mode.
    @MainActor
    static func menuItems(for controls: any RecorderWidgetControls) -> [RecorderMenuItem] {
        let enabled = controls.aiEnabled
        let activeID = controls.activeAIMode.id
        var items = [
            RecorderMenuItem(
                id: "no-ai",
                title: String(localized: "Bez AI"),
                systemImage: "nosign",
                isChecked: !enabled,
                action: { controls.selectAIMode(id: nil) }
            ),
        ]
        for (index, mode) in controls.aiModes.enumerated() {
            items.append(RecorderMenuItem(
                id: mode.id.uuidString,
                title: mode.name,
                systemImage: mode.symbol,
                isChecked: enabled && mode.id == activeID,
                startsGroup: index == 0,
                action: { controls.selectAIMode(id: mode.id) }
            ))
        }
        items.append(RecorderMenuItem(
            id: "edit-modes",
            title: String(localized: "Edytuj tryby..."),
            systemImage: "slider.horizontal.3",
            startsGroup: true,
            action: { controls.openModes() }
        ))
        return items
    }

    /// Applies a "Tryb AI" choice to the settings: nil = "Bez AI" (`aiEnabled` off, the active
    /// mode is kept for later), a mode id = that mode active and AI on. An unknown id changes
    /// nothing.
    @MainActor
    static func select(id: UUID?, in settings: AppSettings) {
        guard let id else {
            settings.aiEnabled = false
            return
        }
        guard settings.mode(id: id) != nil else { return }
        settings.aiActiveModeID = id
        settings.aiEnabled = true
    }
}

/// The app's controls: settings, the device list and the dictation coordinator.
@MainActor
final class RecorderAppControls: RecorderWidgetControls {
    private let settings: AppSettings
    private let devices: AudioDevices
    private weak var coordinator: (any RecorderCoordinator)?
    private let onOpenModes: @MainActor () -> Void

    init(
        settings: AppSettings,
        devices: AudioDevices,
        coordinator: any RecorderCoordinator,
        openModes: @escaping @MainActor () -> Void = {}
    ) {
        self.settings = settings
        self.devices = devices
        self.coordinator = coordinator
        self.onOpenModes = openModes
    }

    var microphones: [RecorderMicrophone] {
        devices.inputs.map { RecorderMicrophone(id: $0.uid, name: $0.name) }
    }

    var selectedMicrophoneID: String? {
        if case .device(let uid, _) = devices.selection { return uid }
        return nil
    }

    var currentMicrophoneName: String? {
        devices.resolveInput()?.name
    }

    func selectMicrophone(id: String?) {
        // The running take keeps its device: `AppState.prewarmCapture` only rebuilds the engine
        // while idle, and `start()` resolves the device again for the next take.
        devices.select(id.flatMap { uid in devices.inputs.first { $0.uid == uid } })
    }

    var language: String {
        get { settings.language }
        set { settings.language = newValue }
    }

    var autoCopy: Bool {
        get { !settings.restoreClipboard }
        set { settings.restoreClipboard = !newValue }
    }

    var saveTranscript: Bool {
        get { settings.saveHistory }
        set { settings.saveHistory = newValue }
    }

    var aiModes: [AIMode] { settings.aiModes }
    var aiEnabled: Bool { settings.aiEnabled }
    var activeAIMode: AIMode { settings.activeMode }

    func selectAIMode(id: UUID?) {
        RecorderAIModeOptions.select(id: id, in: settings)
    }

    func openModes() {
        onOpenModes()
    }

    func togglePause() {
        coordinator?.togglePause()
    }
}

/// Languages of the Język transkrypcji menu: "Automatycznie" first, then the Parakeet languages
/// named in the UI language, sorted.
enum RecorderLanguageOptions {
    struct Option: Identifiable, Hashable, Sendable {
        let code: String
        let name: String
        var id: String { code }
    }

    static var all: [Option] {
        let locale = AppLocale.current
        let named = TranscriptionLanguages.codes.map { code in
            Option(code: code, name: name(for: code, locale: locale))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return [Option(code: TranscriptionLanguages.auto, name: String(localized: "Automatycznie"))] + named
    }

    /// "Polski", "Angielski", ... ("Automatycznie" for `auto`, the upper-cased code as a fallback).
    static func name(for code: String, locale: Locale = AppLocale.current) -> String {
        if code == TranscriptionLanguages.auto {
            return String(localized: "Automatycznie")
        }
        guard let raw = locale.localizedString(forLanguageCode: code), !raw.isEmpty else {
            return code.uppercased()
        }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}
