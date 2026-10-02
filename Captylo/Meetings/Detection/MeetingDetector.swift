import AppKit
import ApplicationServices
import Foundation

/// Asks to record when a call starts and to stop when it ends; never records or stops on its own
/// without a visible prompt.
///
/// Every `pollInterval` it reads which processes hold the mic (Core Audio, no permission), maps
/// them through `MeetingAppCatalog` and feeds `DetectionTracker`. A browser only counts when one
/// of its windows or tabs names a call service ("Meet", "Teams", ...), read through the
/// Accessibility grant Captylo already has for the hotkey (`BrowserCallWindows`); without the
/// grant browsers are skipped. Once a browser is in a call it keeps counting without the title,
/// so leaving the Meet tab mid-call does not end the call; a browser that holds the mic for
/// `browserIdleAfter` while its tab strip shows no call tab is dropped (the user left Meet,
/// another tab uses the mic). A browser whose tabs cannot be read (one tab per window, Arc's
/// sidebar) keeps counting until it releases the mic. Titles are only compared, never logged
/// or kept.
///
/// - A call starts while no meeting records: "Wygląda na spotkanie w Zoom. Nagrać notatki?"
///   with "Nagraj", which opens Spotkania (the live bar must be on screen) and starts the
///   recorder. With a calendar event matching now the offer names it ("Wygląda na spotkanie
///   „Budżet Q4” w Zoom...") and "Nagraj" links the recording to that event. A call that
///   starts while the last meeting is still finishing (back-to-back calls) is asked about as
///   soon as the recorder is idle, if it still runs.
/// - A call that held the mic during this recording ends: "Spotkanie w Zoom zakończone? Kończę
///   notatki za 15 s." with "Nagrywaj dalej"; the recorder stops after `stopDelay` unless the
///   button was pressed, the app took the mic again or the recording was stopped by hand. The
///   call ends after 45 s without the mic, at once when the app's process quit
///   (`NSWorkspace.didTerminateApplicationNotification`), and after `overrunEndAfter` when the
///   recording's calendar event is over for more than `eventOverrun` ("„Budżet Q4” już się
///   skończyło? Kończę notatki za 15 s."). No prompt while another call of the same recording
///   still runs, and none for a call that was over before a manual recording began.
///
/// "Wykrywaj spotkania" is read on every poll: off means no scans, no prompts and no pending stop.
@MainActor
final class MeetingDetector {
    /// Apps in a call right now; `keeping` names the apps already in a call (browsers among them
    /// skip the window title check and report whether a call window is still there).
    typealias Scan = @MainActor (_ keeping: Set<String>) async -> CallScan

    nonisolated static let pollInterval: Duration = .seconds(2)
    nonisolated static let stopDelay: Duration = .seconds(15)
    /// A browser in a call that holds the mic this long without a call window or tab stops
    /// counting.
    nonisolated static let browserIdleAfter: Double = 30
    /// The recording's calendar event over for this long: the call ends after `overrunEndAfter`
    /// without the mic instead of the tracker's 45 s.
    nonisolated static let eventOverrun: TimeInterval = 5 * 60
    nonisolated static let overrunEndAfter: Double = 15

    /// The calls that held the mic while this meeting recorded.
    private struct Link {
        let meetingID: UUID
        var apps: Set<String> = []
    }

    private struct PendingStop {
        let meetingID: UUID
        let appName: String
        let task: Task<Void, Never>
    }

    /// `NotificationCenter` tokens are not Sendable; the wrapper lets `deinit` remove them.
    private struct ObserverToken: @unchecked Sendable {
        let token: any NSObjectProtocol
    }

    private let recorder: MeetingRecorder
    private let toasts: any ToastPresenting
    private let isEnabled: @MainActor () -> Bool
    private let openMeetings: @MainActor () -> Void
    private let scan: Scan
    private let clock: @MainActor () -> Double
    private let currentEvent: @MainActor () -> CalendarEvent?
    private let stopDelay: Duration
    private let freshTracker: DetectionTracker

    private var tracker: DetectionTracker
    /// When the last "Nagrać notatki?" offer was shown; `CalendarReminder` stays quiet about an
    /// event right after it, so one call never gets two offers at once.
    private(set) var lastOfferAt: Date?
    /// When `CalendarReminder` last asked (`lastReminderAt`); a call that starts within
    /// `reminderQuiet` of it while that event still matches gets no second offer. Set by
    /// `AppState` once both exist.
    var recentReminder: @MainActor () -> Date? = { nil }
    /// Seconds after a calendar reminder during which the detector keeps quiet about the event.
    nonisolated static let reminderQuiet: TimeInterval = 2 * 60
    /// Apps whose call started and has not ended.
    private var inCall: Set<String> = []
    private var link: Link?
    private var pendingStop: PendingStop?
    /// Calls that started while the recorder was finishing the last meeting, in start order.
    private var deferredOffers: [MeetingApp] = []
    /// Call apps whose process terminated since the last poll (`appDidQuit`).
    private var quitSincePoll: Set<String> = []
    /// Browsers in a call, by name, and since when they hold the mic without a call window.
    private var browserWithoutCallSince: [String: Double] = [:]
    private var loop: Task<Void, Never>?
    private var quitObserver: ObserverToken?

    /// - Parameters:
    ///   - openMeetings: brings the main window forward on Spotkania before a detected meeting starts.
    ///   - scan: nil reads Core Audio and the browsers' window titles off the main actor.
    ///   - clock: seconds on a monotonic clock.
    ///   - currentEvent: the calendar event matching now (`MeetingCalendar.currentEvent()`),
    ///     the same closure the recorder gets; nil without the calendar.
    init(
        recorder: MeetingRecorder,
        toasts: any ToastPresenting,
        isEnabled: @escaping @MainActor () -> Bool,
        openMeetings: @escaping @MainActor () -> Void,
        scan: Scan? = nil,
        clock: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
        currentEvent: @escaping @MainActor () -> CalendarEvent? = { nil },
        tracker: DetectionTracker = DetectionTracker(),
        stopDelay: Duration = MeetingDetector.stopDelay
    ) {
        self.recorder = recorder
        self.toasts = toasts
        self.isEnabled = isEnabled
        self.openMeetings = openMeetings
        self.scan = scan ?? { keeping in await MeetingDetector.liveScan(keeping: keeping) }
        self.clock = clock
        self.currentEvent = currentEvent
        self.stopDelay = stopDelay
        freshTracker = tracker
        self.tracker = tracker
    }

    deinit {
        if let quitObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(quitObserver.token)
        }
    }

    /// A stop countdown is running (the "Nagrywaj dalej" toast is up).
    var isStopPending: Bool { pendingStop != nil }

    // MARK: Lifecycle

    /// Starts polling and watching for quit call apps. Idempotent.
    func start() {
        guard loop == nil else { return }
        if quitObserver == nil {
            let token = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let bundleID = app?.bundleIdentifier else { return }
                MainActor.assumeIsolated {
                    self?.appDidQuit(bundleID: bundleID)
                }
            }
            quitObserver = ObserverToken(token: token)
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: MeetingDetector.pollInterval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        if let quitObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(quitObserver.token)
        }
        quitObserver = nil
        reset()
    }

    /// A process terminated: when it is a call app itself, its call ends at the next poll without
    /// the 45 s wait (the observer's body; tests call it directly). Helpers (a Chrome renderer
    /// quits with every closed tab, Teams and WebKit helpers come and go during a call) are not
    /// the app and change nothing.
    func appDidQuit(bundleID: String) {
        guard MeetingAppCatalog.isMainApp(bundleID: bundleID),
              let app = MeetingAppCatalog.app(forBundleID: bundleID)
        else { return }
        quitSincePoll.insert(app.name)
    }

    /// One poll (the loop's body; tests call it directly).
    func tick() async {
        guard isEnabled() else {
            reset()
            return
        }
        let scan = await scan(inCall)
        // Switched off while the scan ran.
        guard isEnabled() else {
            reset()
            return
        }
        let now = clock()
        let quit = quitSincePoll
        quitSincePoll = []
        let apps = dropIdleBrowsers(scan, at: now)
        let present = Set(apps.map(\.name))
        let overrunEvent = overrunEvent()
        let endAfter = overrunEvent == nil ? nil : MeetingDetector.overrunEndAfter
        for event in tracker.update(apps: apps, at: now, quit: quit, endAfter: endAfter) {
            switch event {
            case .started(let app):
                inCall.insert(app.name)
                offerToRecord(app)
            case .ended(let app):
                inCall.remove(app.name)
                browserWithoutCallSince[app.name] = nil
                offerToStop(app, overrunEvent: overrunEvent)
            }
        }
        offerDeferred()
        linkCalls(present: present)
        if let pendingStop {
            if recorder.currentMeetingID != pendingStop.meetingID {
                // Stopped by hand (or already the next meeting): the countdown is moot.
                cancelPendingStop()
            } else if present.contains(pendingStop.appName) {
                // The app took the mic again during the countdown: the call goes on.
                Log.audio.info("Call resumed in \(pendingStop.appName, privacy: .public), meeting keeps recording")
                cancelPendingStop()
            }
        }
    }

    /// The scan's apps without the browsers that held the mic for `browserIdleAfter` with no
    /// call window or tab: the user left the call, something else in the browser uses the mic.
    private func dropIdleBrowsers(_ scan: CallScan, at now: Double) -> [MeetingApp] {
        let idle = scan.browsersWithoutCallWindow.intersection(inCall)
        browserWithoutCallSince = browserWithoutCallSince.filter { idle.contains($0.key) }
        var dropped: Set<String> = []
        for name in idle {
            let since = browserWithoutCallSince[name] ?? now
            browserWithoutCallSince[name] = since
            if now - since >= MeetingDetector.browserIdleAfter {
                dropped.insert(name)
            }
        }
        guard !dropped.isEmpty else { return scan.apps }
        return scan.apps.filter { !dropped.contains($0.name) }
    }

    /// The recording's calendar event when it ended more than `eventOverrun` ago.
    private func overrunEvent() -> CalendarEvent? {
        guard recorder.isRecording, let event = recorder.linkedEvent,
              Date().timeIntervalSince(event.end) > MeetingDetector.eventOverrun
        else { return nil }
        return event
    }

    // MARK: Prompts

    private func offerToRecord(_ app: MeetingApp) {
        // The tracker reports a start once: keep it for when the last meeting is finished.
        if case .finishing = recorder.phase {
            if !deferredOffers.contains(app) {
                deferredOffers.append(app)
            }
            return
        }
        guard recorder.phase == .idle, !recorder.isStarting else { return }
        // The event shown is the one "Nagraj" links, even when the calendar matches another by then.
        let event = currentEvent()
        Log.audio.info("Call detected in \(app.name, privacy: .public)\(event == nil ? "" : ", a calendar event matches", privacy: .public)")
        // The reminder already asked about this event: the user answered (or chose not to), and
        // the call is linked to a recording they start anyway (`linkCalls`).
        if event != nil, let remindedAt = recentReminder(), abs(Date().timeIntervalSince(remindedAt)) < Self.reminderQuiet {
            Log.audio.info("Call offer skipped: the calendar reminder asked just now")
            return
        }
        let message: String
        if let event, !event.title.isEmpty {
            message = String(localized: "Wygląda na spotkanie „\(event.title)” w \(app.name). Nagrać notatki?")
        } else {
            message = String(localized: "Wygląda na spotkanie w \(app.name). Nagrać notatki?")
        }
        lastOfferAt = Date()
        toasts.showAction(message: message, buttonTitle: String(localized: "Nagraj")) { [weak self] in
            self?.record(app, event: event)
        }
    }

    /// The calls kept by `offerToRecord` while the recorder finished: asked about once it is
    /// idle, if they still run. A recording started meanwhile takes them in instead.
    private func offerDeferred() {
        guard !deferredOffers.isEmpty else { return }
        deferredOffers.removeAll { !inCall.contains($0.name) }
        if case .finishing = recorder.phase { return }
        let waiting = deferredOffers
        deferredOffers = []
        for app in waiting {
            offerToRecord(app)
        }
    }

    private func record(_ app: MeetingApp, event: CalendarEvent?) {
        guard recorder.phase == .idle, !recorder.isStarting else { return }
        // Spotkania first: a meeting never records without its live bar on screen.
        openMeetings()
        let recorder = self.recorder
        Task { await recorder.start(appName: app.name, event: event) }
    }

    /// - Parameter overrunEvent: the recording's calendar event when it is long over; the toast
    ///   then names the event instead of the app.
    private func offerToStop(_ app: MeetingApp, overrunEvent: CalendarEvent?) {
        guard pendingStop == nil, recorder.isRecording,
              let meetingID = recorder.currentMeetingID,
              let link, link.meetingID == meetingID, link.apps.contains(app.name),
              link.apps.isDisjoint(with: inCall)
        else { return }
        Log.audio.info("Call ended in \(app.name, privacy: .public)\(overrunEvent == nil ? "" : " after its calendar event", privacy: .public), asking to stop the meeting")
        let message: String
        if let overrunEvent, !overrunEvent.title.isEmpty {
            message = String(localized: "„\(overrunEvent.title)” już się skończyło? Kończę notatki za 15 s.")
        } else {
            message = String(localized: "Spotkanie w \(app.name) zakończone? Kończę notatki za 15 s.")
        }
        let delay = stopDelay
        let parts = delay.components
        toasts.showAction(
            message: message,
            buttonTitle: String(localized: "Nagrywaj dalej"),
            lifetime: Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        ) { [weak self] in
            self?.cancelPendingStop()
        }
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.stopAfterCall(meetingID: meetingID)
        }
        pendingStop = PendingStop(meetingID: meetingID, appName: app.name, task: task)
    }

    private func stopAfterCall(meetingID: UUID) async {
        pendingStop = nil
        // Stopped by hand meanwhile, or already the next meeting: leave it alone.
        guard recorder.isRecording, recorder.currentMeetingID == meetingID else { return }
        Log.audio.info("Stopping the meeting after its call ended")
        await recorder.stop()
    }

    private func cancelPendingStop() {
        pendingStop?.task.cancel()
        pendingStop = nil
    }

    /// Calls in progress that hold the mic during this recording become part of it.
    private func linkCalls(present: Set<String>) {
        guard recorder.isRecording, let meetingID = recorder.currentMeetingID else {
            link = nil
            return
        }
        if link?.meetingID != meetingID {
            link = Link(meetingID: meetingID)
        }
        link?.apps.formUnion(inCall.intersection(present))
    }

    /// `lastOfferAt` stays: an offer already shown still counts for the calendar reminder.
    private func reset() {
        tracker = freshTracker
        inCall = []
        link = nil
        deferredOffers = []
        quitSincePoll = []
        browserWithoutCallSince = [:]
        cancelPendingStop()
    }

    // MARK: Live scan

    /// Core Audio and Accessibility reads can wait on other processes: never on the main actor.
    nonisolated static func liveScan(keeping: Set<String>) async -> CallScan {
        await Task.detached(priority: .utility) { appsInCalls(keeping: keeping) }.value
    }

    /// Known call apps holding the mic, and browsers holding it with a call window or tab (or
    /// already in a call, `keeping`; those report when their tabs show no call any more).
    /// Captylo itself never counts.
    nonisolated static func appsInCalls(keeping: Set<String>) -> CallScan {
        let own = ProcessInfo.processInfo.processIdentifier
        let canReadTitles = AXIsProcessTrusted()
        var scan = CallScan(apps: [])
        var windowChecks: [String: BrowserCallWindows.Check] = [:]
        for process in CoreAudioProcesses.usingInput() where process.pid != own {
            guard let app = MeetingAppCatalog.app(forBundleID: process.bundleID), !scan.apps.contains(app) else { continue }
            if app.isBrowser {
                let kept = keeping.contains(app.name)
                // Without the grant a browser never starts a call, and a kept one keeps counting.
                guard canReadTitles else {
                    if kept { scan.apps.append(app) }
                    continue
                }
                let owner = MeetingAppCatalog.windowOwner(forBundleID: process.bundleID) ?? process.bundleID
                let check = windowChecks[owner] ?? BrowserCallWindows.check(owner: owner, fallbackPID: process.pid)
                windowChecks[owner] = check
                guard check == .call || kept else { continue }
                if check == .noCall {
                    scan.browsersWithoutCallWindow.insert(app.name)
                }
            }
            scan.apps.append(app)
        }
        return scan
    }
}
