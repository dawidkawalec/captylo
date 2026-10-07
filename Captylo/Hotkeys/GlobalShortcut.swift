import Carbon.HIToolbox
import os

/// A fixed system-wide key combo through Carbon's `RegisterEventHotKey` ("Nagraj spotkanie",
/// ⌃⌥⌘M). Unlike the dictation hotkey it needs no event tap and no Accessibility grant, and the
/// press never reaches the focused app. Registration can fail when another app owns the combo;
/// the menu bar item still works then.
@MainActor
final class GlobalShortcut {
    /// ⌃⌥⌘M: no system or common app shortcut uses it.
    static let meeting = Combo(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | optionKey | controlKey), display: "⌃⌥⌘M")
    /// ⌃⌥⌘P: "Popraw" the selected text (self-learning).
    static let correction = Combo(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey | controlKey), display: "⌃⌥⌘P")
    /// ⌃⌥⌘N: a voice note from any app (Notatki).
    static let note = Combo(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | optionKey | controlKey), display: "⌃⌥⌘N")

    struct Combo: Sendable, Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
        /// The glyphs shown next to the action ("⌃⌥⌘M").
        let display: String
    }

    /// "CPTY": tags our hot keys in the shared Carbon event stream.
    private static let signature: OSType = 0x4350_5459
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handler: EventHandlerRef?

    let combo: Combo
    private let id: UInt32
    private let action: () -> Void
    private var ref: EventHotKeyRef?

    init(_ combo: Combo, action: @escaping () -> Void) {
        self.combo = combo
        self.action = action
        id = Self.nextID
        Self.nextID += 1
    }

    var isRegistered: Bool { ref != nil }

    /// Idempotent. Returns false when the combo could not be registered.
    @discardableResult
    func register() -> Bool {
        if ref != nil { return true }
        guard Self.installHandler() else { return false }
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &hotKey
        )
        guard status == noErr, let hotKey else {
            Log.hotkey.error("Global shortcut \(self.combo.display, privacy: .public) could not be registered (\(status))")
            return false
        }
        ref = hotKey
        Self.actions[id] = action
        Log.hotkey.info("Global shortcut \(self.combo.display, privacy: .public) registered")
        return true
    }

    func unregister() {
        guard let ref else { return }
        UnregisterEventHotKey(ref)
        self.ref = nil
        Self.actions[id] = nil
    }

    /// One handler for every `GlobalShortcut`; Carbon calls it on the main thread.
    private static func installHandler() -> Bool {
        if handler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == GlobalShortcut.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let id = hotKeyID.id
            MainActor.assumeIsolated {
                GlobalShortcut.actions[id]?()
            }
            return noErr
        }, 1, &spec, nil, &handler)
        if status != noErr {
            Log.hotkey.error("Global shortcut handler could not be installed (\(status))")
        }
        return status == noErr
    }
}
