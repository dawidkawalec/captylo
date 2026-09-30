import ApplicationServices
import CoreGraphics
import Foundation

/// Posts a synthetic Cmd+V (gotcha 48). Events come from a `.privateState` source so the
/// physically held hotkey modifiers never leak into them, and every event carries
/// `SyntheticEventMarker.value` so the hotkey tap ignores it (gotcha 43).
@MainActor
enum KeySynth {
    /// Left Command (`kVK_Command`).
    static let commandKeyCode: CGKeyCode = 0x37
    /// Gap between the four key events.
    static let eventGap: Duration = .milliseconds(10)

    /// cmdDown -> 10 ms -> vDown -> 10 ms -> vUp -> 10 ms -> cmdUp on `.cghidEventTap`.
    /// Returns false when Accessibility is not granted or an event cannot be created.
    static func pasteCommand() async -> Bool {
        guard AXIsProcessTrusted() else {
            Log.output.warning("Cmd+V not posted: Accessibility not trusted")
            return false
        }

        let source = CGEventSource(stateID: .privateState)
        let vKeyCode = KeyboardLayout.keyCodeForV()

        guard
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: false)
        else {
            Log.output.error("Cmd+V not posted: CGEvent creation failed")
            return false
        }

        for event in [cmdDown, vDown, vUp] {
            event.flags = .maskCommand
        }
        for event in [cmdDown, vDown, vUp, cmdUp] {
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEventMarker.value)
        }

        cmdDown.post(tap: .cghidEventTap)
        try? await Task.sleep(for: eventGap)
        vDown.post(tap: .cghidEventTap)
        try? await Task.sleep(for: eventGap)
        vUp.post(tap: .cghidEventTap)
        try? await Task.sleep(for: eventGap)
        cmdUp.post(tap: .cghidEventTap)

        Log.output.debug("Cmd+V posted (V key code 0x\(String(vKeyCode, radix: 16), privacy: .public))")
        return true
    }
}
