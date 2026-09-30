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
    }

    private(set) var phase: Phase = .idle
    /// Finished utterances in time order, without the mic's echo of the other side.
    private(set) var liveSegments: [MeetingSegmentRecord] = []
    /// The grey "w trakcie" line per track.
    private(set) var partials: [MeetingTrack: String] = [:]
    private(set) var systemAudioIssue: SystemAudioIssue?
    private(set) var lastError: String?
    private(set) var lastFinishedMeetingID: UUID?

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
    /// Set from the first line of `start` until it returns: a second click must not open a second meeting.
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private let systemWatch = OSAllocatedUnfairLock(initialState: SystemTrackWatch())

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
        (track == .me ? mic : system)?.level ?? 0
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

    /// Launch step: a meeting left "recording" or "processing" by a crash or quit becomes
    /// "interrupted" with the segments it saved. `start` waits for it, so a meeting started
    /// right after launch is never swept up with them. Runs once.
    func recoverInterruptedMeetings() {
        guard recovery == nil else { return }
        let database = env.database
        recovery = Task {
            do {
                let ids = try await database.markInterruptedMeetings()
                if !ids.isEmpty {
                    Log.data.notice("Marked \(ids.count) interrupted meeting(s)")
                }
            } catch {
                Log.data.error("Interrupted meetings could not be marked: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Start

    func start(title: String? = nil, appName: String? = nil) async {
        guard phase == .idle, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        await recovery?.value

        let now = Date()
        let clockStart = MeetingTrackFeed.now()
        let record = MeetingRecord(createdAt: now, title: title ?? Self.defaultTitle(appName: appName, date: now), appName: appName)
        do {
            try await env.database.createMeeting(record)
        } catch {
            lastError = error.localizedDescription
            Log.data.error("Meeting could not be created: \(error.localizedDescription, privacy: .public)")
            return
        }
        lastError = nil
        systemAudioIssue = nil
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
        Log.audio.info("Meeting recording started")
    }

    private func makeWriter(_ meetingID: UUID, _ track: MeetingTrack) -> TrackFileWriter? {
        do {
            return try TrackFileWriter(url: env.trackURL(meetingID, track))
        } catch {
            Log.audio.error("Meeting track file could not be created (\(track.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The "Rozmówcy" sink for the next session of the system source: the feed, then the
    /// watchdog, whose verdicts hop to the main actor. Silent buffers only ask Core Audio
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
            let (verdict, firstAudio) = watch.withLock {
                $0.observe(samples, silent: silent, expectingAudio: expectingAudio)
            }
            guard verdict != .ok || firstAudio else { return }
            Task { @MainActor in
                self?.handle(verdict, firstAudio: firstAudio)
            }
        }
    }

    private func handle(_ verdict: SilenceWatchdog.Verdict, firstAudio: Bool) {
        guard case .recording(let meetingID, _) = phase else { return }
        // Exact zeros from a call nobody spoke in yet look like a denied grant: real audio ends it.
        if firstAudio, systemAudioIssue == .noAccess {
            systemAudioIssue = nil
        }
        switch verdict {
        case .ok:
            break
        case .noAccess:
            Log.audio.warning("System audio is silent while other apps play: no access to system audio?")
            if systemAudioIssue == nil {
                systemAudioIssue = .noAccess
            }
        case .stalled:
            rebuildSystem(meetingID: meetingID)
        }
    }

    /// The HAL zero-buffer bug: the tap heard audio, then only zeros while apps still play.
    /// The tap is rebuilt on `control` (in order with a later stop) as a new feed session, so the
    /// time it takes is padded; the gap stays on the meeting as "przerwa w nagraniu", at the
    /// moment the zeros began. Once per silent run (`SystemTrackWatch`).
    private func rebuildSystem(meetingID: UUID) {
        guard let system, let feed = feeds[.them] else { return }
        let stallAfter = systemWatch.withLock { $0.dog.stallAfter }
        interruptions.append(max(0, elapsed() - stallAfter))
        Log.audio.warning("System audio stalled, rebuilding the tap")
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
        guard case .recording(let current, _) = phase, current == meetingID else { return }
        systemAudioIssue = .unavailable(message)
    }

    private func apply(_ update: MeetingLiveUpdate) {
        switch update {
        case .segment(let segment):
            liveSegments = Self.liveTranscript(adding: segment, to: liveSegments)
        case .partial(let track, let text):
            partials[track] = text.isEmpty ? nil : text
        }
    }

    // MARK: Stop

    func stop() async {
        guard case .recording(let id, _) = phase else { return }
        let duration = elapsed()
        phase = .finishing(meetingID: id)
        let mic = self.mic
        let system = self.system
        self.mic = nil
        self.system = nil
        try? await run {
            mic?.stop()
            system?.stop()
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

        let gaps = interruptions
        await updateMeeting(id) {
            $0.status = .processing
            $0.duration = duration
            $0.interruptions = gaps
        }
        for processor in env.postProcessors {
            await processor.process(meetingID: id)
        }
        await updateMeeting(id) { $0.status = .completed }
        lastFinishedMeetingID = id
        phase = .idle
        Log.audio.info("Meeting recording finished")
    }

    /// Quit (`applicationWillTerminate`), synchronous: stops both sources and closes the track
    /// files so they are finalized. The row stays "recording" with every segment saved so far
    /// and becomes "interrupted" at the next launch; the utterances still open are lost.
    func abortForTermination() {
        guard case .recording = phase else { return }
        Log.app.notice("Meeting recording cut short by quit")
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

    private func updateMeeting(_ id: UUID, _ change: (inout MeetingRecord) -> Void) async {
        do {
            guard var record = try await env.database.meeting(id: id) else { return }
            change(&record)
            try await env.database.updateMeeting(record)
        } catch {
            Log.data.error("Meeting could not be updated: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The "Rozmówcy" watchdog and what the recorder does with its verdicts, behind one lock: the
/// sink runs on the tap's queue.
private struct SystemTrackWatch: Sendable {
    var dog = SilenceWatchdog()
    /// Set by the `.stalled` verdict that asks for a rebuild, cleared by the next real audio.
    /// A call app keeps its output running and plays exact zeros while the other side is quiet,
    /// so a long quiet stretch would otherwise rebuild the tap, and add a "przerwa w nagraniu",
    /// every `stallAfter` seconds. A rebuild that brought no audio back is not repeated until
    /// the other side is heard again.
    private var rebuiltThisRun = false

    /// The verdict to act on, and whether `samples` are the first real audio of the meeting.
    mutating func observe(_ samples: [Float], silent: Bool, expectingAudio: Bool) -> (verdict: SilenceWatchdog.Verdict, firstAudio: Bool) {
        let heardBefore = dog.heardAudio
        var verdict = dog.observe(samples, expectingAudio: expectingAudio)
        if !silent {
            rebuiltThisRun = false
        } else if verdict == .stalled {
            if rebuiltThisRun {
                verdict = .ok
            } else {
                rebuiltThisRun = true
            }
        }
        return (verdict, !heardBefore && dog.heardAudio)
    }
}
