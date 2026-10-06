import AppKit

/// The text selected in the frontmost app, for "Popraw" (⌃⌥⌘P). Accessibility first (no
/// clipboard traffic); apps that do not report `AXSelectedText` (Electron editors) get a
/// synthetic Cmd+C, and the user's clipboard is put back right after.
@MainActor
enum SelectionReader {
    /// How long the Accessibility read may take before falling back to Cmd+C.
    static let readDeadline: Duration = .milliseconds(300)
    /// How long the app has to answer Cmd+C.
    static let copyWait: Duration = .milliseconds(400)
    /// How long to wait for the shortcut's modifier keys to be let go before Cmd+C.
    static let modifierWait: Duration = .milliseconds(600)

    static func read(from app: NSRunningApplication, output: TextOutput) async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let pid = app.processIdentifier
        let viaAX = await EditWatcher.offMain(deadline: readDeadline) { () -> String? in
            AXText.enableManualAccessibility(pid: pid)
            guard let element = AXText.focusedElement(pid: pid) else { return nil }
            return AXText.selectedText(of: element)
        } ?? nil
        if let viaAX, !viaAX.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return viaAX
        }
        return await copySelection(output: output)
    }

    /// Cmd+C, then the user's clipboard as it was (`TextOutput.takeOverClipboard`, so a restore
    /// still pending after a dictation is honored). Nil when the app copied nothing in `copyWait`.
    static func copySelection(output: TextOutput, pasteboard: NSPasteboard = .general) async -> String? {
        // ⌃⌥ of ⌃⌥⌘P may still be held; some apps read the live modifier state, not the event's.
        let clock = ContinuousClock()
        let releaseDeadline = clock.now + modifierWait
        let held: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        while !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty, clock.now < releaseDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let snapshot = output.takeOverClipboard()
        let before = pasteboard.changeCount
        guard await KeySynth.copyCommand() else {
            snapshot.restore(to: pasteboard)
            return nil
        }
        let deadline = clock.now + copyWait
        while pasteboard.changeCount == before, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard pasteboard.changeCount != before else {
            snapshot.restore(to: pasteboard)
            return nil
        }
        let text = pasteboard.string(forType: .string)
        snapshot.restore(to: pasteboard)
        return text
    }
}
