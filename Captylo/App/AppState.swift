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
    @ObservationIgnored let parakeetEngine: ParakeetEngine
    @ObservationIgnored let modelStore: ParakeetModelStore
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
    @ObservationIgnored let modelContainer: ModelContainer
    @ObservationIgnored let database: Database

    // Meetings
    @ObservationIgnored let proAccess: ProAccess
    /// Itself `@Observable`: views read its phase, live transcript and issues directly.
    @ObservationIgnored let meetingRecorder: MeetingRecorder
    /// AI notes after a meeting (Pro); the meeting view calls `regenerate` with another template.
    @ObservationIgnored let meetingNotes: MeetingNotesProcessor

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

    // Dictation and hotkeys
    @ObservationIgnored let dictationController: DictationController
    @ObservationIgnored let hotkeyTap: HotkeyTap
    @ObservationIgnored let hotkeyController: HotkeyController
    @ObservationIgnored let historyActions: HistoryActions

    /// "Transkrypcja pliku" queue. Owned here so it survives the main window closing and can
    /// take Finder "Otwórz za pomocą" files before any view exists; the drop zone feeds it too.
    @ObservationIgnored let fileQueue: FileTranscriptionQueue

    /// Ustawienia > Dane: import of the old VocaType history (dry run cached, progress, result).
    @ObservationIgnored let legacyImport: LegacyImportModel

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
    /// `Enhancer.modelProvider` runs off the main actor, so it reads this snapshot of `settings.aiModel`.
    @ObservationIgnored private let aiModelSnapshot: OSAllocatedUnfairLock<String>
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
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
        let engine = ParakeetEngine()
        parakeetEngine = engine
        modelStore = ParakeetModelStore(engine: engine, pinnedStatus: overrides.pinnedModelStatus)
        livePreview = LivePreview(engine: engine)
        let keyStore = overrides.keyStore ?? KeyStore()
        self.keyStore = keyStore
        elevenLabs = ElevenLabsSTT(
            session: HTTP.uploadSession,
            keyProvider: { await keyStore.load(KeyStore.Account.elevenLabs, timeout: ElevenLabsSTT.keyLookupTimeout) },
            retrySession: { HTTP.makeEphemeral() }
        )
        transcriptionRouter = TranscriptionRouter(
            local: engine,
            localInstalled: { ParakeetEngine.isDownloaded },
            elevenLabs: elevenLabs
        )

        // AI cleanup
        openRouter = OpenRouterClient()
        openRouterModels = OpenRouterModels(settings: settings, client: openRouter)
        let modelSnapshot = OSAllocatedUnfairLock(initialState: settings.aiModel)
        aiModelSnapshot = modelSnapshot
        let modelsCache = settings.openRouterModelsCacheReader
        let reasoningPolicy: @Sendable (String) -> ReasoningPolicy = { ReasoningPolicy.lookup($0, inCache: modelsCache()) }
        enhancer = Enhancer(
            client: openRouter,
            keyStore: keyStore,
            modelProvider: { modelSnapshot.withLock { $0 } },
            reasoningProvider: reasoningPolicy
        )
        utilityEnhancer = Enhancer(
            client: openRouter,
            keyStore: keyStore,
            modelProvider: { modelSnapshot.withLock { $0 } },
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
        let database = Database(modelContainer: container)
        self.database = database

        // Meetings: nothing records until the user starts a meeting (the design preview and the
        // test host never do). The VAD loads once, on the first meeting, and serves both tracks.
        // After a meeting stops: speaker labels (Pro, macOS 15+; the diarizer loads on first use),
        // then AI notes (Pro) with the user's AI key and model, so the notes see "Mówca N".
        let access = ProAccess(settings: settings, pinned: overrides.pinnedPro)
        proAccess = access
        let meetingVAD = SpeechDetectorCache { try await FluidSpeechDetector.load() }
        let speakerLabels = SpeakerLabelProcessor(
            database: database,
            diarizer: FluidSpeakerDiarizer(),
            isAllowed: { await access.allows(.speakerLabels) },
            trackURL: { id, track in AppPaths.meetingTrackURL(id, track: track) }
        )
        let meetingSummarizer = MeetingSummarizer(
            client: openRouter,
            key: {
                // Off the hot path: a longer wait than dictation, still bounded if an ACL prompt hangs.
                switch await keyStore.load(KeyStore.Account.openRouter, timeout: .seconds(10)) {
                case .value(let key): return key
                case .timedOut:
                    Log.enhancement.error("Meeting notes: Keychain read did not finish in time")
                    return nil
                }
            },
            model: { modelSnapshot.withLock { $0 } },
            reasoning: reasoningPolicy
        )
        let meetingNotes = MeetingNotesProcessor(
            database: database,
            summarizer: meetingSummarizer,
            isAllowed: { await access.allows(.meetingAINotes) }
        )
        self.meetingNotes = meetingNotes
        let mute = systemMute
        meetingRecorder = MeetingRecorder(environment: MeetingEnvironment(
            makeMic: { MeetingMicCapture() },
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
            postProcessors: [speakerLabels, meetingNotes]
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

        // Shell
        let accessibility = AccessibilityWatcher(pinnedTrust: overrides.pinnedAccessibilityTrust)
        self.accessibility = accessibility
        permissions = Permissions(accessibility: accessibility)
        launchAtLogin = LaunchAtLogin()
        let presenter = WindowPresenter(settings: settings)
        windowPresenter = presenter
        oldAppDetector = OldAppDetector()

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
            isLocalModelInstalled: { ParakeetEngine.isDownloaded },
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
        let dictionaryStore = dictionary
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
            keyStore: keyStore,
            stats: stats,
            persistsHistory: !isFallback
        ))

        // The design preview and the test host run next to the real data: they never scan it.
        let scansOldData = !overrides.isDesignPreview && !AppStateOverrides.isTestHost
        legacyImport = LegacyImportModel(
            sources: { scansOldData ? LegacySource.discover() : [] },
            database: database,
            dictionary: dictionary,
            settings: settings,
            stats: stats,
            storeAvailable: !isFallback
        )

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

        // API keys: read once on the Keychain queue so the hot path hits the cache.
        keyStore.preload([KeyStore.Account.openRouter, KeyStore.Account.elevenLabs])
        // Keys of the pre-rename build: copied off the main thread, retried until answered.
        LegacyMigration.migrateKeysInBackground(into: keyStore)

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

        // Parakeet: background load at launch and after sleep (gotcha 16).
        let store = modelStore
        Task { await store.prewarm() }
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

        windowPresenter.start()
        oldAppDetector.start()
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
        meetingRecorder.abortForTermination()
        systemMute.restore()
        dictationController.abortForTermination()
        textOutput.flushPendingRestore()
        hotkeyTap.uninstall()
        accessibility.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    func bumpStats() {
        stats.bump()
    }

    /// Finder "Otwórz za pomocą" (gotcha 63). A cold start stashes the URLs until
    /// `startServices()` has created the data directories; later opens go straight to the queue.
    func openFiles(_ urls: [URL]) {
        pendingOpenURLs.append(contentsOf: urls)
        guard servicesStarted else { return }
        drainPendingOpenURLs()
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
            _ = settings.paragraphs
            _ = settings.menuBarOnly
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
        if dictionary.paragraphs != settings.paragraphs {
            dictionary.setParagraphs(settings.paragraphs)
        }
        windowPresenter.applyDockPolicy()
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
