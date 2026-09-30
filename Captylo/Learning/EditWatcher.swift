import AppKit
import ApplicationServices
import os

/// Self-learning stage 3: watches the text field Captylo just pasted into and hands the user's
/// corrections of that text to `CorrectionLearning`. Read-only Accessibility, polled once a
/// second, only the pasted field, never secure fields or excluded apps. The watch ends when the
/// focus leaves the field or the app, when the next dictation starts, or after `idleLimit`.
/// Nothing is stored here: the text lives in memory until the learner has looked at it.
///
/// Every Accessibility call runs off the main actor behind a deadline (`offMain`): the target
/// app answers over IPC, and a busy web view must never hold the widget, the paste or the UI.
@MainActor
final class EditWatcher: PasteWatching {
    /// Watching stops after this long without an edit.
    static let idleLimit: TimeInterval = 90
    /// And after this long in any case.
    static let hardLimit: TimeInterval = 600
    /// Twice a second: in a chat box the fix and Enter come close together.
    static let pollInterval: Duration = .milliseconds(500)
    /// Delays after Cmd+V before looking for the text (slow apps paste late).
    static let settleDelays: [Duration] = [.milliseconds(500), .milliseconds(1200)]
    /// The field snapshot right before Cmd+V sits on the paste path: no answer by then, no watch.
    static let snapshotDeadline: Duration = .milliseconds(150)
    /// Reads while watching; a field that does not answer in time ends the watch.
    static let readDeadline: Duration = .seconds(2)

    /// Password managers and terminals (their "field" is the whole scrollback).
    static let excludedBundleIDs: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess",
        "com.apple.Passwords", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "io.alacritty",
    ]

    /// Chromium browsers that need `AXEnhancedUserInterface` for their web fields (Arc and
    /// Electron apps answer to `AXManualAccessibility`).
    static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.microsoft.edgemac",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    private struct Target {
        let element: AXElementRef
        let pid: pid_t
        let bundleID: String?
        let before: String
    }

    private struct Watch {
        let target: Target
        let delivered: String
        let anchor: EditSpan.Anchor
        var lastValue: String
        var lastChange: Date
        let started: Date
        var edited = false
    }

    private let learning: any CorrectionLearning
    private let isEnabled: @MainActor () -> Bool
    /// The user's own exclusions (Ustawienia > Nauka > Wykluczone aplikacje).
    private let userExcluded: @MainActor () -> [String]
    private var pending: Target?
    private var watch: Watch?
    private var task: Task<Void, Never>?

    /// A paste is being located or watched (`--watch-paste` waits on this).
    var isWatching: Bool { watch != nil || task != nil }

    init(
        learning: any CorrectionLearning,
        isEnabled: @escaping @MainActor () -> Bool,
        userExcluded: @escaping @MainActor () -> [String] = { [] }
    ) {
        self.learning = learning
        self.isEnabled = isEnabled
        self.userExcluded = userExcluded
    }

    func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return Self.excludedBundleIDs.contains(bundleID) || userExcluded().contains(bundleID)
    }

    // MARK: - PasteWatching

    /// At the start of a take: asks the frontmost app to build its accessibility tree now, so it
    /// is ready when the paste lands (Chromium builds it asynchronously, too late at paste time).
    /// Fire and forget, off the main actor.
    func prepare() {
        guard let front = watchableFrontApp() else { return }
        let pid = front.processIdentifier
        let chromium = Self.chromiumBundleIDs.contains(front.bundleIdentifier ?? "")
        Task.detached(priority: .utility) {
            AXText.enableManualAccessibility(pid: pid)
            if chromium {
                AXText.enableEnhancedUserInterface(pid: pid)
            }
        }
    }

    /// Right before Cmd+V: the focused field and its text, or nothing within `snapshotDeadline`.
    func willPaste() async {
        flush()
        pending = nil
        guard let front = watchableFrontApp() else { return }
        let pid = front.processIdentifier
        let found = await Self.offMain(deadline: Self.snapshotDeadline) { () -> (AXElementRef, AXText.Snapshot)? in
            // Electron apps expose their fields only after this (cheap, idempotent).
            AXText.enableManualAccessibility(pid: pid)
            guard let element = AXText.focusedElement(pid: pid) else { return nil }
            return (AXElementRef(element: element), AXText.snapshot(of: element))
        }
        guard let (element, snapshot) = found ?? nil, !snapshot.isSecure, snapshot.pid == pid else { return }
        pending = Target(element: element, pid: pid, bundleID: snapshot.bundleID, before: snapshot.value ?? "")
    }

    func didPaste(_ text: String) {
        guard let target = pending else { return }
        pending = nil
        task?.cancel()
        task = Task { @MainActor [weak self] in
            await self?.start(target, delivered: text)
        }
    }

    /// Ends the current watch now with the last polled text (at most a second old) and learns
    /// from it. No Accessibility call: it runs on the dictation start path.
    func flush() {
        task?.cancel()
        task = nil
        guard let current = watch else { return }
        finish(current)
    }

    // MARK: - Watch

    private func watchableFrontApp() -> NSRunningApplication? {
        guard isEnabled(), AXIsProcessTrusted(),
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !isExcluded(front.bundleIdentifier) else { return nil }
        return front
    }

    private func start(_ target: Target, delivered: String) async {
        let element = target.element
        for delay in Self.settleDelays {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let after = await Self.offMain(deadline: Self.readDeadline) { AXText.value(of: element.element) } ?? nil
            guard !Task.isCancelled else { return }
            guard let after, let paste = EditSpan.locate(delivered: delivered, before: target.before, after: after) else { continue }
            let now = Date()
            watch = Watch(
                target: target,
                delivered: delivered.trimmingCharacters(in: .whitespacesAndNewlines),
                anchor: EditSpan.anchor(in: after, paste: paste),
                lastValue: after,
                lastChange: now,
                started: now
            )
            Log.learning.debug("Watching a paste in \(target.bundleID ?? "?", privacy: .public)")
            await poll()
            return
        }
        task = nil
        Log.learning.debug("Paste not readable in \(target.bundleID ?? "?", privacy: .public), not watching")
    }

    private func poll() async {
        while !Task.isCancelled, watch != nil {
            try? await Task.sleep(for: Self.pollInterval)
            guard !Task.isCancelled, let target = watch?.target else { return }
            let pid = target.pid
            let element = target.element
            var value: String?
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                // The field's own AXFocused first: Chrome keeps a closed tab's field as the app's
                // focused element. nil (no answer in time) counts as focus lost.
                value = await Self.offMain(deadline: Self.readDeadline) { () -> String? in
                    let focused = AXText.isFocused(element.element)
                        ?? (AXText.focusedElement(pid: pid).map { CFEqual($0, element.element) } == true)
                    return focused ? AXText.value(of: element.element) : nil
                } ?? nil
            }
            // A flush or a new paste may have ended this watch while the read was running.
            guard !Task.isCancelled, var current = watch else { return }
            let now = Date()
            // Our text left the field (a chat message was sent and the box cleared, or it was
            // deleted): end with the last text that still held it, never with the empty box.
            if let value, value != current.lastValue,
               Self.isGone(EditSpan.extract(from: value, anchor: current.anchor), delivered: current.delivered) {
                finish(current)
                return
            }
            if let value {
                if value != current.lastValue {
                    current.lastValue = value
                    current.lastChange = now
                    current.edited = true
                }
                watch = current
                let idle = now.timeIntervalSince(current.lastChange) > Self.idleLimit
                let tooLong = now.timeIntervalSince(current.started) > Self.hardLimit
                if !idle, !tooLong { continue }
            }
            finish(current)
            return
        }
    }

    private func finish(_ current: Watch) {
        watch = nil
        task = nil
        guard isEnabled() else { return }
        // An untouched paste is reported too: it counts as words pasted with nothing changed.
        let corrected = current.edited ? EditSpan.extract(from: current.lastValue, anchor: current.anchor) : current.delivered
        guard let corrected else { return }
        learning.learn(
            delivered: current.delivered,
            corrected: corrected.trimmingCharacters(in: .whitespacesAndNewlines),
            appBundleID: current.target.bundleID
        )
    }

    /// True when the span no longer holds our text: not found, empty, or what the learner would
    /// call noise (under half of the pasted words left; text typed after the paste is ignored).
    nonisolated static func isGone(_ extracted: String?, delivered: String) -> Bool {
        guard let extracted else { return true }
        return CorrectionLearner.analyze(delivered: delivered, corrected: extracted, isRealWord: { _ in true }).isNoise
    }

    // MARK: - Off the main actor

    /// Runs `work` on a background thread and returns its result, or nil when `deadline` passes
    /// first. The late call keeps running on its own thread (AX has its own 0.5 s timeout per
    /// request) and its result is dropped; the caller is never held past the deadline.
    nonisolated static func offMain<T: Sendable>(deadline: Duration, _ work: @escaping @Sendable () -> T) async -> T? {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resumeOnce: @Sendable (T?) -> Void = { value in
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first {
                    continuation.resume(returning: value)
                }
            }
            Task.detached(priority: .userInitiated) {
                resumeOnce(work())
            }
            Task.detached {
                try? await Task.sleep(for: deadline)
                resumeOnce(nil)
            }
        }
    }
}
