import Foundation
import Observation

/// Typed, observable wrapper over `UserDefaults` (brief 4.10, trimmed to the rewrite decisions).
/// Every getter registers with the observation system, so SwiftUI views re-render on change.
@MainActor
@Observable
final class AppSettings {
    enum Key: String, CaseIterable, Sendable {
        case hotkey
        case language
        case sttEngine
        case livePreview
        case aiEnabled = "ai.enabled"
        case aiModel = "ai.model"
        case aiPrompt = "ai.prompt"
        case aiModes = "ai.modes"
        case aiActiveModeID = "ai.activeModeID"
        case micSelection = "mic.selection"
        case sounds
        case muteWhileRecording
        case restoreClipboard
        case trailingSpace
        case paragraphs
        case saveHistory
        case learningEnabled = "learning.enabled"
        case learningNotifications = "learning.notifications"
        case learningExcludedApps = "learning.excludedApps"
        case menuBarOnly
        case windowBackground = "ui.windowBackground"
        case backgroundDim = "ui.backgroundDim"
        case panelSmoke = "ui.panelSmoke"
        case audioRetentionDays
        case onboardingStep = "onboarding.step"
        case onboardingDone = "onboarding.done"
        case dashboardRange = "dashboard.range"
        case dashboardMode = "dashboard.mode"
        case dashboardMetric = "dashboard.metric"
        case supportCardHiddenUntil = "supportCard.hiddenUntil"
        case openRouterModelsCache = "openRouter.modelsCache"
        case openRouterModelsCachedAt = "openRouter.modelsCachedAt"
        case devPro = "dev.pro"
        case meetingsAutoDetect = "meetings.autoDetect"
        case meetingsConsentReminder = "meetings.consentReminder"
        case meetingAudioRetention = "meetings.audioRetention"
        case meetingsShortcut = "meetings.shortcut"
        case meetingsCloudTranscript = "meetings.cloudTranscript"
        case meetingsAICorrection = "meetings.aiCorrection"
        case meetingsAIModel = "meetings.aiModel"
        case meetingsCalendar = "meetings.calendar"
        case meetingsCalendarReminder = "meetings.calendarReminder"
        case meetingsCalendarReminderMinutes = "meetings.calendarReminderMinutes"
        case meetingsCalendarPromptDismissed = "meetings.calendarPromptDismissed"
        case meetingsVoiceProcessing = "meetings.voiceProcessing"
        case meetingsMCP = "meetings.mcp"
        case accountCache = "account.cache"
        case accountRefreshedAt = "account.refreshedAt"
    }

    /// Every persisted key, for tests and diagnostics.
    nonisolated static let keys: [Key] = Key.allCases

    nonisolated static let defaultLanguage = "pl"
    nonisolated static let defaultOnboardingStep = "welcome"
    nonisolated static let defaultDashboardRange = 14
    /// "Przypominaj przed spotkaniem": minutes before the event (0 = "W chwili startu").
    nonisolated static let calendarReminderMinuteOptions = [0, 1, 2, 5]
    nonisolated static let defaultCalendarReminderMinutes = 1

    @ObservationIgnored private let defaults: UserDefaults
    /// Bumped by `reset()` so every observer refreshes at once.
    private var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Hotkey and speech

    var hotkey: Hotkey {
        get { track(\.hotkey); return decode(Hotkey.self, .hotkey) ?? .rightOption }
        set { withMutation(keyPath: \.hotkey) { encode(newValue, .hotkey) } }
    }

    /// ISO code or `TranscriptionLanguages.auto`.
    var language: String {
        get { track(\.language); return string(.language, default: Self.defaultLanguage) }
        set { withMutation(keyPath: \.language) { defaults.set(newValue, forKey: Key.language.rawValue) } }
    }

    /// `language` as the engines expect it (nil = auto detect).
    var transcriptionLanguage: String? { TranscriptionLanguages.engineCode(for: language) }

    var sttEngine: STTEngine {
        get { track(\.sttEngine); return STTEngine(rawValue: string(.sttEngine, default: "")) ?? .local }
        set { withMutation(keyPath: \.sttEngine) { defaults.set(newValue.rawValue, forKey: Key.sttEngine.rawValue) } }
    }

    var livePreview: Bool {
        get { track(\.livePreview); return bool(.livePreview, default: true) }
        set { withMutation(keyPath: \.livePreview) { defaults.set(newValue, forKey: Key.livePreview.rawValue) } }
    }

    // MARK: AI cleanup

    var aiEnabled: Bool {
        get { track(\.aiEnabled); return bool(.aiEnabled, default: false) }
        set { withMutation(keyPath: \.aiEnabled) { defaults.set(newValue, forKey: Key.aiEnabled.rawValue) } }
    }

    var aiModel: String {
        get { track(\.aiModel); return string(.aiModel, default: OpenRouterModel.defaultID) }
        set { withMutation(keyPath: \.aiModel) { defaults.set(newValue, forKey: Key.aiModel.rawValue) } }
    }

    /// Legacy single prompt from before "Tryby AI". Empty string = the default template. Only
    /// read by the one-time migration into `aiModes` ("Mój prompt"); the dictation path uses
    /// `activeMode`.
    var aiPrompt: String {
        get { track(\.aiPrompt); return string(.aiPrompt, default: "") }
        set { withMutation(keyPath: \.aiPrompt) { defaults.set(newValue, forKey: Key.aiPrompt.rawValue) } }
    }

    /// Legacy: the old single prompt or the default one. Not used for dictation any more.
    var aiPromptTemplate: String { aiPrompt.isEmpty ? CleanupPrompt.defaultTemplate : aiPrompt }

    // MARK: AI modes ("Tryby AI")

    /// The AI modes in display order. Until the list is first saved it is computed: the
    /// built-ins, plus "Mój prompt" when the old `ai.prompt` holds a custom prompt (the
    /// migration happens once, on the first change, because the list is then stored).
    var aiModes: [AIMode] {
        get {
            track(\.aiModes)
            if let stored = decode([AIMode].self, .aiModes), !stored.isEmpty {
                return stored
            }
            return Self.initialModes(legacyPrompt: defaults.string(forKey: Key.aiPrompt.rawValue))
        }
        set { withMutation(keyPath: \.aiModes) { encode(newValue, .aiModes) } }
    }

    /// Id of the mode used for dictation. Defaults to "Czyszczenie", or to "Mój prompt" when
    /// the old custom prompt was migrated. May point at a deleted mode: read `activeMode`.
    var aiActiveModeID: UUID {
        get {
            track(\.aiActiveModeID)
            if let raw = defaults.string(forKey: Key.aiActiveModeID.rawValue), let id = UUID(uuidString: raw) {
                return id
            }
            return Self.migratedPrompt(defaults.string(forKey: Key.aiPrompt.rawValue)) == nil
                ? BuiltInAIModes.cleanupID
                : BuiltInAIModes.migratedPromptID
        }
        set { withMutation(keyPath: \.aiActiveModeID) { defaults.set(newValue.uuidString, forKey: Key.aiActiveModeID.rawValue) } }
    }

    /// The mode used for dictation and files: the active one, else "Czyszczenie", else the first.
    var activeMode: AIMode {
        let modes = aiModes
        let id = aiActiveModeID
        return modes.first { $0.id == id }
            ?? modes.first { $0.builtInKey == BuiltInAIModes.Key.cleanup }
            ?? modes.first
            ?? BuiltInAIModes.cleanup
    }

    func mode(id: UUID) -> AIMode? {
        aiModes.first { $0.id == id }
    }

    /// Appends a copy of `mode` as the user's own (fresh id, no built-in key, deadline clamped).
    @discardableResult
    func addMode(_ mode: AIMode = AIMode.newCustom()) -> AIMode {
        var added = mode
        added.id = UUID()
        added.builtInKey = nil
        added.deadlineSeconds = mode.clampedDeadlineSeconds
        aiModes.append(added)
        return added
    }

    /// Replaces the mode with the same id (its built-in key is kept). Unknown id: no change.
    func updateMode(_ mode: AIMode) {
        var modes = aiModes
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        var updated = mode
        updated.builtInKey = modes[index].builtInKey
        updated.deadlineSeconds = mode.clampedDeadlineSeconds
        modes[index] = updated
        aiModes = modes
    }

    /// Inserts a user-owned copy right after the original, named "<name> (kopia)".
    @discardableResult
    func duplicateMode(id: UUID) -> AIMode? {
        var modes = aiModes
        guard let index = modes.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = modes[index]
        copy.id = UUID()
        copy.builtInKey = nil
        copy.name = String(localized: "\(copy.name) (kopia)")
        modes.insert(copy, at: index + 1)
        aiModes = modes
        return copy
    }

    /// Removes a mode. The last one cannot be removed (returns false). Deleting the active
    /// mode makes "Czyszczenie" (or the first remaining mode) active.
    @discardableResult
    func deleteMode(id: UUID) -> Bool {
        var modes = aiModes
        guard modes.count > 1, let index = modes.firstIndex(where: { $0.id == id }) else { return false }
        let wasActive = activeMode.id == id
        modes.remove(at: index)
        aiModes = modes
        if wasActive {
            let next = modes.first { $0.builtInKey == BuiltInAIModes.Key.cleanup } ?? modes[0]
            aiActiveModeID = next.id
        }
        return true
    }

    /// `List.onMove` semantics: `toOffset` is the index before the move.
    func moveModes(fromOffsets source: IndexSet, toOffset destination: Int) {
        var modes = aiModes
        let moving = source.filter { modes.indices.contains($0) }.map { modes[$0] }
        guard !moving.isEmpty else { return }
        let insertAt = destination - source.filter { $0 < destination }.count
        for index in source.sorted(by: >) where modes.indices.contains(index) {
            modes.remove(at: index)
        }
        modes.insert(contentsOf: moving, at: min(max(0, insertAt), modes.count))
        aiModes = modes
    }

    /// Moves one mode up (negative) or down (positive), clamped to the list.
    func moveMode(id: UUID, by offset: Int) {
        var modes = aiModes
        guard let index = modes.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, index + offset), modes.count - 1)
        guard target != index else { return }
        let mode = modes.remove(at: index)
        modes.insert(mode, at: target)
        aiModes = modes
    }

    /// "Przywróć domyślne tryby": every built-in is put back with its shipped name, prompt,
    /// kind and deadline (in place when present, appended when deleted). The user's own modes
    /// stay untouched.
    func restoreDefaultModes() {
        var modes = aiModes
        for builtIn in BuiltInAIModes.all {
            if let index = modes.firstIndex(where: { $0.builtInKey == builtIn.builtInKey }) {
                var restored = builtIn
                restored.id = modes[index].id
                modes[index] = restored
            } else {
                modes.append(builtIn)
            }
        }
        aiModes = modes
    }

    /// Built-ins plus the migrated custom prompt, if any.
    nonisolated static func initialModes(legacyPrompt: String?) -> [AIMode] {
        var modes = BuiltInAIModes.all
        if let migrated = migratedPrompt(legacyPrompt) {
            modes.append(migrated)
        }
        return modes
    }

    /// "Mój prompt" for a non-empty `ai.prompt` that differs from the default template.
    nonisolated static func migratedPrompt(_ legacyPrompt: String?) -> AIMode? {
        guard let legacyPrompt else { return nil }
        let trimmed = legacyPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != CleanupPrompt.defaultTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return BuiltInAIModes.migratedPrompt(legacyPrompt)
    }

    // MARK: Audio

    var micSelection: AudioInputSelection {
        get { track(\.micSelection); return decode(AudioInputSelection.self, .micSelection) ?? .systemDefault }
        set { withMutation(keyPath: \.micSelection) { encode(newValue, .micSelection) } }
    }

    var sounds: Bool {
        get { track(\.sounds); return bool(.sounds, default: true) }
        set { withMutation(keyPath: \.sounds) { defaults.set(newValue, forKey: Key.sounds.rawValue) } }
    }

    var muteWhileRecording: Bool {
        get { track(\.muteWhileRecording); return bool(.muteWhileRecording, default: true) }
        set { withMutation(keyPath: \.muteWhileRecording) { defaults.set(newValue, forKey: Key.muteWhileRecording.rawValue) } }
    }

    // MARK: Output and text

    var restoreClipboard: Bool {
        get { track(\.restoreClipboard); return bool(.restoreClipboard, default: true) }
        set { withMutation(keyPath: \.restoreClipboard) { defaults.set(newValue, forKey: Key.restoreClipboard.rawValue) } }
    }

    var trailingSpace: Bool {
        get { track(\.trailingSpace); return bool(.trailingSpace, default: true) }
        set { withMutation(keyPath: \.trailingSpace) { defaults.set(newValue, forKey: Key.trailingSpace.rawValue) } }
    }

    var paragraphs: Bool {
        get { track(\.paragraphs); return bool(.paragraphs, default: true) }
        set { withMutation(keyPath: \.paragraphs) { defaults.set(newValue, forKey: Key.paragraphs.rawValue) } }
    }

    /// Snapshot for `TextDelivering.deliver` (restore delay is fixed at 2 s).
    var outputSettings: OutputSettings {
        OutputSettings(restoreClipboard: restoreClipboard, trailingSpace: trailingSpace)
    }

    // MARK: History and shell

    var saveHistory: Bool {
        get { track(\.saveHistory); return bool(.saveHistory, default: true) }
        set { withMutation(keyPath: \.saveHistory) { defaults.set(newValue, forKey: Key.saveHistory.rawValue) } }
    }

    /// "Ucz się z moich poprawek": off = no observation, no lessons, the dictionary stays as is.
    var learningEnabled: Bool {
        get { track(\.learningEnabled); return bool(.learningEnabled, default: true) }
        set { withMutation(keyPath: \.learningEnabled) { defaults.set(newValue, forKey: Key.learningEnabled.rawValue) } }
    }

    /// "Pokazuj powiadomienia o nauce": the "Zapamiętałem ... [Cofnij]" toasts (Słownik keeps the list either way).
    var learningNotifications: Bool {
        get { track(\.learningNotifications); return bool(.learningNotifications, default: true) }
        set { withMutation(keyPath: \.learningNotifications) { defaults.set(newValue, forKey: Key.learningNotifications.rawValue) } }
    }

    /// Bundle ids whose fields are never read back, on top of `EditWatcher.excludedBundleIDs`.
    var learningExcludedApps: [String] {
        get { track(\.learningExcludedApps); return decode([String].self, .learningExcludedApps) ?? [] }
        set { withMutation(keyPath: \.learningExcludedApps) { encode(newValue, .learningExcludedApps) } }
    }

    // MARK: Meetings

    /// DEBUG-only "Tryb Pro (dev)" until accounts exist (M4). Read through `ProAccess`.
    var devPro: Bool {
        get { track(\.devPro); return bool(.devPro, default: false) }
        set { withMutation(keyPath: \.devPro) { defaults.set(newValue, forKey: Key.devPro.rawValue) } }
    }

    /// "Wykrywaj spotkania": ask to record when a meeting app holds the mic.
    var meetingsAutoDetect: Bool {
        get { track(\.meetingsAutoDetect); return bool(.meetingsAutoDetect, default: true) }
        set { withMutation(keyPath: \.meetingsAutoDetect) { defaults.set(newValue, forKey: Key.meetingsAutoDetect.rawValue) } }
    }

    /// "Przypominaj o poinformowaniu uczestników": the consent card at every meeting start.
    var meetingsConsentReminder: Bool {
        get { track(\.meetingsConsentReminder); return bool(.meetingsConsentReminder, default: true) }
        set { withMutation(keyPath: \.meetingsConsentReminder) { defaults.set(newValue, forKey: Key.meetingsConsentReminder.rawValue) } }
    }

    /// "Zachowuj nagrania spotkań": how long `me.caf` / `them.caf` stay (transcripts always stay).
    var meetingAudioRetention: MeetingAudioRetention {
        get {
            track(\.meetingAudioRetention)
            return MeetingAudioRetention(rawValue: string(.meetingAudioRetention, default: MeetingAudioRetention.days7.rawValue)) ?? .days7
        }
        set { withMutation(keyPath: \.meetingAudioRetention) { defaults.set(newValue.rawValue, forKey: Key.meetingAudioRetention.rawValue) } }
    }

    /// "Skrót ⌃⌥⌘M": the system-wide shortcut that starts and ends a meeting recording.
    var meetingsShortcut: Bool {
        get { track(\.meetingsShortcut); return bool(.meetingsShortcut, default: true) }
        set { withMutation(keyPath: \.meetingsShortcut) { defaults.set(newValue, forKey: Key.meetingsShortcut.rawValue) } }
    }

    /// "Dokładniejszy transkrypt z chmury" (Pro): after a meeting both tracks go to the cloud
    /// engine and its transcript replaces the live one.
    var meetingsCloudTranscript: Bool {
        get { track(\.meetingsCloudTranscript); return bool(.meetingsCloudTranscript, default: false) }
        set { withMutation(keyPath: \.meetingsCloudTranscript) { defaults.set(newValue, forKey: Key.meetingsCloudTranscript.rawValue) } }
    }

    /// "Poprawiaj transkrypt przez AI" (Pro): after a meeting an AI model fixes misheard words,
    /// names and punctuation, line by line.
    var meetingsAICorrection: Bool {
        get { track(\.meetingsAICorrection); return bool(.meetingsAICorrection, default: false) }
        set { withMutation(keyPath: \.meetingsAICorrection) { defaults.set(newValue, forKey: Key.meetingsAICorrection.rawValue) } }
    }

    /// "Model AI do spotkań": the model of the transcript fixes and the AI notes; empty = the
    /// model chosen in Modele (`aiModel`). Read through `meetingAIModelID`.
    var meetingsAIModel: String {
        get { track(\.meetingsAIModel); return string(.meetingsAIModel, default: "") }
        set { withMutation(keyPath: \.meetingsAIModel) { defaults.set(newValue, forKey: Key.meetingsAIModel.rawValue) } }
    }

    /// The model the meeting AI calls use: `meetingsAIModel`, or Modele's when it is empty.
    var meetingAIModelID: String {
        meetingsAIModel.isEmpty ? aiModel : meetingsAIModel
    }

    /// "Kalendarz": name recordings after the calendar event, keep its participants, remind
    /// before a call. Off until the user turns it on after granting access (Free).
    var meetingsCalendar: Bool {
        get { track(\.meetingsCalendar); return bool(.meetingsCalendar, default: false) }
        set { withMutation(keyPath: \.meetingsCalendar) { defaults.set(newValue, forKey: Key.meetingsCalendar.rawValue) } }
    }

    /// "Nie teraz" on the "Połącz kalendarz" row in Spotkania: the row stays hidden (the switch
    /// in Ustawienia still works).
    var meetingsCalendarPromptDismissed: Bool {
        get { track(\.meetingsCalendarPromptDismissed); return bool(.meetingsCalendarPromptDismissed, default: false) }
        set { withMutation(keyPath: \.meetingsCalendarPromptDismissed) { defaults.set(newValue, forKey: Key.meetingsCalendarPromptDismissed.rawValue) } }
    }

    /// "Przypominaj przed spotkaniem": a toast shortly before an event with a call link.
    var meetingsCalendarReminder: Bool {
        get { track(\.meetingsCalendarReminder); return bool(.meetingsCalendarReminder, default: true) }
        set { withMutation(keyPath: \.meetingsCalendarReminder) { defaults.set(newValue, forKey: Key.meetingsCalendarReminder.rawValue) } }
    }

    /// Minutes before the event the reminder shows; only `calendarReminderMinuteOptions`, any
    /// other stored value reads as the default.
    var meetingsCalendarReminderMinutes: Int {
        get {
            track(\.meetingsCalendarReminderMinutes)
            let stored = int(.meetingsCalendarReminderMinutes, default: Self.defaultCalendarReminderMinutes)
            return Self.calendarReminderMinuteOptions.contains(stored) ? stored : Self.defaultCalendarReminderMinutes
        }
        set {
            let value = Self.calendarReminderMinuteOptions.contains(newValue) ? newValue : Self.defaultCalendarReminderMinutes
            withMutation(keyPath: \.meetingsCalendarReminderMinutes) {
                defaults.set(value, forKey: Key.meetingsCalendarReminderMinutes.rawValue)
            }
        }
    }

    /// "Redukcja echa (eksperymentalna)": Apple's voice processing on the meeting mic (echo
    /// cancellation, noise suppression). Read when a meeting starts, so a change applies to
    /// the next one.
    var meetingsVoiceProcessing: Bool {
        get { track(\.meetingsVoiceProcessing); return bool(.meetingsVoiceProcessing, default: false) }
        set { withMutation(keyPath: \.meetingsVoiceProcessing) { defaults.set(newValue, forKey: Key.meetingsVoiceProcessing.rawValue) } }
    }

    /// "Dostęp dla asystentów AI (MCP)": the `--mcp` process (`MCPServer`, started by the user's
    /// AI assistant) lists and serves its read-only tools only while this is on. That process
    /// reads it straight from the app's defaults domain at every call (`MCPServer.settingIsOn`).
    var meetingsMCP: Bool {
        get { track(\.meetingsMCP); return bool(.meetingsMCP, default: false) }
        set { withMutation(keyPath: \.meetingsMCP) { defaults.set(newValue, forKey: Key.meetingsMCP.rawValue) } }
    }

    var menuBarOnly: Bool {
        get { track(\.menuBarOnly); return bool(.menuBarOnly, default: false) }
        set { withMutation(keyPath: \.menuBarOnly) { defaults.set(newValue, forKey: Key.menuBarOnly.rawValue) } }
    }

    /// "Tło okna": what fills every window behind the panels.
    var windowBackground: WindowBackgroundStyle {
        get {
            track(\.windowBackground)
            return WindowBackgroundStyle(rawValue: string(.windowBackground, default: "")) ?? .defaultStyle
        }
        set { withMutation(keyPath: \.windowBackground) { defaults.set(newValue.rawValue, forKey: Key.windowBackground.rawValue) } }
    }

    /// "Przyciemnienie tła" in percent, clamped to `WindowTone.backgroundDimRange`.
    var backgroundDim: Int {
        get {
            track(\.backgroundDim)
            return clamp(int(.backgroundDim, default: WindowTone.standard.backgroundDim), WindowTone.backgroundDimRange)
        }
        set { withMutation(keyPath: \.backgroundDim) { defaults.set(clamp(newValue, WindowTone.backgroundDimRange), forKey: Key.backgroundDim.rawValue) } }
    }

    /// "Przydymienie paneli" in percent, clamped to `WindowTone.panelSmokeRange`.
    var panelSmoke: Int {
        get {
            track(\.panelSmoke)
            return clamp(int(.panelSmoke, default: WindowTone.standard.panelSmoke), WindowTone.panelSmokeRange)
        }
        set { withMutation(keyPath: \.panelSmoke) { defaults.set(clamp(newValue, WindowTone.panelSmokeRange), forKey: Key.panelSmoke.rawValue) } }
    }

    /// Both tone settings for the window environment (`\.windowTone`).
    var windowTone: WindowTone {
        WindowTone(backgroundDim: backgroundDim, panelSmoke: panelSmoke)
    }

    /// 0 = keep recordings forever (P1).
    var audioRetentionDays: Int {
        get { track(\.audioRetentionDays); return int(.audioRetentionDays, default: 0) }
        set { withMutation(keyPath: \.audioRetentionDays) { defaults.set(newValue, forKey: Key.audioRetentionDays.rawValue) } }
    }

    // MARK: Onboarding

    var onboardingStep: String {
        get { track(\.onboardingStep); return string(.onboardingStep, default: Self.defaultOnboardingStep) }
        set { withMutation(keyPath: \.onboardingStep) { defaults.set(newValue, forKey: Key.onboardingStep.rawValue) } }
    }

    var onboardingDone: Bool {
        get { track(\.onboardingDone); return bool(.onboardingDone, default: false) }
        set { withMutation(keyPath: \.onboardingDone) { defaults.set(newValue, forKey: Key.onboardingDone.rawValue) } }
    }

    // MARK: Dashboard

    /// Days in the trend chart: 7, 14 or 30.
    var dashboardRange: Int {
        get { track(\.dashboardRange); return int(.dashboardRange, default: Self.defaultDashboardRange) }
        set { withMutation(keyPath: \.dashboardRange) { defaults.set(newValue, forKey: Key.dashboardRange.rawValue) } }
    }

    var dashboardMode: TrendMode {
        get { track(\.dashboardMode); return TrendMode(rawValue: string(.dashboardMode, default: "")) ?? .daily }
        set { withMutation(keyPath: \.dashboardMode) { defaults.set(newValue.rawValue, forKey: Key.dashboardMode.rawValue) } }
    }

    var dashboardMetric: TrendMetric {
        get { track(\.dashboardMetric); return TrendMetric(rawValue: string(.dashboardMetric, default: "")) ?? .words }
        set { withMutation(keyPath: \.dashboardMetric) { defaults.set(newValue.rawValue, forKey: Key.dashboardMetric.rawValue) } }
    }

    // MARK: Support card

    /// "Ukryj" on the Pulpit support card hides it until this moment (nil = shown).
    var supportCardHiddenUntil: Date? {
        get { track(\.supportCardHiddenUntil); return defaults.object(forKey: Key.supportCardHiddenUntil.rawValue) as? Date }
        set { withMutation(keyPath: \.supportCardHiddenUntil) { defaults.set(newValue, forKey: Key.supportCardHiddenUntil.rawValue) } }
    }

    // MARK: OpenRouter model cache

    /// JSON-encoded `[OpenRouterModel]`, refreshed after `OpenRouterModel.cacheMaxAge`.
    var openRouterModelsCache: Data? {
        get { track(\.openRouterModelsCache); return defaults.data(forKey: Key.openRouterModelsCache.rawValue) }
        set { withMutation(keyPath: \.openRouterModelsCache) { defaults.set(newValue, forKey: Key.openRouterModelsCache.rawValue) } }
    }

    /// Thread-safe reader of the cached model list for actors (UserDefaults is thread-safe).
    var openRouterModelsCacheReader: @Sendable () -> Data? {
        nonisolated(unsafe) let defaults = self.defaults
        let key = Key.openRouterModelsCache.rawValue
        return { defaults.data(forKey: key) }
    }

    var openRouterModelsCachedAt: Date? {
        get { track(\.openRouterModelsCachedAt); return defaults.object(forKey: Key.openRouterModelsCachedAt.rawValue) as? Date }
        set { withMutation(keyPath: \.openRouterModelsCachedAt) { defaults.set(newValue, forKey: Key.openRouterModelsCachedAt.rawValue) } }
    }

    // MARK: Captylo account

    /// The last `/v1/me` answer as JSON (`AccountClient.encodeCache`), so the plan is known at
    /// launch before the network answers. Nil when signed out. The token lives in the Keychain.
    var accountCache: String? {
        get { track(\.accountCache); return defaults.string(forKey: Key.accountCache.rawValue) }
        set { withMutation(keyPath: \.accountCache) { setOrRemove(newValue, .accountCache) } }
    }

    /// When `accountCache` was last confirmed by the server, stored as seconds since 1970.
    var accountRefreshedAt: Date? {
        get {
            track(\.accountRefreshedAt)
            guard defaults.object(forKey: Key.accountRefreshedAt.rawValue) != nil else { return nil }
            return Date(timeIntervalSince1970: defaults.double(forKey: Key.accountRefreshedAt.rawValue))
        }
        set { withMutation(keyPath: \.accountRefreshedAt) { setOrRemove(newValue?.timeIntervalSince1970, .accountRefreshedAt) } }
    }

    // MARK: Reset

    /// Removes every key so the defaults above apply again.
    func reset() {
        for key in Key.allCases {
            defaults.removeObject(forKey: key.rawValue)
        }
        revision += 1
    }

    // MARK: Helpers

    private func track<Member>(_ keyPath: KeyPath<AppSettings, Member>) {
        access(keyPath: keyPath)
        _ = revision
    }

    private func bool(_ key: Key, default value: Bool) -> Bool {
        defaults.object(forKey: key.rawValue) == nil ? value : defaults.bool(forKey: key.rawValue)
    }

    private func int(_ key: Key, default value: Int) -> Int {
        defaults.object(forKey: key.rawValue) == nil ? value : defaults.integer(forKey: key.rawValue)
    }

    private func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func setOrRemove(_ value: Any?, _ key: Key) {
        if let value {
            defaults.set(value, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
    }

    private func string(_ key: Key, default value: String) -> String {
        defaults.string(forKey: key.rawValue) ?? value
    }

    private func decode<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        guard let data = defaults.data(forKey: key.rawValue) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T, _ key: Key) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key.rawValue)
    }
}
