import AppKit
import Observation

/// Owns the local event monitor and the capture session for `HotkeyRecorderView`.
@MainActor
@Observable
final class HotkeyCaptureModel {
    enum Result: Sendable, Equatable {
        case captured(Hotkey)
        case cancelled
    }

    private(set) var isCapturing = false
    private(set) var preview: Hotkey?
    var errorText: String?

    /// Safety net: capture never keeps the global hotkey paused longer than this.
    static let captureTimeout: Duration = .seconds(30)

    @ObservationIgnored private var session = HotkeyCaptureSession()
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var onResult: ((Result) -> Void)?

    /// Starts capturing. The local monitor only sees keys while our window is key (gotcha 44), and
    /// the global tap stays paused meanwhile, so capture cancels itself as soon as it can no longer
    /// receive keys: the window resigns key, the app resigns active, or `captureTimeout` passes.
    func begin(onResult: @escaping (Result) -> Void) {
        end()
        self.onResult = onResult
        isCapturing = true
        preview = nil
        session.reset()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // NSEvent is not Sendable: pull the integer fields out before hopping.
            let type = event.type
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isCapturing else { return false }
                self.handle(type: type, keyCode: keyCode, flags: flags)
                return true
            }
            return consumed ? nil : event
        }

        let center = NotificationCenter.default
        let cancelOnMain: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelBecauseUnreachable() }
        }
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: cancelOnMain),
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: NSApp.keyWindow, queue: .main, using: cancelOnMain),
        ]
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.captureTimeout)
            guard !Task.isCancelled else { return }
            self?.cancelBecauseUnreachable()
        }
    }

    /// Reports `.cancelled` so the owner restores the saved hotkey on the tap.
    private func cancelBecauseUnreachable() {
        guard isCapturing else { return }
        Log.hotkey.info("Hotkey capture cancelled: the window can no longer receive keys")
        if let onResult {
            onResult(.cancelled)
        }
        end()
    }

    /// Clears the chord in progress but keeps capturing (after a validation error).
    func restart() {
        session.reset()
        preview = nil
    }

    func end() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        timeoutTask?.cancel()
        timeoutTask = nil
        isCapturing = false
        preview = nil
        onResult = nil
        session.reset()
    }

    /// Feeds one event into the session; exposed for tests.
    func handle(type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        let outcome: HotkeyCaptureSession.Outcome
        switch type {
        case .keyDown:
            outcome = session.keyDown(keyCode: keyCode, flags: flags)
        case .flagsChanged:
            outcome = session.flagsChanged(keyCode: keyCode, flags: flags)
        default:
            return
        }
        switch outcome {
        case .pending(let chord):
            preview = chord
        case .captured(let hotkey):
            preview = hotkey
            onResult?(.captured(hotkey))
        case .cancelled:
            onResult?(.cancelled)
        }
    }
}
