import AppKit
import Foundation
import Observation
import os
import SwiftData

/// Composition root. Builds every service once and injects it; no singletons except `Log`.
/// `init` only constructs (safe for the headless debug commands); `startServices()` wires the
/// launch-time behaviour of a normal GUI run (tap, prewarm, retention, observers).
@MainActor
@Observable
final class AppState {
    let settings: AppSettings

    /// Files handed over by Finder "Otwórz za pomocą" before the main view existed (gotcha 63).
    var pendingOpenURLs: [URL] = []

    /// Parsed at launch from `CommandLine.arguments`; nil for a normal GUI launch.
    var debugCommand: DebugCommand?

    /// `--design-preview` run on fake services: never installs the hotkey tap or starts services.
    let isDesignPreview: Bool

    /// Shown once when the SwiftData store could not be opened (gotcha 80).
    private(set) var storeIsFallback: Bool

    // MARK: Services (order follows the dictation flow)

    @ObservationIgnored let stats: StatsTicker

    // Audio
    @ObservationIgnored let levelMeter: LevelMeter
    @ObservationIgnored let audioCapture: AudioCapture
    @ObservationIgnored let audioDevices: AudioDevices
    @ObservationIgnored let systemMute: SystemMute
    @ObservationIgnored let sounds: Sounds

    // Transcription
    @ObservationIgnored let localEngine: WhisperEngine
    @ObservationIgnored let modelStore: LocalModelStore
    @ObservationIgnored let livePreview: LivePreview
    @ObservationIgnored let keyStore: KeyStore
    @ObservationIgnored let elevenLabs: ElevenLabsSTT
    @ObservationIgnored let transcriptionRouter: TranscriptionRouter

    // AI cleanup
    @ObservationIgnored let openRouter: OpenRouterClient
    @ObservationIgnored let openRouterModels: OpenRouterModels
    @ObservationIgnored let enhancer: Enhancer
    /// Off the hot path ("Przetwórz przez AI", "Testuj tryb"): the file session, a 15 s
    /// deadline and the file token cap, with the same model as dictation.
    @ObservationIgnored let utilityEnhancer: Enhancer

    // Text and data
    @ObservationIgnored let dictionary: DictionaryStore
    /// Self-learning memory and rules (Słownik "Nauczone", Ustawienia "Ucz się z moich poprawek").
    @ObservationIgnored let learning: SelfLearning
    /// "Popraw" on selected text (⌃⌥⌘P and the Services menu).
    @ObservationIgnored let manualCorrection: ManualCorrection
    @ObservationIgnored let modelContainer: ModelContainer
    @ObservationIgnored let database: Database
    /// Full-text meeting search (FTS5), kept in step by `database`. Checked against the store and
    /// rebuilt when needed by `startServices()`; until it is ready search uses the store.
    @ObservationIgnored let meetingSearchIndex: MeetingSearchIndex

    // Account and Pro
    /// The Captylo account (sign-in, plan, billing links). Itself `@Observable`.
    @ObservationIgnored let account: AccountStore

    // Meetings
    @ObservationIgnored let proAccess: ProAccess
    /// Itself `@Observable`: views read its phase, live transcript and issues directly.
    @ObservationIgnored let meetingRecorder: MeetingRecorder
    /// AI notes after a meeting (Pro).
    @ObservationIgnored let meetingNotes: MeetingNotesProcessor
    /// "Wygeneruj ponownie" in the "Notatki AI" tab: `meetingNotes.regenerate` with the picked
    /// template. Itself `@Observable` (which meetings are being written, finished runs).
    @ObservationIgnored let meetingNotesRuns: MeetingNotesRuns
    /// "Zapytaj" about one meeting and "Zapytaj wszystkie spotkania" (Pro): `MeetingAsker` and
    /// `LibraryAsker` with the meetings model and the AI key. Itself `@Observable` (the question
    /// being answered per meeting, finished questions, the library session).
    @ObservationIgnored let meetingAskRuns: MeetingAskRuns
    /// The transcript actions in the details (cloud again, AI fix, restore). Itself `@Observable`.
    @ObservationIgnored let meetingTranscriptRuns: MeetingTranscriptRuns
    /// "Zachowuj nagrania spotkań": the last post-processor, and a sweep at launch.
    @ObservationIgnored let meetingRetention: MeetingRetention
    /// The meeting voice detector: fetched with the speech model and at launch, shown under the
    /// model status in Modele and onboarding. Itself `@Observable`.
    @ObservationIgnored let speechDetectorStatus: SpeechDetectorStatus
    /// "Wykrywaj spotkania": asks to record when a call starts and to stop when it ends.
    /// Polls only after `startServices()` (never in the design preview or the test host).
    @ObservationIgnored let meetingDetector: MeetingDetector
    /// "Kalendarz": the event a recording belongs to (title, participants) and the upcoming
    /// ones. Itself `@Observable`. Refreshes only after `startServices()`; the design preview
    /// and the test host get a fixed list instead of EventKit (`AppStateOverrides.calendarEvents`).
    @ObservationIgnored let meetingCalendar: MeetingCalendar
    /// "Przypominaj przed spotkaniem": a toast with "Nagraj" shortly before a calendar event
    /// with a call link. Checks only after `startServices()`.
    @ObservationIgnored let calendarReminder: CalendarReminder

    // Output and UI
    @ObservationIgnored let textOutput: TextOutput
    @ObservationIgnored let recorderModel: RecorderModel
    @ObservationIgnored let widget: RecorderPanelController
    @ObservationIgnored let toasts: ToastCenter

    // Shell
    @ObservationIgnored let accessibility: AccessibilityWatcher
    @ObservationIgnored let permissions: Permissions
    @ObservationIgnored let launchAtLogin: LaunchAtLogin
    @ObservationIgnored let windowPresenter: WindowPresenter
    @ObservationIgnored let oldAppDetector: OldAppDetector
    /// "Sprawdź aktualizacje" (Sparkle). Itself `@Observable`. No controller in the design preview
    /// or the test host; elsewhere it starts only in `startServices()`.
    @ObservationIgnored let updater: AppUpdater

    // Dictation and hotkeys
    @ObservationIgnored let dictationController: DictationController
    @ObservationIgnored let hotkeyTap: HotkeyTap
    @ObservationIgnored let hotkeyController: HotkeyController
    @ObservationIgnored let historyActions: HistoryActions

    /// "Transkrypcja pliku" queue. Owned here so it survives the main window closing and can
    /// take Finder "Otwórz za pomocą" files before any view exists; the drop zone feeds it too.
    @ObservationIgnored let fileQueue: FileTranscriptionQueue


    /// Seam-typed views of the services for code that only needs the protocol.
    var coordinator: any RecorderCoordinator { dictationController }
    var levelSource: any LevelSource { levelMeter }

    /// "Testuj tryb" on the Modele screen.
    var modeTester: ModeTester {
        let dictionary = self.dictionary
        return ModeTester(enhancer: utilityEnhancer, vocabulary: { dictionary.data.vocabulary })
    }

    /// Bumped after every saved dictation; the dashboard reloads with `.task(id:)`.
    var statsVersion: Int { stats.version }

    @ObservationIgnored private let hotkeyRelay: HotkeyRelay
    /// The dictation AI route runs off the main actor, so it reads this snapshot of `settings.aiModel`.
    @ObservationIgnored private let aiModelSnapshot: OSAllocatedUnfairLock<String>
    @ObservationIgnored private let aiCaptyloSnapshot: OSAllocatedUnfairLock<Bool>
    /// The cloud transcription route runs off the main actor too: `settings.sttCaptylo`.
    @ObservationIgnored private let sttCaptyloSnapshot: OSAllocatedUnfairLock<Bool>
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    /// ⌃⌥⌘M, registered while "Skrót ⌃⌥⌘M" is on (`applyMeetingShortcut`).
    @ObservationIgnored private var meetingShortcut: GlobalShortcut?
    /// ⌃⌥⌘P "Popraw", registered while its switch is on (`applyCorrectionShortcut`).
    @ObservationIgnored private var correctionShortcut: GlobalShortcut?
    /// Services menu "Popraw w Captylo"; set in `startServices`.
    @ObservationIgnored private var correctionService: CorrectionServiceProvider?
    @ObservationIgnored private var servicesStarted = false

    init(settings: AppSettings = AppSettings(), overrides: AppStateOverrides = .live) {
        self.settings = settings
        isDesignPreview = overrides.isDesignPreview
        let stats = StatsTicker()
        self.stats = stats

        // Audio
        let level = LevelMeter()
        levelMeter = level
        audioCapture = AudioCapture(level: level)
        audioDevices = AudioDevices(settings: settings)
        systemMute = SystemMute(settings: settings, defaults: overrides.systemMuteDefaults ?? .standard)
        sounds = Sounds(settings: settings)

        // Transcription
        let engine = WhisperEngine()
        localEngine = engine
        modelStore = LocalModelStore(engine: engine, pinnedStatus: overrides.pinnedModelStatus)
        livePreview = LivePreview(engine: engine)
        let keyStore = overrides.keyStore ?? KeyStore()
        self.keyStore = keyStore

        // Account and Pro. Pro comes from the Captylo account; the design preview and the test
        // host pin its state (no Keychain, no network, never a relay token).
        let account = AccountStore(
            client: AccountClient(),
            keyStore: overrides.pinnedAccount == nil ? keyStore : .inMemory(),
            settings: settings,
            pinned: overrides.pinnedAccount
        )
        self.account = account
        let access = ProAccess(settings: settings, account: account, pinned: overrides.pinnedPro)
        proAccess = access
        // Every cloud request: own key -> vendor, else the Pro session -> relay, else no route.
        let openRouter = OpenRouterClient()
        self.openRouter = openRouter
        let cloudRouter = CloudRouter(
            keyStore: keyStore,
            accountToken: { timeout in await account.relayToken(timeout: timeout) },
            aiClient: openRouter
        )

        // "Chmura Captylo" in Pro while it is chosen in Modele, else the own cloud key.
        let cloudCaptyloSnapshot = OSAllocatedUnfairLock(initialState: settings.sttCaptylo)
        sttCaptyloSnapshot = cloudCaptyloSnapshot
        elevenLabs = ElevenLabsSTT(
            session: HTTP.uploadSession,
            credentialProvider: {
                await cloudRouter.sttCredential(
                    timeout: ElevenLabsSTT.keyLookupTimeout,
                    preferRelay: cloudCaptyloSnapshot.withLock { $0 }
                )
            },
            retrySession: { HTTP.makeEphemeral() }
        )
        transcriptionRouter = TranscriptionRouter(
            local: engine,
            localInstalled: { WhisperEngine.isDownloaded },
            localReady: { engine.state == .ready },
            elevenLabs: elevenLabs
        )

        // AI cleanup
        openRouterModels = OpenRouterModels(settings: settings, client: openRouter)
        let modelSnapshot = OSAllocatedUnfairLock(initialState: settings.aiModel)
        aiModelSnapshot = modelSnapshot
        let captyloSnapshot = OSAllocatedUnfairLock(initialState: settings.aiCaptylo)
        aiCaptyloSnapshot = captyloSnapshot
        let modelsCache = settings.openRouterModelsCacheReader
        let reasoningPolicy: @Sendable (String) -> ReasoningPolicy = { ReasoningPolicy.lookup($0, inCache: modelsCache()) }
        // Dictation, files and "Testuj tryb": Captylo AI in Pro while it is chosen in Modele,
        // else the model chosen there with the own key (or the relay without one).
        let dictationRoute: @Sendable (Duration) async -> KeyStore.Lookup<AIRoute> = { timeout in
            await cloudRouter.aiRoute(
                timeout: timeout,
                model: modelSnapshot.withLock { $0 },
                preferRelay: captyloSnapshot.withLock { $0 }
            )
        }
        enhancer = Enhancer(
            client: openRouter,
            route: dictationRoute,
            reasoningProvider: reasoningPolicy
        )
        utilityEnhancer = Enhancer(
            client: openRouter,
            route: dictationRoute,
            reasoningProvider: reasoningPolicy,
            session: HTTP.fileLLMSession,
            deadline: FileTranscriptionQueue.enhancementDeadline,
            tokenCap: FileTranscriptionQueue.enhancementTokenCap
        )

        // Text and data
        dictionary = DictionaryStore(fileURL: overrides.dictionaryURL ?? AppPaths.dictionaryJSON, paragraphs: settings.paragraphs)
        let (container, isFallback) = overrides.modelContainer.map { ($0, false) } ?? Store.makeContainer()
        modelContainer = container
        storeIsFallback = isFallback
        // The real index file only next to the real store: an overridden or fallback store gets
        // an in-memory index (a fallback store would otherwise wipe the real index).
        let searchIndexURL = overrides.searchIndexURL
            ?? ((overrides.modelContainer == nil && !isFallback) ? AppPaths.searchIndex : nil)
        let searchIndex = MeetingSearchIndex(url: searchIndexURL)
        meetingSearchIndex = searchIndex
        let database = Database(modelContainer: container, searchIndex: searchIndex)
        self.database = database

        // Meetings: nothing records until the user starts a meeting (the design preview and the
        // test host never do), and never without the speech model on disk. The VAD loads once,
        // on the first meeting, and serves both tracks. After a meeting stops, in the background:
        // the cloud transcript (Pro, setting) replaces the live one, then speaker labels (Pro,
        // macOS 15+; the diarizer loads on first use), the AI fixes of the transcript (Pro,
        // setting) and the AI notes (Pro), both as "Captylo AI" on the Pro relay (`meetingRoute`),
        // so the notes see "Mówca N" and the fixed text.
        let meetingVAD = SpeechDetectorCache { try await FluidSpeechDetector.load() }
        let detectorStatus = SpeechDetectorStatus(load: { try await meetingVAD.prewarm() }, pinned: overrides.pinnedSpeechDetectorStatus)
        speechDetectorStatus = detectorStatus
        // The voice detector comes with the speech model: fetched right after its download.
        modelStore.onDownloaded = {
            Task { await detectorStatus.prewarm() }
        }
        let dictionaryStore = dictionary
        let meetingVocabulary: @Sendable () async -> [String] = { @MainActor in dictionaryStore.data.vocabulary }
        // The Pro relay only (own keys are for dictation). Off the hot path: a longer wait than
        // dictation, still bounded if an ACL prompt hangs.
        let meetingRoute: @Sendable () async -> AIRoute? = {
            switch await cloudRouter.relayAIRoute(timeout: .seconds(10)) {
            case .value(let route): return route
            case .timedOut:
                Log.enhancement.error("Meeting AI: the account token did not come in time")
                return nil
            }
        }
        let cloudSTT = elevenLabs
        let meetingCloud = MeetingCloudTranscription(
            database: database,
            isEnabled: { @MainActor in access.allows(.cloudMeetingTranscription) && settings.meetingsCloudTranscript },
            trackURL: { id, track in AppPaths.meetingTrackURL(id, track: track) },
            language: { @MainActor in settings.transcriptionLanguage },
            vocabulary: meetingVocabulary,
            transcribe: { request, mimeType in try await cloudSTT.transcribeWords(request, mimeType: mimeType) }
        )
        let speakerLabels = SpeakerLabelProcessor(
            database: database,
            diarizer: FluidSpeakerDiarizer(),
            isAllowed: { await access.allows(.speakerLabels) },
            trackURL: { id, track in AppPaths.meetingTrackURL(id, track: track) }
        )
        let meetingCorrection = MeetingCorrectionProcessor(
            database: database,
            corrector: MeetingTranscriptCorrector(route: meetingRoute),
            isEnabled: { @MainActor in access.allows(.meetingTranscriptCorrection) && settings.meetingsAICorrection },
            vocabulary: meetingVocabulary
        )
        let meetingSummarizer = MeetingSummarizer(route: meetingRoute)
        let meetingNotes = MeetingNotesProcessor(
            database: database,
            summarizer: meetingSummarizer,
            isAllowed: { await access.allows(.meetingAINotes) }
        )
        self.meetingNotes = meetingNotes
        meetingNotesRuns = MeetingNotesRuns { id, templateID in
            guard await access.allows(.meetingAINotes) else { return }
            await meetingNotes.regenerate(meetingID: id, templateID: templateID)
        }
        let meetingAsker = MeetingAsker(database: database, route: meetingRoute)
        let libraryAsker = LibraryAsker(database: database, index: searchIndex, route: meetingRoute)
        // The design preview never reaches the network: its questions are seeded.
        let asksOffline = overrides.isDesignPreview
        meetingAskRuns = MeetingAskRuns(
            ask: { id, question in
                guard !asksOffline, await access.allows(.meetingAsk) else { return }
                _ = await meetingAsker.ask(meetingID: id, question: question)
            },
            askLibrary: { question in
                guard !asksOffline, await access.allows(.meetingAsk) else { return nil }
                return await libraryAsker.ask(question: question)
            }
        )
        // Notes written from an older transcript would sit next to the new one (also in the
        // export), so a transcript that changed rewrites them with the same template. Meetings
        // without notes stay without: that is the user's "Napisz notatki".
        let refreshNotes: @Sendable (UUID) async -> Void = { id in
            guard await access.allows(.meetingAINotes),
                  let meeting = try? await database.meeting(id: id), meeting.summary != nil else { return }
            await meetingNotes.regenerate(meetingID: id, templateID: meeting.summaryTemplateID)
        }
        meetingTranscriptRuns = MeetingTranscriptRuns { id, kind in
            switch kind {
            case .cloud:
                guard await access.allows(.cloudMeetingTranscription) else { return }
                // The new "Rozmówcy" lines have no speaker labels yet, and like after a meeting
                // the cloud text gets the AI fixes when they are on.
                if await meetingCloud.run(meetingID: id) {
                    await speakerLabels.process(meetingID: id)
                    await meetingCorrection.process(meetingID: id)
                    await refreshNotes(id)
                }
            case .aiFix:
                guard await access.allows(.meetingTranscriptCorrection) else { return }
                if await meetingCorrection.run(meetingID: id) {
                    await refreshNotes(id)
                }
            case .restore:
                do {
                    try await database.restoreOriginalTranscript(meetingID: id)
                    await refreshNotes(id)
                } catch {
                    Log.data.error("Meeting transcript could not be restored: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        // Last: the speaker labels read the track files, the AI notes do not need them.
        let meetingRetention = MeetingRetention(
            database: database,
            policy: { await MainActor.run { settings.meetingAudioRetention } },
            folder: { AppPaths.meetingFolder($0) }
        )
        self.meetingRetention = meetingRetention
        // The calendar: never EventKit for the design preview or the test host.
        let calendarSource: any CalendarEventSource
        if let events = overrides.calendarEvents {
            calendarSource = FixedCalendarSource(events: events)
        } else {
            calendarSource = EventKitSource()
        }
        let meetingCalendar = MeetingCalendar(source: calendarSource, isOn: { settings.meetingsCalendar })
        self.meetingCalendar = meetingCalendar
        let mute = systemMute
        meetingRecorder = MeetingRecorder(environment: MeetingEnvironment(
            makeMic: { MeetingMicCapture(voiceProcessing: settings.meetingsVoiceProcessing) },
            makeSystem: { SystemAudioTap() },
            makeTranscriber: { id, language, save in
                MeetingTranscriber(meetingID: id, language: language, engine: engine,
                                   detectorFactory: { _ in try await meetingVAD.detector() }, save: save)
            },
            database: database,
            trackURL: { id, track in AppPaths.meetingTrackURL(id, track: track) },
            expectingSystemAudio: { CoreAudioProcesses.anyOtherProcessPlaying() },
            language: { settings.transcriptionLanguage },
            setMuteSuppressed: { mute.isSuppressed = $0 },
            postProcessors: [meetingCloud, speakerLabels, meetingCorrection, meetingNotes, meetingRetention],
            // After a quit mid-processing: only the AI steps still missing on the row, then
            // retention. Never the diarizer (a crash there would repeat at every launch) or the
            // cloud pass (paid; the live transcript is already there).
            resumeProcessors: [
                MeetingResumeStep(database: database, isDone: { $0.transcriptAIModel != nil }, processor: meetingCorrection),
                MeetingResumeStep(database: database, isDone: { $0.summary != nil }, processor: meetingNotes),
                meetingRetention,
            ],
            outputUsesBuiltInSpeakers: { CoreAudioProcesses.defaultOutputIsBuiltInSpeakers() },
            speechModelReady: { WhisperEngine.isDownloaded },
            currentEvent: { meetingCalendar.currentEvent() }
        ))

        // Output and UI
        textOutput = TextOutput()
        recorderModel = RecorderModel(level: level)
        let widget = RecorderPanelController(model: recorderModel)
        self.widget = widget
        toasts = ToastCenter(sounds: sounds, anchor: { [weak widget] in widget?.widgetFrame })

        // Self-learning: `learning.json` always sits next to the dictionary, so the test host and
        // the design preview (temp dictionary) never touch the user's memory.
        let learningURL = overrides.dictionaryURL.map { $0.deletingLastPathComponent().appending(path: "learning.json") }
            ?? AppPaths.learningJSON
        // Style distillation goes through the utility enhancer (file session, 15 s, no UsageStat),
        // never the dictation hot path, and only while AI is on.
        let styleEnhancer = utilityEnhancer
        let learning = SelfLearning(
            settings: settings,
            dictionary: dictionary,
            store: LearningStore(fileURL: learningURL),
            toasts: toasts,
            distill: { system, input in
                guard settings.aiEnabled else { return nil }
                let job = EnhancementJob(systemPrompt: system, kind: .rewrite, deadline: .seconds(15))
                if case .enhanced(let text, _, _) = await styleEnhancer.enhance(input, job: job) {
                    return text
                }
                return nil
            }
        )
        self.learning = learning
        let correction = ManualCorrection(
            learning: learning,
            output: textOutput,
            toasts: toasts,
            outputSettings: { settings.outputSettings }
        )
        manualCorrection = correction

        // Shell
        let accessibility = AccessibilityWatcher(pinnedTrust: overrides.pinnedAccessibilityTrust)
        self.accessibility = accessibility
        permissions = Permissions(accessibility: accessibility)
        launchAtLogin = LaunchAtLogin()
        let presenter = WindowPresenter(settings: settings)
        windowPresenter = presenter
        oldAppDetector = OldAppDetector()
        // The design preview and the test host never get a live updater (no network, no windows).
        updater = AppUpdater(enabled: !overrides.isDesignPreview && !AppStateOverrides.isTestHost)
        meetingDetector = MeetingDetector(
            recorder: meetingRecorder,
            toasts: toasts,
            isEnabled: { settings.meetingsAutoDetect },
            openMeetings: { presenter.openMain(section: .spotkania) },
            currentEvent: { meetingCalendar.currentEvent() }
        )
        let detector = meetingDetector
        calendarReminder = CalendarReminder(
            recorder: meetingRecorder,
            toasts: toasts,
            events: { meetingCalendar.isEnabled ? meetingCalendar.upcoming : [] },
            isEnabled: { settings.meetingsCalendarReminder },
            minutesBefore: { settings.meetingsCalendarReminderMinutes },
            lastDetectorOffer: { detector.lastOfferAt },
            openMeetings: { presenter.openMain(section: .spotkania) }
        )

        // Hotkeys: the tap comes first, the controller resolves through the relay.
        let relay = HotkeyRelay()
        hotkeyRelay = relay
        let tap = HotkeyTap { event in
            MainActor.assumeIsolated {
                relay.handle(event)
            }
        }
        hotkeyTap = tap
        tap.setHotkey(settings.hotkey)

        // Dictation
        dictationController = DictationController(env: DictationEnvironment(
            settings: settings,
            devices: audioDevices,
            capture: audioCapture,
            sounds: sounds,
            systemMute: systemMute,
            router: transcriptionRouter,
            livePreview: livePreview,
            enhancer: enhancer,
            dictionary: dictionary,
            learning: learning,
            pasteWatcher: EditWatcher(
                learning: learning,
                isEnabled: { settings.learningEnabled },
                userExcluded: { settings.learningExcludedApps }
            ),
            output: textOutput,
            widget: widget,
            toasts: toasts,
            recorderModel: recorderModel,
            database: database,
            persistsHistory: !isFallback,
            isLocalModelInstalled: { WhisperEngine.isDownloaded },
            isLocalModelReady: { engine.state == .ready },
            setEscapeArmed: { tap.setEscapeArmed($0) },
            didSave: {
                stats.bump()
                let days = settings.audioRetentionDays
                Task { await Retention.run(days: days, database: database) }
            },
            // Never over the onboarding: its Wypróbuj step shows the missing model itself, and
            // the main window must not jump in front of it (the error toast still appears).
            openModels: {
                guard !OnboardingPresenter.isShowing else { return }
                presenter.openMain(section: .modele)
            },
            openAccessibilitySettings: { accessibility.openSystemSettings() },
            openMicrophoneSettings: { MicrophonePermission.openSystemSettings() }
        ))
        hotkeyController = HotkeyController(tap: tap, coordinator: dictationController, toasts: toasts)
        relay.controller = hotkeyController
        // "Popraw" waits while a take runs, and a take that starts closes its panel.
        let dictation = dictationController
        correction.isDictating = { [weak dictation] in (dictation?.phase ?? .idle) != .idle }
        relay.willHandle = { [weak correction] in correction?.cancel() }
        // Expanded widget: microphone and language menus, output switches, "Pauza".
        recorderModel.controls = RecorderAppControls(
            settings: settings,
            devices: audioDevices,
            coordinator: dictationController,
            openModes: {
                guard !OnboardingPresenter.isShowing else { return }
                presenter.openMain(section: .modele)
            }
        )
        historyActions = HistoryActions(
            database: database,
            output: textOutput,
            router: transcriptionRouter,
            enhancer: utilityEnhancer,
            vocabulary: { dictionaryStore.data.vocabulary },
            didChange: { stats.bump() }
        )
        fileQueue = FileTranscriptionQueue(services: .make(
            settings: settings,
            router: transcriptionRouter,
            dictionary: dictionary,
            database: database,
            client: openRouter,
            route: dictationRoute,
            stats: stats,
            persistsHistory: !isFallback
        ))

        let controller = dictationController
        audioCapture.onDeviceDied = {
            Task { @MainActor in
                Log.audio.notice("Input device died, stopping the take")
                await controller.stop()
            }
        }
    }

    // MARK: Launch

    /// Everything a GUI launch does beyond construction. Idempotent.
    func startServices() {
        // The design preview runs next to a real Captylo: a second tap would double every take.
        guard !servicesStarted, !isDesignPreview else { return }
        servicesStarted = true

        // A crash or Force Quit during a take never ran `restore()`: undo that mute first.
        systemMute.recoverAfterAbnormalExit()

        do {
            try AppPaths.ensureDirectories()
        } catch {
            Log.data.error("Could not create the data directories: \(error.localizedDescription, privacy: .public)")
        }

        // A crash or quit mid-meeting left its row "recording": it becomes "Przerwane" with the
        // segments it saved. A meeting started right after launch waits for this.
        meetingRecorder.recoverInterruptedMeetings()

        // Search index: opened, checked against the store and rebuilt when missing, old, corrupt
        // or out of step, on its own queue. Search uses the store until it is ready.
        let searchIndex = meetingSearchIndex
        let indexedDatabase = database
        Task.detached(priority: .utility) {
            await searchIndex.prepare(database: indexedDatabase)
        }

        // API keys and the account token: read once on the Keychain queue so the hot path hits the cache.
        keyStore.preload([KeyStore.Account.openRouter, KeyStore.Account.elevenLabs, KeyStore.Account.captyloAccount])
        // The plan: refreshed now and every 6 hours (the cache already answered at init).
        account.start()

        // Updates: Sparkle's scheduler (no-op until the public key is configured).
        updater.start()

        // Hotkey tap: installed now when trusted, otherwise on the Accessibility flip (gotcha 38).
        // Revoking the grant kills the tap but leaves its port behind, so a re-grant always builds
        // a fresh one (otherwise `install()` sees the dead port and does nothing).
        let tap = hotkeyTap
        accessibility.onGranted = { [weak self] in
            tap.uninstall()
            tap.install()
            self?.permissions.refresh()
        }
        accessibility.onRevoked = { [weak self] in
            tap.uninstall()
            self?.permissions.refresh()
        }
        if accessibility.isTrusted {
            tap.install()
        }
        accessibility.start()

        // Audio unit prewarm at launch and on every route change (gotcha "prewarm").
        audioDevices.onRouteChange = { [weak self] in
            self?.prewarmCapture()
        }
        prewarmCapture()

        // Local model: background load at launch and after sleep. The meeting voice
        // detector follows it once the model is installed (its first load downloads it).
        let store = modelStore
        let detectorStatus = speechDetectorStatus
        Task {
            await store.prewarm()
            if store.isInstalled {
                await detectorStatus.prewarm()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.modelStore.prewarm() }
                self.prewarmCapture()
            }
        }

        // Retention (P1, 0 = off).
        let days = settings.audioRetentionDays
        let database = self.database
        let sweepOrphans = !storeIsFallback
        Task {
            await Retention.run(days: days, database: database)
            // The in-memory fallback store has no rows: sweeping against it would delete everything.
            if sweepOrphans {
                await Retention.sweepOrphans(database: database)
            }
        }
        // Meeting audio ("Zachowuj nagrania spotkań"): goes by the rows, so the in-memory
        // fallback store (no rows) removes nothing. Every finished meeting sweeps again.
        let meetingRetention = self.meetingRetention
        Task { await meetingRetention.sweep() }

        windowPresenter.start()
        oldAppDetector.start()
        applyMeetingShortcut()
        applyCorrectionShortcut()
        // Services menu "Popraw w Captylo" (`NSServices` in Info.plist).
        let service = CorrectionServiceProvider(correction: manualCorrection)
        correctionService = service
        NSApp.servicesProvider = service
        NSUpdateDynamicServices()
        // Always polling: it reads "Wykrywaj spotkania" every time and idles while it is off,
        // so switching it on in Ustawienia works without a relaunch.
        meetingDetector.start()
        // Same for "Kalendarz": every refresh reads the switch and idles (no EventKit read) while off.
        meetingCalendar.start()
        // And the reminder: it reads both switches on every check.
        // Each prompt knows about the other: one meeting never gets two "Nagrać?" toasts.
        meetingDetector.recentReminder = { [weak self] in self?.calendarReminder.lastReminderAt }
        calendarReminder.start()
        observeSettings()

        if storeIsFallback {
            showStoreFallbackAlert()
        }

        // Files Finder handed over during launch, before the data directories existed.
        drainPendingOpenURLs()
    }

    /// Quit path (`applicationWillTerminate`): synchronous only. Unmutes the output we muted
    /// (nothing else would), drops a live take and restores the user's clipboard early. A meeting
    /// that still records gets its track files finalized; the next launch marks it interrupted.
    func stopServices() {
        meetingDetector.stop()
        calendarReminder.stop()
        meetingCalendar.stop()
        meetingRecorder.abortForTermination()
        account.stop()
        systemMute.restore()
        dictationController.abortForTermination()
        textOutput.flushPendingRestore()
        hotkeyTap.uninstall()
        meetingShortcut?.unregister()
        correctionShortcut?.unregister()
        accessibility.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    func bumpStats() {
        stats.bump()
    }

    /// ⌃⌥⌘M and "Nagraj spotkanie" in the menu bar: ends the meeting that records, otherwise
    /// opens Spotkania first (a meeting never records without its live bar on screen) and starts one.
    func toggleMeetingRecording() {
        let recorder = meetingRecorder
        if recorder.isRecording {
            Task { await recorder.stop() }
            return
        }
        guard recorder.phase == .idle, !recorder.isStarting else { return }
        windowPresenter.openMain(section: .spotkania)
        Task { await recorder.start() }
    }

    /// Registers or drops ⌃⌥⌘M to match the setting. Only after `startServices`: the design
    /// preview and the test host never take the combo from the running app.
    private func applyMeetingShortcut() {
        guard servicesStarted else { return }
        if settings.meetingsShortcut {
            if meetingShortcut == nil {
                meetingShortcut = GlobalShortcut(GlobalShortcut.meeting) { [weak self] in
                    self?.toggleMeetingRecording()
                }
            }
            meetingShortcut?.register()
        } else {
            meetingShortcut?.unregister()
        }
    }

    /// Registers or drops ⌃⌥⌘P to match the setting, like `applyMeetingShortcut`.
    private func applyCorrectionShortcut() {
        guard servicesStarted else { return }
        if settings.learningFixShortcut {
            if correctionShortcut == nil {
                correctionShortcut = GlobalShortcut(GlobalShortcut.correction) { [weak self] in
                    self?.manualCorrection.start()
                }
            }
            correctionShortcut?.register()
        } else {
            correctionShortcut?.unregister()
        }
    }

    /// Finder "Otwórz za pomocą" (gotcha 63). A cold start stashes the URLs until
    /// `startServices()` has created the data directories; later opens go straight to the queue.
    func openFiles(_ urls: [URL]) {
        pendingOpenURLs.append(contentsOf: urls)
        guard servicesStarted else { return }
        drainPendingOpenURLs()
    }

    /// `captylo://pro/done` (after Checkout) and `captylo://account/refresh` (after the Portal):
    /// the account refreshes and the main window opens on its panel in Ustawienia.
    func handleDeepLink(_ url: URL) {
        guard account.handleDeepLink(url) else {
            Log.app.notice("Ignored an unknown captylo:// link")
            return
        }
        windowPresenter.openAccount()
    }

    private func drainPendingOpenURLs() {
        let urls = pendingOpenURLs
        guard !urls.isEmpty else { return }
        pendingOpenURLs.removeAll()
        fileQueue.add(urls: urls)
        windowPresenter.openMain(section: .plik)
    }

    // MARK: Helpers

    /// Builds the audio engine for the resolved device so the first take starts in a few ms.
    private func prewarmCapture() {
        guard MicrophonePermission.isAuthorized, dictationController.phase == .idle else { return }
        guard let device = audioDevices.resolve() else { return }
        let capture = audioCapture
        Task {
            do {
                try await capture.prepare(device: device)
            } catch {
                Log.audio.error("Audio prewarm failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Re-applies the settings that other services cache: hotkey, AI model, paragraphs, Dock policy.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.hotkey
            _ = settings.aiModel
            _ = settings.aiCaptylo
            _ = settings.sttCaptylo
            _ = settings.paragraphs
            _ = settings.menuBarOnly
            _ = settings.meetingsShortcut
            _ = settings.learningFixShortcut
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applySettings()
                self.observeSettings()
            }
        }
    }

    private func applySettings() {
        let hotkey = settings.hotkey
        // While the recorder control captures a new combo the tap holds nil; it re-arms itself.
        if hotkeyTap.hotkey != nil, hotkeyTap.hotkey != hotkey {
            hotkeyTap.setHotkey(hotkey)
        }
        let model = settings.aiModel
        aiModelSnapshot.withLock { $0 = model }
        let captylo = settings.aiCaptylo
        aiCaptyloSnapshot.withLock { $0 = captylo }
        let cloudCaptylo = settings.sttCaptylo
        sttCaptyloSnapshot.withLock { $0 = cloudCaptylo }
        if dictionary.paragraphs != settings.paragraphs {
            dictionary.setParagraphs(settings.paragraphs)
        }
        windowPresenter.applyDockPolicy()
        applyMeetingShortcut()
        applyCorrectionShortcut()
    }

    private func showStoreFallbackAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Ostrzeżenie o pamięci")
        alert.informativeText = String(localized: "Nie udało się otworzyć bazy historii. Ta sesja działa na bazie tymczasowej, nowe dyktowania nie zostaną zapisane.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
