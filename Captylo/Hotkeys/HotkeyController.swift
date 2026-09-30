import Foundation

/// Hybrid hotkey state machine (brief 4.4, hotkeys note 3.4 / 3.5 / 3.6):
/// - tap (< `holdThreshold`) latches the recording, the next press stops it;
/// - hold (>= `holdThreshold`) is push-to-talk, the release stops it;
/// - `cooldown` between accepted downs, the hotkey is ignored while `phase.isProcessing`;
/// - a non-modifier key within `interruptWindow` of a press that started the recording cancels it silently;
/// - Esc twice within `escWindow` cancels, the first Esc only shows a toast.
///
/// Coordinator calls are chained on one task queue so `stop()` / `cancel()` never overtake a `start()`
/// still in flight; each call re-checks `phase` when it actually runs. The Esc-Esc cancel is the
/// exception: it must abort a `stop()` that is still transcribing, so it runs right away (Esc is armed
/// only after `start()` has created the session, and `cancel()` copes with a start or stop in flight).
@MainActor
final class HotkeyController {
    private let tap: HotkeyTap
    private let coordinator: any RecorderCoordinator
    private let toasts: any ToastPresenting
    private let holdThreshold: TimeInterval
    private let cooldown: TimeInterval
    private let interruptWindow: TimeInterval
    private let escWindow: TimeInterval
    private let clock: () -> TimeInterval

    private var isPressed = false
    private var pressStartedAt: TimeInterval = 0
    private var pressStartedRecording = false
    private var lastAcceptedDownAt: TimeInterval?
    /// Set when `.interrupted` arrives before its `.down` (the two hops raced, gotcha 42).
    private var swallowDownUntil: TimeInterval?
    private var firstEscapeAt: TimeInterval?
    private var lastOperation: Task<Void, Never>?
    private var escapeCancel: Task<Void, Never>?

    /// True while the press that started the current recording is still held: releasing it
    /// either stops (held >= `holdThreshold`) or latches the recording.
    private(set) var isPushToTalkActive = false

    init(
        tap: HotkeyTap,
        coordinator: any RecorderCoordinator,
        toasts: any ToastPresenting,
        holdThreshold: TimeInterval = 0.5,
        cooldown: TimeInterval = 0.3,
        interruptWindow: TimeInterval = 1.0,
        escWindow: TimeInterval = 1.5,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.tap = tap
        self.coordinator = coordinator
        self.toasts = toasts
        self.holdThreshold = holdThreshold
        self.cooldown = cooldown
        self.interruptWindow = interruptWindow
        self.escWindow = escWindow
        self.clock = clock
    }

    /// The hotkey the tap currently matches (nil while the recorder control captures a new one).
    var hotkey: Hotkey? { tap.hotkey }

    /// Entry point for `HotkeyTap.onEvent` (already on the main actor).
    func handle(_ event: HotkeyEvent) {
        switch event {
        case .down(let at):
            handleDown(at: at)
        case .up(let at):
            handleUp(at: at)
        case .interrupted:
            handleInterrupted()
        case .escape:
            handleEscape()
        }
    }

    /// Waits until every coordinator call queued so far has finished (tests, shutdown).
    func awaitPendingOperations() async {
        await escapeCancel?.value
        await lastOperation?.value
    }

    // MARK: Down / up

    private func handleDown(at eventTime: TimeInterval) {
        if let swallowDownUntil {
            self.swallowDownUntil = nil
            if clock() <= swallowDownUntil {
                Log.hotkey.debug("Swallowed a down that raced its interruption")
                return
            }
        }
        guard !isPressed else { return }
        if let last = lastAcceptedDownAt, eventTime - last < cooldown {
            Log.hotkey.debug("Down dropped by cooldown")
            return
        }
        guard !coordinator.phase.isProcessing else {
            Log.hotkey.debug("Down ignored while processing")
            return
        }

        isPressed = true
        pressStartedAt = eventTime
        lastAcceptedDownAt = eventTime
        pressStartedRecording = false
        isPushToTalkActive = false

        if coordinator.phase.isCapturing {
            enqueue { coordinator in
                guard coordinator.phase.isCapturing else { return }
                await coordinator.stop()
            }
        } else {
            pressStartedRecording = true
            isPushToTalkActive = true
            enqueue { coordinator in
                guard coordinator.phase == .idle else { return }
                await coordinator.start()
            }
        }
    }

    private func handleUp(at eventTime: TimeInterval) {
        guard isPressed else { return }
        isPressed = false
        isPushToTalkActive = false
        let startedRecording = pressStartedRecording
        pressStartedRecording = false
        guard startedRecording else { return }

        let held = eventTime - pressStartedAt
        if held >= holdThreshold {
            enqueue { coordinator in
                guard coordinator.phase.isCapturing else { return }
                await coordinator.stop()
            }
        }
        // Short tap: latched, the next press stops the recording.
    }

    // MARK: Interruption and Esc

    private func handleInterrupted() {
        guard isPressed else {
            if coordinator.phase == .idle, !coordinator.isWidgetVisible {
                swallowDownUntil = clock() + interruptWindow
            }
            return
        }
        guard pressStartedRecording, clock() - pressStartedAt <= interruptWindow else { return }
        pressStartedRecording = false
        isPushToTalkActive = false
        Log.hotkey.info("Accidental start cancelled")
        enqueue { coordinator in
            guard coordinator.phase != .idle else { return }
            await coordinator.cancel()
        }
    }

    private func handleEscape() {
        let now = clock()
        if let firstEscapeAt, now - firstEscapeAt <= escWindow {
            self.firstEscapeAt = nil
            // Not chained: a queued cancel would only run after the stop it should abort has pasted.
            let coordinator = self.coordinator
            escapeCancel = Task { @MainActor in
                guard coordinator.phase != .idle else { return }
                await coordinator.cancel()
            }
            return
        }
        firstEscapeAt = now
        toasts.showInfo(String(localized: "Naciśnij Esc ponownie, aby anulować"))
    }

    // MARK: Queue

    private func enqueue(_ operation: @escaping @MainActor (any RecorderCoordinator) async -> Void) {
        let previous = lastOperation
        let coordinator = self.coordinator
        lastOperation = Task { @MainActor in
            await previous?.value
            await operation(coordinator)
        }
    }
}
