import AppKit
import CoreGraphics
import Foundation
import os

/// One `CGEventTap` for keyDown / keyUp / flagsChanged, running on a dedicated thread with its
/// own `CFRunLoop` so a busy main thread never stalls system-wide typing (gotcha 36).
///
/// The callback only does integer compares and posts `HotkeyEvent`s to the main actor.
/// Modifier-only hotkeys pass through to the focused app; combo hotkeys are suppressed on
/// keyDown, autorepeat and keyUp (gotcha 41). Esc is swallowed and reported as `.escape` only
/// while `setEscapeArmed(true)` (the widget is visible). Events stamped with
/// `SyntheticEventMarker.value` are our own synthetic keys and are ignored (gotcha 43).
final class HotkeyTap: @unchecked Sendable {
    /// Marker our synthetic events carry in `eventSourceUserData` (brief 4.4 name).
    static let syntheticMarker: Int64 = SyntheticEventMarker.value

    /// Any non-modifier keyDown this long after `.down` reports `.interrupted` (gotcha 42).
    static let interruptWindow: TimeInterval = 1.0

    /// Result of the hot-path state machine for one event.
    struct Decision: Sendable, Equatable {
        var event: HotkeyEvent?
        var suppress: Bool

        static let passThrough = Decision(event: nil, suppress: false)
    }

    /// Hot-path state, touched from the tap thread and the main actor.
    struct State: Sendable {
        var hotkey: Hotkey?
        var pressed = false
        var pressedAt: TimeInterval = 0
        var interrupted = false
        var escapeArmed = false
        var escapeDown = false
        /// Combo key whose press we released without seeing its keyUp (tap re-enable, hotkey
        /// change, uninstall); only that one orphan keyUp is swallowed, never ordinary typing.
        var swallowKeyUpOf: UInt16?
    }

    /// Tap machinery, touched only by `install` / `uninstall` and the tap thread.
    private struct Resources {
        var port: CFMachPort?
        var source: CFRunLoopSource?
        var runLoop: CFRunLoop?
        var thread: Thread?
        var stopRequested = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let resources = OSAllocatedUnfairLock(uncheckedState: Resources())
    private let onEvent: @Sendable (HotkeyEvent) -> Void

    private static let eventMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

    /// `onEvent` is called on the main actor, in the order the tap saw the keys.
    init(onEvent: @escaping @Sendable (HotkeyEvent) -> Void) {
        self.onEvent = onEvent
    }

    deinit {
        uninstall()
    }

    // MARK: Public state

    var isInstalled: Bool {
        resources.withLockUnchecked { $0.port != nil }
    }

    var hotkey: Hotkey? {
        state.withLock { $0.hotkey }
    }

    /// `nil` pauses matching (the recorder control captures a new combo, gotcha 44).
    /// A pending press is released so a paused tap never leaves push-to-talk stuck.
    func setHotkey(_ hotkey: Hotkey?) {
        let pendingRelease: Bool = state.withLock { state in
            let wasPressed = Self.forceRelease(&state)
            state.hotkey = hotkey
            return wasPressed
        }
        if pendingRelease {
            emit(.up(at: ProcessInfo.processInfo.systemUptime))
        }
    }

    /// Suppress Esc and report `.escape` only while the widget is visible.
    func setEscapeArmed(_ armed: Bool) {
        state.withLock { state in
            state.escapeArmed = armed
            if !armed { state.escapeDown = false }
        }
    }

    // MARK: Install / uninstall

    /// Creates the tap and starts the tap thread. Returns false when `CGEvent.tapCreate` returns nil
    /// (Accessibility missing, gotcha 38); the caller retries when the permission flips.
    @discardableResult
    func install() -> Bool {
        if isInstalled { return true }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: Self.callback,
            userInfo: userInfo
        ) else {
            Log.hotkey.error("CGEvent.tapCreate returned nil (Accessibility missing?)")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            Log.hotkey.error("CFMachPortCreateRunLoopSource failed")
            return false
        }

        let thread = Thread { [self] in
            runTapLoop()
        }
        thread.name = "com.captylo.app.hotkey-tap"
        thread.qualityOfService = .userInteractive

        resources.withLockUnchecked { resources in
            resources.port = port
            resources.source = source
            resources.runLoop = nil
            resources.thread = thread
            resources.stopRequested = false
        }
        thread.start()
        Log.hotkey.info("Event tap installed")
        return true
    }

    /// Removes the source, invalidates the port and stops the tap run loop (brief 5.4).
    func uninstall() {
        let (port, source, runLoop): (CFMachPort?, CFRunLoopSource?, CFRunLoop?) = resources.withLockUnchecked { resources in
            let taken = (resources.port, resources.source, resources.runLoop)
            resources.stopRequested = true
            resources.port = nil
            resources.source = nil
            resources.runLoop = nil
            resources.thread = nil
            return taken
        }
        guard let port else { return }

        CGEvent.tapEnable(tap: port, enable: false)
        if let runLoop, let source {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        CFMachPortInvalidate(port)
        if let runLoop {
            CFRunLoopStop(runLoop)
        }

        let pendingRelease: Bool = state.withLock { state in
            state.escapeDown = false
            return Self.forceRelease(&state)
        }
        if pendingRelease {
            emit(.up(at: ProcessInfo.processInfo.systemUptime))
        }
        Log.hotkey.info("Event tap uninstalled")
    }

    // MARK: Tap thread

    /// Body of the tap thread: attach the source to this thread's run loop, enable the tap, run.
    private func runTapLoop() {
        let runLoop = CFRunLoopGetCurrent()
        let port: CFMachPort? = resources.withLockUnchecked { resources in
            guard !resources.stopRequested, let port = resources.port, let source = resources.source else {
                return nil
            }
            resources.runLoop = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            return port
        }
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopRun()
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let tap = Unmanaged<HotkeyTap>.fromOpaque(userInfo).takeUnretainedValue()
        return tap.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
    }

    /// Runs on the tap thread. Returns true to suppress the event.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            recoverFromDisable(type: type)
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return false
        }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = NSEvent.ModifierFlags(rawValue: UInt(truncatingIfNeeded: event.flags.rawValue))
        let isAutorepeat = type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let now = ProcessInfo.processInfo.systemUptime

        let decision = state.withLock { state in
            Self.decide(&state, type: type, keyCode: keyCode, flags: flags, isAutorepeat: isAutorepeat, now: now)
        }
        if let event = decision.event {
            emit(event)
        }
        return decision.suppress
    }

    /// Pure state machine, lock held by the caller. Integer compares only (gotcha 36).
    static func decide(
        _ state: inout State,
        type: CGEventType,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        isAutorepeat: Bool,
        now: TimeInterval
    ) -> Decision {
        let isFlagsChanged = type == .flagsChanged

        // Esc: swallowed and reported only while armed and pressed without extra modifiers. The
        // modifiers of a held hotkey (push-to-talk: Right Option, Fn, Right Command, a combo's
        // own modifiers) do not count, so Esc x2 cancels a hold take and never reaches the app.
        // This branch runs before the interruption check, so Esc is never `.interrupted`.
        if !isFlagsChanged, keyCode == KeyCode.escape {
            let held: NSEvent.ModifierFlags = state.pressed ? (state.hotkey?.modifierFlags ?? []) : []
            if state.escapeArmed, Hotkey.normalize(flags).subtracting(held).isEmpty {
                if type == .keyDown {
                    state.escapeDown = true
                    return Decision(event: isAutorepeat ? nil : .escape, suppress: true)
                }
                state.escapeDown = false
                return Decision(event: nil, suppress: true)
            }
            if type == .keyUp, state.escapeDown {
                // Armed flag dropped between keyDown and keyUp: swallow the orphan keyUp too.
                state.escapeDown = false
                return Decision(event: nil, suppress: true)
            }
        }

        // Orphan keyUp of a combo press we force-released; a fresh press of that key ends the wait.
        if let orphan = state.swallowKeyUpOf, orphan == keyCode, !isFlagsChanged {
            if type == .keyUp {
                state.swallowKeyUpOf = nil
                return Decision(event: nil, suppress: true)
            }
            if !isAutorepeat {
                state.swallowKeyUpOf = nil
            }
        }

        guard let hotkey = state.hotkey else { return .passThrough }
        let suppressCombo = hotkey.kind == .key

        if !state.pressed {
            if hotkey.matchesPress(keyCode: keyCode, flags: flags, isFlagsChanged: isFlagsChanged) {
                if isAutorepeat {
                    return Decision(event: nil, suppress: suppressCombo)
                }
                state.pressed = true
                state.pressedAt = now
                state.interrupted = false
                return Decision(event: .down(at: now), suppress: suppressCombo)
            }
            return .passThrough
        }

        // Hotkey is down.
        if type == .keyUp || isFlagsChanged,
           hotkey.matchesRelease(keyCode: keyCode, flags: flags, isFlagsChanged: isFlagsChanged) {
            state.pressed = false
            state.interrupted = false
            return Decision(event: .up(at: now), suppress: suppressCombo)
        }

        if type == .keyDown {
            if suppressCombo, keyCode == hotkey.keyCode {
                // Autorepeat of the combo key while held.
                return Decision(event: nil, suppress: true)
            }
            if !isAutorepeat, !KeyCode.isModifierKey(keyCode), !state.interrupted,
               now - state.pressedAt <= interruptWindow {
                state.interrupted = true
                return Decision(event: .interrupted, suppress: false)
            }
        }
        return .passThrough
    }

    /// Re-enable the tap and release a pending press so push-to-talk never sticks (gotcha 37).
    private func recoverFromDisable(type: CGEventType) {
        Log.hotkey.warning("Event tap disabled (\(type.rawValue)), re-enabling")
        let port: CFMachPort? = resources.withLockUnchecked { $0.port }
        if let port {
            CGEvent.tapEnable(tap: port, enable: true)
        }
        let pendingRelease: Bool = state.withLock { state in
            state.escapeDown = false
            return Self.forceRelease(&state)
        }
        if pendingRelease {
            emit(.up(at: ProcessInfo.processInfo.systemUptime))
        }
    }

    /// Clears a held press without its key-up. For a combo hotkey, remembers the key so the
    /// physical keyUp that follows is swallowed like the rest of the press. Returns whether a
    /// press was pending (the caller then reports `.up`).
    static func forceRelease(_ state: inout State) -> Bool {
        let wasPressed = state.pressed
        if wasPressed, let hotkey = state.hotkey, hotkey.kind == .key {
            state.swallowKeyUpOf = hotkey.keyCode
        }
        state.pressed = false
        state.interrupted = false
        return wasPressed
    }

    /// Hop to the main actor. Tasks created from one thread are enqueued in order.
    private func emit(_ event: HotkeyEvent) {
        let onEvent = self.onEvent
        Task { @MainActor in
            onEvent(event)
        }
    }
}
