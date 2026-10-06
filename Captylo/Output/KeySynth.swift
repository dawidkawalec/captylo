import ApplicationServices
import CoreGraphics
import Foundation

/// Posts a synthetic Cmd+V (gotcha 48), or Cmd+C for "Popraw". Events come from a
/// `.privateState` source so the physically held hotkey modifiers never leak into them, and
/// every event carries `SyntheticEventMarker.value` so the hotkey tap ignores it (gotcha 43).
@MainActor
enum KeySynth {
    /// Left Command (`kVK_Command`).
    static let commandKeyCode: CGKeyCode = 0x37
    /// Gap between the four key events.
    static let eventGap: Duration = .milliseconds(10)

    /// cmdDown -> 10 ms -> vDown -> 10 ms -> vUp -> 10 ms -> cmdUp on `.cghidEventTap`.
    /// Returns false when Accessibility is not granted or an event cannot be created.
    static func pasteCommand() async -> Bool {
        await command(KeyboardLayout.keyCodeForV(), name: "Cmd+V")
    }

    /// Cmd+C, the same way: copies the selection of an app that does not expose it through
    /// Accessibility (Electron editors).
    static func copyCommand() async -> Bool {
        await command(KeyboardLayout.keyCodeForC(), name: "Cmd+C")
    }

    private static func command(_ keyCode: CGKeyCode, name: String) async -> Bool {
        guard AXIsProcessTrusted() else {
            Log.output.warning("\(name, privacy: .public) not posted: Accessibility not trusted")
            return false
        }

        let source = CGEventSource(stateID: .privateState)

        guard
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: true),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: false)
        else {
            Log.output.error("\(name, privacy: .public) not posted: CGEvent creation failed")
            return false
        }

        for event in [cmdDown, keyDown, keyUp] {
            event.flags = .maskCommand
        }
        for event in [cmdDown, keyDown, keyUp, cmdUp] {
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEventMarker.value)
        }

        cmdDown.post(tap: .cghidEventTap)
        try? await Task.sleep(for: eventGap)
        keyDown.post(tap: .cghidEventTap)
        try? await Task.sleep(for: eventGap)
        keyUp.post(tap: .cghidEventTap)
        try? await Task.sleep(for: eventGap)
        cmdUp.post(tap: .cghidEventTap)

        Log.output.debug("\(name, privacy: .public) posted (key code 0x\(String(keyCode, radix: 16), privacy: .public))")
        return true
    }
}
