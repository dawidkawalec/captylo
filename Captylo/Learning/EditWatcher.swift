import AppKit
import ApplicationServices
import os

/// Self-learning stage 3: watches the text field Captylo just pasted into and hands the user's
/// corrections of that text to `CorrectionLearning`. Read-only Accessibility, polled twice a
/// second and ten times a second while the user edits, only the pasted field, never secure fields
/// or excluded apps. The watch ends when the focus leaves the field or the app, when the next
/// dictation starts, or after `idleLimit`. A take dictated over words selected in a recent paste
/// is a correction by voice: the selection and the new take are learned as a pair.
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
    /// Twice a second while nothing happens in the field.
    static let pollInterval: Duration = .milliseconds(500)
    /// While the user edits (the text or the selection moved in the last `activeWindow`): in a
    /// chat box the fix and Enter come a few hundred milliseconds apart, and the text that counts
    /// is the last one read before Enter cleared the box.
    static let activePollInterval: Duration = .milliseconds(100)
    static let activeWindow: TimeInterval = 3
    /// A dictation over a selection in a field watched this recently is a correction by voice.
    static let voiceFixWindow: TimeInterval = 120
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
        var lastSelection: NSRange?
        /// Last change of the text or the selection (picks `activePollInterval`).
        var lastActivity: Date
    }

    /// A finished watch, kept for `voiceFixWindow`: a take that replaces a selection inside its
    /// text is a correction by voice.
    private struct Finished {
        let element: AXElementRef
        let pid: pid_t
        let bundleID: String?
        let anchor: EditSpan.Anchor
        let ended: Date
    }

    /// The selected words a take is about to replace by voice, learned against it in `didPaste`.
    private struct VoiceFix {
        let selected: String
        let bundleID: String?
    }

    private let learning: any CorrectionLearning
    private let isEnabled: @MainActor () -> Bool
    /// The user's own exclusions (Ustawienia > Nauka > Wykluczone aplikacje).
    private let userExcluded: @MainActor () -> [String]
    private var pending: Target?
    private var watch: Watch?
    private var finished: Finished?
    private var voiceFix: VoiceFix?
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
        voiceFix = nil
        guard let front = watchableFrontApp() else { return }
        let pid = front.processIdentifier
        let found = await Self.offMain(deadline: Self.snapshotDeadline) { () -> (AXElementRef, AXText.Snapshot)? in
            // Electron apps expose their fields only after this (cheap, idempotent).
            AXText.enableManualAccessibility(pid: pid)
            guard let element = AXText.focusedElement(pid: pid) else { return nil }
            return (AXElementRef(element: element), AXText.snapshot(of: element))
        }
        guard let (element, snapshot) = found ?? nil, snapshot.pid == pid else {
            learning.noteUnreadable(appBundleID: front.bundleIdentifier)
            return
        }
        guard !snapshot.isSecure else { return }
        // Words of a recent paste selected and now replaced by this take: a correction by voice.
        if let finished, finished.pid == pid, Date().timeIntervalSince(finished.ended) < Self.voiceFixWindow,
           CFEqual(finished.element.element, element.element), let value = snapshot.value,
           let selected = Self.selectionInsidePaste(value: value, selection: snapshot.selection, anchor: finished.anchor) {
            voiceFix = VoiceFix(selected: selected, bundleID: finished.bundleID)
        }
        pending = Target(element: element, pid: pid, bundleID: snapshot.bundleID, before: snapshot.value ?? "")
    }

    /// The selected words when they are 1...3 words inside the earlier paste (found again by its
    /// anchor), else nil.
    nonisolated static func selectionInsidePaste(value: String, selection: NSRange?, anchor: EditSpan.Anchor) -> String? {
        let text = value as NSString
        guard let selection, selection.length > 0, NSMaxRange(selection) <= text.length,
              let paste = EditSpan.extract(from: value, anchor: anchor) else { return nil }
        let selected = text.substring(with: selection).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty, TokenDiff.words(selected).count <= CorrectionLearner.maxTermWords,
              paste.contains(selected) else { return nil }
        return selected
    }

    func didPaste(_ text: String) {
        if let fix = voiceFix {
            voiceFix = nil
            learning.learn(delivered: fix.selected, corrected: text.trimmingCharacters(in: .whitespacesAndNewlines), appBundleID: fix.bundleID)
        }
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
                started: now,
                lastActivity: now
            )
            Log.learning.debug("Watching a paste in \(target.bundleID ?? "?", privacy: .public)")
            await poll()
            return
        }
        task = nil
        Log.learning.debug("Paste not readable in \(target.bundleID ?? "?", privacy: .public), not watching")
        learning.noteUnreadable(appBundleID: target.bundleID)
    }

    private func poll() async {
        while !Task.isCancelled, let active = watch?.lastActivity {
            let isActive = Date().timeIntervalSince(active) < Self.activeWindow
            try? await Task.sleep(for: isActive ? Self.activePollInterval : Self.pollInterval)
            guard !Task.isCancelled, let target = watch?.target else { return }
            let pid = target.pid
            let element = target.element
            var read: (value: String, selection: NSRange?)?
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                // The field's own AXFocused first: Chrome keeps a closed tab's field as the app's
                // focused element. nil (no answer in time) counts as focus lost.
                read = await Self.offMain(deadline: Self.readDeadline) { () -> (value: String, selection: NSRange?)? in
                    let focused = AXText.isFocused(element.element)
                        ?? (AXText.focusedElement(pid: pid).map { CFEqual($0, element.element) } == true)
                    guard focused, let value = AXText.value(of: element.element) else { return nil }
                    return (value, AXText.selection(of: element.element))
                } ?? nil
            }
            let value = read?.value
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
                    current.lastActivity = now
                    current.edited = true
                }
                // Selecting a word to retype it comes before the edit: poll fast from there on.
                if read?.selection != current.lastSelection {
                    current.lastSelection = read?.selection
                    current.lastActivity = now
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
        finished = Finished(
            element: current.target.element,
            pid: current.target.pid,
            bundleID: current.target.bundleID,
            anchor: current.anchor,
            ended: Date()
        )
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
