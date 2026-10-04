import AppKit

/// Pure capture logic behind `HotkeyRecorderView` (hotkeys note 3.8 / 4.4):
/// a non-modifier keyDown finishes at once as a combo; a modifier-only chord finishes
/// when every modifier is released, using the peak flags seen during the chord;
/// plain Esc cancels.
struct HotkeyCaptureSession: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        /// Still capturing; `preview` is the chord held so far (nil before any modifier).
        case pending(preview: Hotkey?)
        case captured(Hotkey)
        case cancelled
    }

    private(set) var peakFlags: NSEvent.ModifierFlags = []
    private(set) var pendingModifierOnly: Hotkey?

    init() {}

    mutating func keyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Outcome {
        let normalized = Hotkey.normalize(flags, keyCode: keyCode)
        if keyCode == KeyCode.escape, normalized.isEmpty {
            reset()
            return .cancelled
        }
        if KeyCode.isModifierKey(keyCode) {
            return .pending(preview: pendingModifierOnly)
        }
        reset()
        return .captured(Hotkey(kind: .key, keyCode: keyCode, modifiers: normalized.rawValue))
    }

    mutating func flagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Outcome {
        let normalized = Hotkey.normalize(flags, keyCode: keyCode)
        if normalized.isEmpty {
            guard let pending = pendingModifierOnly else { return .pending(preview: nil) }
            reset()
            return .captured(pending)
        }
        peakFlags.formUnion(normalized)
        let isSingle = Self.flagCount(peakFlags) == 1 && KeyCode.isModifierKey(keyCode)
        let pending = Hotkey(
            kind: .modifierOnly,
            keyCode: isSingle ? keyCode : KeyCode.generic,
            modifiers: peakFlags.rawValue
        )
        pendingModifierOnly = pending
        return .pending(preview: pending)
    }

    mutating func reset() {
        peakFlags = []
        pendingModifierOnly = nil
    }

    private static func flagCount(_ flags: NSEvent.ModifierFlags) -> Int {
        [NSEvent.ModifierFlags.control, .option, .shift, .command, .function]
            .filter { flags.contains($0) }
            .count
    }
}
