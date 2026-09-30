import Foundation
import Observation

/// The dictation state machine: idle -> recording -> transcribing -> enhancing -> idle.
/// Implements the hot path from the brief (4.2) with every state change on the main actor.
/// Called by `HotkeyController`, the widget orb and the menu bar through `RecorderCoordinator`.
@MainActor
@Observable
final class DictationController: RecorderCoordinator {
    /// Recordings shorter than this are discarded (gotcha 17).
    static let minimumDuration: TimeInterval = 0.3
    /// Start sound, widget and mute are deferred so a cancelled press never flashes (gotcha 42).
    static let revealDelay: Duration = .milliseconds(150)
    static let muteDelay: Duration = .milliseconds(220)
    static let timerTick: Duration = .milliseconds(250)
    /// Re-warm the LLM connection when the recording outlived the prewarm debounce (gotcha 64).
    static let longRecording: TimeInterval = 30

    private(set) var phase: DictationPhase = .idle
    private(set) var partialText = ""
    /// Excludes paused time, drives the mm:ss timer.
    private(set) var elapsed: TimeInterval = 0

    var isWidgetVisible: Bool { env.widget.isVisible }

    /// One take: identity, samples, file and timing.
    private struct Session {
        let id: UUID
        let buffer: SampleBuffer
        let fileURL: URL
        var startedAt: TimeInterval
        var pausedTotal: TimeInterval = 0
        var pausedAt: TimeInterval?
    }

    @ObservationIgnored private let env: DictationEnvironment
    @ObservationIgnored private var session: Session?
    /// Guards the awaits inside `start()` (permission prompt, engine start) against a second start.
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    /// The stop pipeline in flight, tagged with its take so a stale task never swallows a newer stop.
    @ObservationIgnored private var stopTask: (id: UUID, task: Task<Void, Never>)?
    /// Text of the last delivered take: a take that is only a spelling ("Pisane J-E-V") corrects it.
    @ObservationIgnored private var lastDeliveredText: String?

    init(env: DictationEnvironment) {
        self.env = env
        env.recorderModel.onStop = { [weak self] in
            Task { @MainActor [weak self] in await self?.stop() }
        }
        env.recorderModel.onCancel = { [weak self] in
            Task { @MainActor [weak self] in await self?.cancel() }
        }
    }

    // MARK: - RecorderCoordinator

    func start() async {
        guard phase == .idle, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        // Edits of the previous paste are final once the next take starts; the target app gets
        // the take's length to build its accessibility tree for the next watch.
        env.pasteWatcher.flush()
        env.pasteWatcher.prepare()

        if env.settings.sttEngine == .parakeet, !env.isLocalModelInstalled() {
            env.toasts.showError(DictationError.modelNotReady)
            env.openModels()
            return
        }

        guard await MicrophonePermission.request() else {
            let status = MicrophonePermission.status
            if status == .denied || status == .restricted {
                let open = env.openMicrophoneSettings
                env.toasts.showAction(
                    message: DictationError.micDenied.errorDescription ?? "",
                    buttonTitle: String(localized: "Otwórz ustawienia"),
                    action: { open() }
                )
            } else {
                env.toasts.showError(DictationError.micDenied)
            }
            return
        }

        guard let device = env.devices.resolve() else {
            env.toasts.showError(DictationError.noMicrophone(lidClosed: env.devices.isLidClosed))
            return
        }

        let id = UUID()
        let buffer = SampleBuffer()
        let fileURL = AppPaths.recordingURL(for: id)
        var take = Session(id: id, buffer: buffer, fileURL: fileURL, startedAt: Self.now())
        session = take
        setPhase(.recording)
        partialText = ""
        elapsed = 0
        env.recorderModel.partialText = ""
        env.recorderModel.elapsed = 0
        env.recorderModel.showLivePreview = env.settings.livePreview
        env.setEscapeArmed(true)

        let signpost = Log.signposter.beginInterval("dictation.start")
        do {
            try await env.capture.start(device: device, fileURL: fileURL, into: buffer)
        } catch {
            Log.signposter.endInterval("dictation.start", signpost)
            Log.audio.error("Capture start failed: \(error.localizedDescription, privacy: .public)")
            guard session?.id == id else { return }
            session = nil
            env.setEscapeArmed(false)
            setPhase(.idle)
            env.toasts.showError(error)
            return
        }
        Log.signposter.endInterval("dictation.start", signpost)

        // Cancelled (Esc or accidental start) while the engine was starting.
        guard session?.id == id, phase == .recording else { return }
        take.startedAt = Self.now()
        session = take
        Log.app.info("Dictation \(id.uuidString, privacy: .public) started")

        revealTask = Task { [weak self] in
            try? await Task.sleep(for: Self.revealDelay)
            guard !Task.isCancelled, let self, self.session?.id == id, self.phase.isCapturing else { return }
            self.env.sounds.play(.start)
            self.env.widget.show()
            self.env.systemMute.muteIfEnabled(after: Self.muteDelay)
        }
        startTimer(for: id)

        if env.settings.aiEnabled {
            let enhancer = env.enhancer
            Task { await enhancer.prewarm() }
        }
        if env.settings.livePreview, env.isLocalModelReady() {
            startPreview(for: id, buffer: buffer)
        }
    }

    func stop() async {
        guard phase.isCapturing, let take = session else { return }
        if let stopTask, stopTask.id == take.id {
            await stopTask.task.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStop(take)
        }
        stopTask = (take.id, task)
        await task.value
        if stopTask?.id == take.id {
            stopTask = nil
        }
    }

    func cancel() async {
        guard phase != .idle || session != nil else { return }
        Log.app.info("Dictation cancelled in phase \(String(describing: self.phase), privacy: .public)")
        stopTask?.task.cancel()
        stopTask = nil
        cancelSideTasks()
        let take = session
        session = nil
        await env.capture.abort()
        if let take {
            Self.removeFile(take.fileURL)
        }
        env.systemMute.restore()
        hideWidget()
        setPhase(.idle)
        partialText = ""
        env.recorderModel.partialText = ""
    }

    /// Quit during a take: `applicationWillTerminate` cannot await, so this unmutes the output,
    /// stops the engine and deletes the WAV synchronously. Nothing is saved, like `cancel()`.
    func abortForTermination() {
        env.systemMute.restore()
        guard phase != .idle || session != nil else { return }
        Log.app.info("Dictation aborted by quit in phase \(String(describing: self.phase), privacy: .public)")
        stopTask?.task.cancel()
        stopTask = nil
        cancelSideTasks()
        let take = session
        session = nil
        env.capture.abortSynchronously()
        if let take {
            Self.removeFile(take.fileURL)
        }
        hideWidget()
        setPhase(.idle)
    }

    func togglePause() {
        guard var take = session else { return }
        switch phase {
        case .recording:
            env.capture.setPaused(true)
            take.pausedAt = Self.now()
            session = take
            setPhase(.paused)
        case .paused:
            env.capture.setPaused(false)
            if let pausedAt = take.pausedAt {
                take.pausedTotal += Self.now() - pausedAt
                take.pausedAt = nil
            }
            session = take
            setPhase(.recording)
        default:
            return
        }
    }

    // MARK: - Stop pipeline

    private func performStop(_ take: Session) async {
        let id = take.id
        setPhase(.transcribing)
        cancelSideTasks()
        let signpost = Log.signposter.beginInterval("dictation.stop")
        defer { Log.signposter.endInterval("dictation.stop", signpost) }

        let recordedFor = Self.now() - take.startedAt - take.pausedTotal
        if env.settings.aiEnabled, recordedFor > Self.longRecording {
            let enhancer = env.enhancer
            Task { await enhancer.prewarm() }
        }

        var record = DictationRecord(
            id: id,
            text: "",
            source: .dictation,
            audioFileName: take.fileURL.lastPathComponent,
            language: env.settings.transcriptionLanguage
        )

        do {
            let duration = try await env.capture.stop()
            env.systemMute.restore()
            try Task.checkCancellation()
            record.audioDuration = duration

            guard duration >= Self.minimumDuration else {
                Log.app.info("Dictation \(id.uuidString, privacy: .public) discarded: \(duration, format: .fixed(precision: 2)) s")
                discard(take)
                return
            }
            if !env.widget.isVisible {
                env.widget.show()
            }

            let audio = CapturedAudio(id: id, fileURL: take.fileURL, samples: take.buffer.snapshot(), duration: duration)
            let result = try await env.router.transcribe(
                audio,
                engine: env.settings.sttEngine,
                language: env.settings.transcriptionLanguage,
                vocabulary: env.dictionary.data.vocabulary
            )
            try Task.checkCancellation()
            record.modelName = result.modelName
            record.transcriptionMs = result.ms
            if result.usedFallback {
                env.toasts.showInfo(String(localized: "Chmura nie odpowiedziała, użyto Parakeet."))
            }

            // A take that is only a spelling corrects the previous dictation: learn the pair,
            // paste nothing, keep no row.
            if env.learning.isEnabled,
               let letters = SpellingDetector.standaloneSpelling(result.text),
               let previous = lastDeliveredText,
               let heard = SpellingDetector.closestWord(in: previous, to: letters, isRealWord: WordChecker.isRealWord) {
                env.learning.learn(spelled: [SpellingDetector.Spelled(heard: heard, spelled: SpellingDetector.cased(letters, like: heard))])
                Log.app.info("Dictation \(id.uuidString, privacy: .public) was a spelling of the previous take, not pasted")
                discard(take)
                return
            }

            // Words spelled out loud replace the misheard word and drop the letters; the pairs
            // are learned after the paste.
            let spelling = SpellingDetector.apply(result.text)
            let text = env.dictionary.processor.process(spelling.text, language: env.settings.transcriptionLanguage)
            guard !text.isEmpty else {
                env.toasts.showInfo(DictationError.emptyResult.errorDescription ?? "")
                discard(take)
                return
            }
            record.text = text

            var finalText = text
            // AI off: no mode and no note. AI on: the row always names the mode, and a note
            // says why there is no AI version (too short, no key, deadline, HTTP error...).
            if env.settings.aiEnabled {
                let mode = env.settings.activeMode
                if Enhancer.shouldSkip(text, kind: mode.kind) {
                    record.applyEnhancement(.skipped(.tooShort), mode: mode.name)
                } else {
                    setPhase(.enhancing)
                    let outcome = await env.enhancer.enhance(
                        text,
                        mode: mode,
                        vocabulary: env.dictionary.data.vocabulary,
                        learned: env.learning.promptContext
                    )
                    try Task.checkCancellation()
                    record.applyEnhancement(outcome, mode: mode.name)
                    switch outcome {
                    case .enhanced(let enhanced, _, _):
                        finalText = enhanced
                    case .failed(let failure, _):
                        Log.enhancement.notice("AI skipped: \(failure.errorDescription ?? "", privacy: .public)")
                        env.toasts.showInfo(String(localized: "AI pominięte"))
                    case .skipped:
                        break
                    }
                }
            }
            record.wordCount = WordCounter.count(finalText)

            env.sounds.play(.stop)
            hideWidget()
            await env.pasteWatcher.willPaste()
            let delivery = await env.output.deliver(finalText, env.settings.outputSettings)
            if delivery == .pasted {
                env.pasteWatcher.didPaste(finalText)
            }
            lastDeliveredText = finalText
            if case .copiedOnly(let reason) = delivery {
                Log.output.notice("Paste failed: \(reason, privacy: .public)")
                let open = env.openAccessibilitySettings
                env.toasts.showAction(
                    message: String(localized: "Skopiowano - naciśnij ⌘V"),
                    buttonTitle: String(localized: "Włącz dostęp"),
                    action: { open() }
                )
            }
            finishTake(take)
            Log.app.info("Dictation \(id.uuidString, privacy: .public) done: \(record.wordCount) words, stt \(result.ms) ms")
            persist(record, fileURL: take.fileURL)
            if !spelling.spelled.isEmpty {
                env.learning.learn(spelled: spelling.spelled)
            }
        } catch is CancellationError {
            // cancel() already aborted the capture, deleted the WAV and reset the phase.
            return
        } catch {
            // Cancelled or superseded take: cancel() already cleaned up, and a newer take owns the UI.
            if Task.isCancelled || session?.id != take.id { return }
            Log.app.error("Dictation \(id.uuidString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            env.systemMute.restore()
            env.toasts.showError(error)
            finishTake(take)
            record.status = .failed
            record.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            persist(record, fileURL: take.fileURL)
        }
    }

    /// Saves the row after the paste (never before) or drops the WAV when history is off or only
    /// lives in the in-memory fallback store. A failed save drops the WAV too: a recording no row
    /// points at could never be seen or deleted from Historia.
    private func persist(_ record: DictationRecord, fileURL: URL) {
        guard env.settings.saveHistory, env.persistsHistory else {
            Self.removeFile(fileURL)
            return
        }
        let database = env.database
        let didSave = env.didSave
        Task {
            do {
                try await database.save(record)
                didSave()
            } catch {
                Log.data.error("Saving dictation failed: \(error.localizedDescription, privacy: .public), dropping its recording")
                Self.removeFile(fileURL)
            }
        }
    }

    /// Too short or nothing heard: no row, no WAV.
    private func discard(_ take: Session) {
        finishTake(take)
        Self.removeFile(take.fileURL)
    }

    /// Common tail of every stop: hide, idle, clear the session. A newer take keeps its widget and phase.
    private func finishTake(_ take: Session) {
        if session?.id == take.id {
            session = nil
        } else if session != nil {
            return
        }
        hideWidget()
        setPhase(.idle)
        partialText = ""
        env.recorderModel.partialText = ""
    }

    // MARK: - Side tasks

    private func startTimer(for id: UUID) {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.timerTick)
                guard !Task.isCancelled, let self, let take = self.session, take.id == id else { return }
                guard self.phase.isCapturing else { continue }
                let paused = take.pausedTotal + (take.pausedAt.map { Self.now() - $0 } ?? 0)
                let value = max(0, Self.now() - take.startedAt - paused)
                self.elapsed = value
                self.env.recorderModel.elapsed = value
            }
        }
    }

    private func startPreview(for id: UUID, buffer: SampleBuffer) {
        previewTask?.cancel()
        let stream = env.livePreview.updates(buffer: buffer, language: env.settings.transcriptionLanguage)
        previewTask = Task { [weak self] in
            for await text in stream {
                guard !Task.isCancelled, let self else { return }
                // Stale session or not recording: drop the partial (gotcha 59).
                guard self.session?.id == id, self.phase == .recording else { continue }
                self.partialText = text
                self.env.recorderModel.partialText = text
            }
        }
    }

    private func cancelSideTasks() {
        revealTask?.cancel()
        revealTask = nil
        previewTask?.cancel()
        previewTask = nil
        timerTask?.cancel()
        timerTask = nil
    }

    private func hideWidget() {
        env.widget.hide()
        env.setEscapeArmed(false)
    }

    private func setPhase(_ new: DictationPhase) {
        phase = new
        env.recorderModel.phase = new
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func removeFile(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            Log.audio.debug("Could not remove \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
