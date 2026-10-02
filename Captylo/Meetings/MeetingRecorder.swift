import Foundation
import Observation
import os

/// One meeting at a time: the mic ("Ja") and the system audio ("Rozmówcy") -> a track file each
/// and the live transcriber -> SwiftData, segment by segment.
///
/// Independent of dictation: the dictation hotkey keeps working while a meeting records, and
/// `SystemMute` is suppressed for the whole meeting, so a take never mutes the call.
///
/// Sources start and stop on `control`, a serial queue: engine and Core Audio calls block (the
/// first tap start shows the system prompt) and one queue keeps a tap rebuild and a stop in the
/// order they were asked for. `MeetingTrackFeed` keeps both tracks on the meeting clock.
///
/// A crash or quit leaves the row "recording" with the segments saved so far and readable
/// tracks; `recoverInterruptedMeetings()` marks it "interrupted" at the next launch.
///
/// `stop` returns to idle once the transcript, the echo marks and the meeting's length are
/// saved. The post-processors (speaker labels, AI notes, retention) then run in the background,
/// one meeting at a time in stop order, while the row reads "processing": a call that starts
/// right after can be recorded at once.
@MainActor
@Observable
final class MeetingRecorder {
    enum Phase: Equatable {
        case idle
        case recording(meetingID: UUID, startedAt: Date)
        case finishing(meetingID: UUID)
    }

    enum SystemAudioIssue: Equatable {
        /// The tap could not start (message for the banner); the mic still records.
        case unavailable(String)
        /// Exact zeros while other apps play: "Brak dostępu do dźwięku systemu".
        case noAccess
        /// The other side was heard, then only zeros for a minute while other apps play, and a
        /// tap rebuild brought nothing back (`SystemTrackWatch`): the other side is quiet or the
        /// tap hears nothing. The live bar warns that it cannot hear them; real audio, or nothing
        /// playing anymore, clears it.
        case silent
    }

    /// How often the default output is checked for the headphones hint while recording.
    nonisolated static let outputRouteInterval: Duration = .seconds(4)

    private(set) var phase: Phase = .idle
    /// Finished utterances in time order, without the mic's echo of the other side.
    private(set) var liveSegments: [MeetingSegmentRecord] = []
    /// The grey "w trakcie" line per track.
    private(set) var partials: [MeetingTrack: String] = [:]
    private(set) var systemAudioIssue: SystemAudioIssue?
    /// While recording: the mic could not start (only the other side records). While idle: why
    /// the last start failed. Cleared by the next start and by a stop.
    private(set) var lastError: String?
    /// The last start was refused because the speech model is not on disk (`lastError` says
    /// so); Spotkania offers to open Modele. Cleared by the next start.
    private(set) var needsSpeechModel = false
    /// While recording: speech is not turning into lines (`MeetingTranscriber` reports it); the
    /// live bar warns. Cleared by the stop.
    private(set) var transcriptionProblem: MeetingLiveUpdate.Problem?
    private(set) var lastFinishedMeetingID: UUID?
    /// The calendar event the current recording is for (the one on its row); nil without one
    /// and once the recording stops. `MeetingDetector` ends the call sooner when it is long over.
    private(set) var linkedEvent: CalendarEvent?
    /// Bumped each time the post-processors are done with a meeting (it reads "completed" now):
    /// Spotkania reloads to show the speaker labels and the AI notes.
    private(set) var processedCount = 0
    /// Set from the first line of `start` until it returns: a second click must not open a
    /// second meeting, and "Nagraj spotkanie" stays disabled meanwhile (the first system audio
    /// start can wait on the permission prompt).
    private(set) var isStarting = false
    /// The consent card of this recording ("Nagrywasz spotkanie. Poinformuj uczestników.") is
    /// still up: set by every start, cleared by its close button and by the stop.
    private(set) var showsConsentReminder = false
    /// The default output is the Mac's speakers while recording: the other side will also reach
    /// the mic, so the live bar suggests headphones.
    private(set) var usesBuiltInSpeakers = false

    @ObservationIgnored private let env: MeetingEnvironment
    @ObservationIgnored private let control = DispatchQueue(label: "com.captylo.app.meeting.recorder", qos: .userInitiated)
    @ObservationIgnored private var mic: (any MeetingAudioSource)?
    @ObservationIgnored private var system: (any MeetingAudioSource)?
    @ObservationIgnored private var feeds: [MeetingTrack: MeetingTrackFeed] = [:]
    @ObservationIgnored private var transcriber: MeetingTranscriber?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var interruptions: [Double] = []
    /// Bumped by every start of the system source: a rebuilt tap is a new session of its feed.
    @ObservationIgnored private var systemSession = 0
    @ObservationIgnored private var recovery: Task<Void, Never>?
    /// The post-processing of the last stopped meeting; it waits for the one before it.
    @ObservationIgnored private var postProcessing: Task<Void, Never>?
    @ObservationIgnored private var routeTask: Task<Void, Never>?
    @ObservationIgnored private let systemWatch = OSAllocatedUnfairLock(initialState: SystemTrackWatch())
    /// Design preview only (`previewLive`): fixed meter levels instead of the sources'.
    @ObservationIgnored private var previewLevels: [MeetingTrack: Float]?

    init(environment: MeetingEnvironment) {
        env = environment
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var currentMeetingID: UUID? {
        switch phase {
        case .idle: return nil
        case .recording(let id, _), .finishing(let id): return id
        }
    }

    func elapsed(at date: Date = Date()) -> TimeInterval {
        if case .recording(_, let startedAt) = phase { return max(0, date.timeIntervalSince(startedAt)) }
        return 0
    }

    func level(_ track: MeetingTrack) -> Float {
        if let previewLevels { return previewLevels[track] ?? 0 }
        return (track == .me ? mic : system)?.level ?? 0
    }

    /// The close button of the consent card.
    func dismissConsentReminder() {
        showsConsentReminder = false
    }

    /// "Spotkanie w Zoom, 30 września 14:00" / "Spotkanie, 30 września 14:00".
    nonisolated static func defaultTitle(appName: String?, date: Date) -> String {
        let locale = AppLocale.current
        let day = date.formatted(.dateTime.day().month(.wide).locale(locale))
        let time = date.formatted(.dateTime.hour().minute().locale(locale))
        let when = "\(day) \(time)"
        if let appName, !appName.isEmpty {
            return String(localized: "Spotkanie w \(appName), \(when)")
        }
        return String(localized: "Spotkanie, \(when)")
    }

    /// `live` with `segment` inserted in time order, minus the mic's echo of the other side.
    /// The echo marks in the database are made once, when the meeting ends (`EchoFilter.mark`);
    /// live, a mic segment is hidden as soon as a system segment it repeats is known, whichever
    /// of the two was transcribed first.
    nonisolated static func liveTranscript(adding segment: MeetingSegmentRecord, to live: [MeetingSegmentRecord]) -> [MeetingSegmentRecord] {
        if segment.track == .me, EchoFilter.isEcho(segment, against: live) {
            return live
        }
        var result = live
        let index = result.lastIndex { $0.start <= segment.start }.map { $0 + 1 } ?? 0
        result.insert(segment, at: index)
        guard segment.track == .them else { return result }
        let window = EchoFilter.window
        let echoes = Set(result.filter {
            $0.track == .me && $0.end >= segment.start - window && $0.start <= segment.end + window
                && EchoFilter.isEcho($0, against: result)
        }.map(\.id))
        return echoes.isEmpty ? result : result.filter { !echoes.contains($0.id) }
    }

    // MARK: Launch recovery

    /// Launch step: a meeting left "recording" by a crash or quit becomes "interrupted" with the
    /// segments it saved (echo marked, length from its track files), one left "processing" becomes
    /// "completed" (`Database.markInterruptedMeetings`). `start` waits for it, so a meeting started
    /// right after launch is never swept up with them. Runs once.
    func recoverInterruptedMeetings() {
        guard recovery == nil else { return }
        let database = env.database
        let trackURL = env.trackURL
        recovery = Task {
            do {
                let ids = try await database.markInterruptedMeetings { id in
                    MeetingTrack.allCases.map { TrackFileWriter.recordedSeconds(at: trackURL(id, $0)) }.max() ?? 0
                }
                if !ids.isEmpty {
                    Log.data.notice("Marked \(ids.count) interrupted meeting(s)")
                }
            } catch {
                Log.data.error("Interrupted meetings could not be marked: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Start

    /// - Parameters:
    ///   - title: an explicit title. Without it the calendar event names the row, and without an
    ///     event the default "Spotkanie w Zoom, 30 września 14:00".
    ///   - appName: the app in the call ("Zoom", from the detector). Without it the event's
    ///     call service ("Meet") stands in.
    ///   - event: the calendar event this recording is for (the detector's offer, the upcoming
    ///     strip). When nil and `title` is nil, `env.currentEvent()` picks the event matching
    ///     now. The row keeps the event's id and participants.
    func start(title: String? = nil, appName: String? = nil, event: CalendarEvent? = nil) async {
        guard phase == .idle, !isStarting else { return }
        guard env.speechModelReady() else {
            refuseWithoutSpeechModel()
            return
        }
        needsSpeechModel = false
        isStarting = true
        defer { isStarting = false }
        await recovery?.value

        let now = Date()
        let clockStart = MeetingTrackFeed.now()
        let event = event ?? (title == nil ? env.currentEvent() : nil)
        let appName = appName ?? event?.callApp
        let eventTitle = event.flatMap { $0.title.isEmpty ? nil : $0.title }
        var record = MeetingRecord(createdAt: now, title: title ?? eventTitle ?? Self.defaultTitle(appName: appName, date: now), appName: appName)
        if let event {
            record.calendarEventID = event.id
            record.participants = event.participants
            Log.calendar.info("Meeting linked to a calendar event with \(event.participants.count, privacy: .public) participant(s)")
        }
        do {
            try await env.database.createMeeting(record)
        } catch {
            lastError = error.localizedDescription
            Log.data.error("Meeting could not be created: \(error.localizedDescription, privacy: .public)")
            return
        }
        lastError = nil
        systemAudioIssue = nil
        transcriptionProblem = nil
        liveSegments = []
        partials = [:]
        interruptions = []
        systemWatch.withLock { $0 = SystemTrackWatch() }
        // Before the sources: a take already muting the output is undone right away.
        env.setMuteSuppressed(true)

        let database = env.database
        let transcriber = env.makeTranscriber(record.id, env.language()) { segment in
            do {
                try await database.appendSegment(segment)
            } catch {
                Log.data.error("Meeting segment could not be saved: \(error.localizedDescription, privacy: .public)")
            }
        }
        self.transcriber = transcriber
        await transcriber.start()
        updatesTask = Task { [weak self] in
            for await update in transcriber.updates {
                self?.apply(update)
            }
        }

        let meFeed = MeetingTrackFeed(track: .me, writer: makeWriter(record.id, .me), transcriber: transcriber, startedAt: clockStart)
        let themFeed = MeetingTrackFeed(track: .them, writer: makeWriter(record.id, .them), transcriber: transcriber, startedAt: clockStart)
        feeds = [.me: meFeed, .them: themFeed]

        // The mic first: opening it before the tap lets a Bluetooth headset settle its profile.
        let mic = env.makeMic()
        do {
            try await run { try mic.start { samples in meFeed.deliver(samples, session: 0) } }
            self.mic = mic
        } catch {
            lastError = error.localizedDescription
            Log.audio.error("Meeting mic could not start: \(error.localizedDescription, privacy: .public)")
        }

        let system = env.makeSystem()
        let systemSink = makeSystemSink(feed: themFeed)
        do {
            try await run { try system.start(onSamples: systemSink) }
            self.system = system
        } catch {
            systemAudioIssue = .unavailable(error.localizedDescription)
            Log.audio.error("System audio could not start: \(error.localizedDescription, privacy: .public)")
        }

        guard self.mic != nil || self.system != nil else {
            await abort(meetingID: record.id)
            return
        }
        phase = .recording(meetingID: record.id, startedAt: now)
        linkedEvent = event
        showsConsentReminder = true
        watchOutputRoute()
        Log.audio.info("Meeting recording started")
    }

    /// No speech model on disk: nothing starts (no row, no folder, no sources) and Spotkania
    /// shows why, with the way to Modele.
    private func refuseWithoutSpeechModel() {
        needsSpeechModel = true
        lastError = String(localized: "Brakuje modelu mowy. Pobierz go w zakładce Modele.")
        Log.audio.error("Meeting not started: the speech model is not downloaded")
    }

    /// Checks the default output now and every `outputRouteInterval` until the stop, off the
    /// main actor (a Core Audio read can wait on the audio server).
    private func watchOutputRoute() {
        let check = env.outputUsesBuiltInSpeakers
        routeTask?.cancel()
        routeTask = Task { [weak self] in
            while !Task.isCancelled {
                let builtIn = await Task.detached(priority: .utility) { check() }.value
                guard !Task.isCancelled else { return }
                self?.setUsesBuiltInSpeakers(builtIn)
                try? await Task.sleep(for: Self.outputRouteInterval)
            }
        }
    }

    private func setUsesBuiltInSpeakers(_ value: Bool) {
        if usesBuiltInSpeakers != value {
            usesBuiltInSpeakers = value
        }
    }

    private func stopWatchingOutputRoute() {
        routeTask?.cancel()
        routeTask = nil
        setUsesBuiltInSpeakers(false)
    }

    private func makeWriter(_ meetingID: UUID, _ track: MeetingTrack) -> TrackFileWriter? {
        do {
            return try TrackFileWriter(url: env.trackURL(meetingID, track))
        } catch {
            Log.audio.error("Meeting track file could not be created (\(track.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The "Rozmówcy" sink for the next session of the system source: the feed, then
    /// `SystemTrackWatch`, whose reports hop to the main actor. Silent buffers only ask Core Audio
    /// whether another app plays.
    private func makeSystemSink(feed: MeetingTrackFeed) -> @Sendable ([Float]) -> Void {
        systemSession += 1
        let session = systemSession
        let watch = self.systemWatch
        let expecting = env.expectingSystemAudio
        return { [weak self] samples in
            feed.deliver(samples, session: session)
            let silent = !samples.contains { $0 != 0 }
            let expectingAudio = silent && expecting()
            let now = Date()
            let report = watch.withLock {
                $0.observe(samples, session: session, silent: silent, expectingAudio: expectingAudio, at: now)
            }
            guard report.needsAction else { return }
            Task { @MainActor in
                self?.handle(report)
            }
        }
    }

    private func handle(_ report: SystemTrackWatch.Report) {
        guard case .recording(let meetingID, let startedAt) = phase else { return }
        // Exact zeros from a call nobody spoke in yet look like a denied grant: real audio ends it.
        if report.firstAudio, systemAudioIssue == .noAccess {
            systemAudioIssue = nil
        }
        if report.noAccess {
            Log.audio.warning("System audio is silent while other apps play: no access to system audio?")
            if systemAudioIssue == nil {
                systemAudioIssue = .noAccess
            }
        }
        if let gap = report.gap {
            keepGap(at: gap, startedAt: startedAt)
        }
        switch report.warning {
        case true?:
            Log.audio.warning("System audio still silent after a tap rebuild while other apps play")
            if systemAudioIssue == nil {
                systemAudioIssue = .silent
            }
        case false?:
            if systemAudioIssue == .silent {
                systemAudioIssue = nil
            }
        case nil:
            break
        }
        if report.rebuild {
            rebuildSystem(meetingID: meetingID)
        }
    }

    /// A "przerwa w nagraniu" at `date`, stored on the meeting when it stops.
    private func keepGap(at date: Date, startedAt: Date) {
        let offset = max(0, date.timeIntervalSince(startedAt))
        interruptions.append(offset)
        Log.audio.notice("System audio gap kept at \(offset, format: .fixed(precision: 1)) s")
    }

    /// Only zeros while other apps play, for as long as `SystemTrackWatch` allows: the other side
    /// may be quiet, or the tap hit the HAL zero-buffer bug. The tap is rebuilt on `control` (in
    /// order with a later stop) as a new feed session, so the time it takes is padded. Whether the
    /// silent run becomes a "przerwa w nagraniu" is decided later, by what the rebuilt tap hears.
    private func rebuildSystem(meetingID: UUID) {
        guard let system, let feed = feeds[.them] else { return }
        Log.audio.warning("System audio is only zeros while other apps play, rebuilding the tap")
        let sink = makeSystemSink(feed: feed)
        control.async { [weak self] in
            do {
                system.stop()
                try system.start(onSamples: sink)
            } catch {
                let message = error.localizedDescription
                Log.audio.error("System audio tap rebuild failed: \(message, privacy: .public)")
                Task { @MainActor in
                    self?.systemRebuildFailed(message, meetingID: meetingID)
                }
            }
        }
    }

    private func systemRebuildFailed(_ message: String, meetingID: UUID) {
        guard case .recording(let current, let startedAt) = phase, current == meetingID else { return }
        systemAudioIssue = .unavailable(message)
        // No tap anymore: the other side is missing from where the zeros began.
        if let gap = systemWatch.withLock({ $0.rebuildFailed() }) {
            keepGap(at: gap, startedAt: startedAt)
        }
    }

    private func apply(_ update: MeetingLiveUpdate) {
        switch update {
        case .segment(let segment):
            liveSegments = Self.liveTranscript(adding: segment, to: liveSegments)
        case .partial(let track, let text):
            partials[track] = text.isEmpty ? nil : text
        case .problem(let problem):
            if let problem {
                Log.transcription.warning("Meeting speech is not turning into lines: \(String(describing: problem), privacy: .public)")
            }
            transcriptionProblem = problem
        }
    }

    // MARK: Stop

    func stop() async {
        guard case .recording(let id, let startedAt) = phase else { return }
        let duration = elapsed()
        phase = .finishing(meetingID: id)
        linkedEvent = nil
        stopWatchingOutputRoute()
        showsConsentReminder = false
        lastError = nil
        previewLevels = nil
        let mic = self.mic
        let system = self.system
        self.mic = nil
        self.system = nil
        try? await run {
            mic?.stop()
            system?.stop()
        }
        // Still warning that the other side cannot be heard: they may be missing from there on.
        if let gap = systemWatch.withLock({ $0.finish() }) {
            keepGap(at: gap, startedAt: startedAt)
        }
        for feed in feeds.values { feed.close() }
        feeds = [:]
        env.setMuteSuppressed(false)

        if let transcriber {
            let result = await transcriber.finish()
            do {
                try await env.database.updateSegments(result.echoChanges)
            } catch {
                Log.data.error("Meeting echo marks could not be saved: \(error.localizedDescription, privacy: .public)")
            }
            await updatesTask?.value
            liveSegments = result.segments.filter { !$0.isEcho }
        }
        updatesTask = nil
        transcriber = nil
        partials = [:]
        transcriptionProblem = nil

        let gaps = interruptions
        await updateMeeting(id) {
            $0.status = .processing
            $0.duration = duration
            $0.interruptions = gaps
        }
        lastFinishedMeetingID = id
        phase = .idle
        Log.audio.info("Meeting recording finished")
        postProcess(id)
    }

    /// The post-processors for `id`, then "completed", in the background: after the meeting
    /// stopped before it is done, so they never run for two meetings at once (the diarizer and
    /// the AI call are heavy, and retention must follow the speaker labels of the same meeting).
    private func postProcess(_ id: UUID) {
        let previous = postProcessing
        let processors = env.postProcessors
        let database = env.database
        postProcessing = Task { [weak self] in
            await previous?.value
            for processor in processors {
                await processor.process(meetingID: id)
            }
            do {
                try await database.modifyMeeting(id: id) { $0.status = .completed }
            } catch {
                Log.data.error("Meeting could not be marked completed: \(error.localizedDescription, privacy: .public)")
            }
            self?.processedCount += 1
            Log.audio.info("Meeting post-processing finished")
        }
    }

    /// Returns once every meeting stopped so far is processed and reads "completed".
    func waitForPostProcessing() async {
        await postProcessing?.value
    }

    /// Quit (`applicationWillTerminate`), synchronous: stops both sources and closes the track
    /// files so they are finalized. The row stays "recording" with every segment saved so far
    /// and becomes "interrupted" at the next launch; the utterances still open are lost.
    func abortForTermination() {
        guard case .recording = phase else { return }
        Log.app.notice("Meeting recording cut short by quit")
        stopWatchingOutputRoute()
        let mic = self.mic
        let system = self.system
        self.mic = nil
        self.system = nil
        control.sync {
            mic?.stop()
            system?.stop()
        }
        for feed in feeds.values { feed.close() }
        feeds = [:]
        env.setMuteSuppressed(false)
        updatesTask?.cancel()
        updatesTask = nil
        transcriber = nil
        partials = [:]
        transcriptionProblem = nil
        linkedEvent = nil
        phase = .idle
    }

    /// Neither source started: nothing was recorded, so neither the row nor the folder is kept.
    private func abort(meetingID: UUID) async {
        for feed in feeds.values { feed.close() }
        feeds = [:]
        env.setMuteSuppressed(false)
        if let transcriber {
            _ = await transcriber.finish()
        }
        await updatesTask?.value
        updatesTask = nil
        transcriber = nil
        liveSegments = []
        partials = [:]
        transcriptionProblem = nil
        do {
            try await env.database.deleteMeeting(id: meetingID)
        } catch {
            Log.data.error("Meeting that never started could not be removed: \(error.localizedDescription, privacy: .public)")
        }
        let files = FileManager.default
        for track in MeetingTrack.allCases {
            try? files.removeItem(at: env.trackURL(meetingID, track))
        }
        let folder = env.trackURL(meetingID, .me).deletingLastPathComponent()
        if (try? files.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? files.removeItem(at: folder)
        }
        Log.audio.error("Meeting recording could not start: no audio source")
    }

    // MARK: Helpers

    /// Blocking source work on `control`. It is queued before the first suspension, so calls
    /// run in the order they were made (a tap rebuild before a later stop).
    private func run(_ work: @escaping @Sendable () throws -> Void) async throws {
        let control = self.control
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            control.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// In one step on the database actor: notes typed while the meeting stops survive.
    private func updateMeeting(_ id: UUID, _ change: @Sendable (inout MeetingRecord) -> Void) async {
        do {
            try await env.database.modifyMeeting(id: id, change)
        } catch {
            Log.data.error("Meeting could not be updated: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Design preview

    #if DEBUG
    /// `--design-preview main-spotkania` with `CAPTYLO_PREVIEW_LIVE`: shows `meetingID` as
    /// recording for `elapsed` seconds with these lines and meter levels, without audio, files
    /// or a transcriber. The consent card is up, like after a real start.
    func previewLive(
        meetingID: UUID,
        segments: [MeetingSegmentRecord],
        partials: [MeetingTrack: String],
        elapsed: TimeInterval,
        levels: [MeetingTrack: Float],
        issue: SystemAudioIssue? = nil,
        problem: MeetingLiveUpdate.Problem? = nil,
        builtInSpeakers: Bool = false
    ) {
        phase = .recording(meetingID: meetingID, startedAt: Date().addingTimeInterval(-elapsed))
        liveSegments = segments
        self.partials = partials
        systemAudioIssue = issue
        transcriptionProblem = problem
        usesBuiltInSpeakers = builtInSpeakers
        showsConsentReminder = true
        previewLevels = levels
    }

    /// `--design-preview main-spotkania` with `CAPTYLO_PREVIEW_START=nomodel`: the state a start
    /// leaves without the speech model, without touching the recorder otherwise.
    func previewMissingSpeechModel() {
        refuseWithoutSpeechModel()
    }
    #endif
}
