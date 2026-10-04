import AppKit

/// The global recording shortcut. Persisted as JSON under `AppSettings.Key.hotkey`:
/// `{"kind":"modifierOnly","keyCode":61,"modifiers":524288}`.
///
/// Matching rules (brief gotchas 39/40): a modifier-only press is a `flagsChanged` event
/// with the same key code and normalized flags exactly equal to the stored flags (Shift held
/// does not match Right Option). A release is the next `flagsChanged` with the same key code.
/// `.function` is stripped for F-keys and navigation keys because Mac keyboards always set it.
struct Hotkey: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case key
        case modifierOnly
    }

    var kind: Kind
    /// Side-specific key code for single modifiers, `KeyCode.generic` for multi-modifier chords.
    var keyCode: UInt16
    /// Normalized `NSEvent.ModifierFlags` raw value.
    var modifiers: UInt

    init(kind: Kind, keyCode: UInt16, modifiers: UInt) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(kind: Kind, keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        self.init(kind: kind, keyCode: keyCode, modifiers: Hotkey.normalize(flags, keyCode: keyCode).rawValue)
    }

    // MARK: Presets

    static let rightOption = Hotkey(
        kind: .modifierOnly, keyCode: KeyCode.rightOption, modifiers: NSEvent.ModifierFlags.option.rawValue)
    static let fn = Hotkey(
        kind: .modifierOnly, keyCode: KeyCode.fn, modifiers: NSEvent.ModifierFlags.function.rawValue)
    static let rightCommand = Hotkey(
        kind: .modifierOnly, keyCode: KeyCode.rightCommand, modifiers: NSEvent.ModifierFlags.command.rawValue)

    static let presets: [Hotkey] = [.rightOption, .fn, .rightCommand]

    // MARK: Flags

    /// The only flags that take part in matching.
    static var relevantFlags: NSEvent.ModifierFlags { [.control, .option, .shift, .command, .function] }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// A multi-modifier chord without a side-specific key code.
    var isGenericChord: Bool { kind == .modifierOnly && keyCode == KeyCode.generic }

    /// Keep only the device-independent modifier bits; drop `.function` for keys that always carry it.
    static func normalize(_ flags: NSEvent.ModifierFlags, keyCode: UInt16? = nil) -> NSEvent.ModifierFlags {
        var normalized = flags.intersection(relevantFlags)
        if let keyCode, KeyCode.stripsFunctionFlag(keyCode) {
            normalized.remove(.function)
        }
        return normalized
    }

    // MARK: Matching

    /// Call for `keyDown` (`isFlagsChanged == false`) and `flagsChanged` (`true`) events.
    func matchesPress(keyCode: UInt16, flags: NSEvent.ModifierFlags, isFlagsChanged: Bool) -> Bool {
        let normalized = Hotkey.normalize(flags, keyCode: keyCode)
        switch kind {
        case .modifierOnly:
            guard isFlagsChanged, normalized.rawValue == modifiers else { return false }
            return isGenericChord || keyCode == self.keyCode
        case .key:
            guard !isFlagsChanged, keyCode == self.keyCode else { return false }
            return normalized.rawValue == modifiers
        }
    }

    /// Call for `keyUp` (`isFlagsChanged == false`) and `flagsChanged` (`true`) events while the hotkey is down.
    func matchesRelease(keyCode: UInt16, flags: NSEvent.ModifierFlags, isFlagsChanged: Bool) -> Bool {
        switch kind {
        case .modifierOnly:
            guard isFlagsChanged else { return false }
            if isGenericChord {
                return !Hotkey.normalize(flags).isSuperset(of: modifierFlags)
            }
            return keyCode == self.keyCode
        case .key:
            return !isFlagsChanged && keyCode == self.keyCode
        }
    }

    // MARK: Display

    /// "Prawy ⌥", "Fn", "Prawy ⌘", "⌃⌥Spacja".
    var displayName: String {
        switch kind {
        case .modifierOnly:
            if let side = Hotkey.sideName(for: keyCode) { return side }
            return Hotkey.glyphs(for: modifierFlags)
        case .key:
            return Hotkey.glyphs(for: modifierFlags) + KeyCode.name(for: keyCode)
        }
    }

    /// Modifier glyphs in the macOS order, Fn first.
    static func glyphs(for flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.function) { result += "Fn" }
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result
    }

    private static func sideName(for keyCode: UInt16) -> String? {
        switch keyCode {
        case KeyCode.fn: return "Fn"
        case KeyCode.rightOption: return String(localized: "Prawy ⌥")
        case KeyCode.leftOption: return String(localized: "Lewy ⌥")
        case KeyCode.rightCommand: return String(localized: "Prawy ⌘")
        case KeyCode.leftCommand: return String(localized: "Lewy ⌘")
        case KeyCode.rightControl: return String(localized: "Prawy ⌃")
        case KeyCode.leftControl: return String(localized: "Lewy ⌃")
        case KeyCode.rightShift: return String(localized: "Prawy ⇧")
        case KeyCode.leftShift: return String(localized: "Lewy ⇧")
        default: return nil
        }
    }

    // MARK: Validation

    /// Returns a Polish error text, or nil when the hotkey is acceptable.
    static func validate(_ hotkey: Hotkey) -> String? {
        let flags = hotkey.modifierFlags
        switch hotkey.kind {
        case .modifierOnly:
            if flags.isEmpty {
                return String(localized: "Skrót musi zawierać modyfikator.")
            }
            if !hotkey.isGenericChord && !KeyCode.isModifierKey(hotkey.keyCode) {
                return String(localized: "Nieprawidłowy klawisz modyfikatora.")
            }
            return nil
        case .key:
            if KeyCode.isModifierKey(hotkey.keyCode) || hotkey.keyCode == KeyCode.generic {
                return String(localized: "Nieprawidłowy skrót.")
            }
            let isFunctionKey = KeyCode.isFunctionKey(hotkey.keyCode)
            if flags.isEmpty && !isFunctionKey {
                return String(localized: "Skrót musi zawierać modyfikator (⌃, ⌥, ⇧, ⌘ lub Fn).")
            }
            if flags == [.shift] && !isFunctionKey {
                return String(localized: "Shift z klawiszem znakowym nie może być skrótem.")
            }
            if reserved.contains(Hotkey(kind: .key, keyCode: hotkey.keyCode, modifiers: flags.rawValue)) {
                return String(localized: "Ten skrót jest zarezerwowany przez system.")
            }
            return nil
        }
    }

    /// System shortcuts that must stay with macOS (brief hotkeys note 3.8).
    static let reserved: Set<Hotkey> = {
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> Hotkey {
            Hotkey(kind: .key, keyCode: code, modifiers: flags.rawValue)
        }
        var set = Set<Hotkey>()
        for code in [
            KeyCode.a, KeyCode.c, KeyCode.f, KeyCode.h, KeyCode.m, KeyCode.n, KeyCode.o, KeyCode.p,
            KeyCode.q, KeyCode.s, KeyCode.t, KeyCode.v, KeyCode.w, KeyCode.x, KeyCode.z, KeyCode.comma,
            KeyCode.b, KeyCode.i, KeyCode.u,
        ] {
            set.insert(key(code, [.command]))
        }
        for code in [KeyCode.h, KeyCode.m, KeyCode.w, KeyCode.escape] {
            set.insert(key(code, [.option, .command]))
        }
        set.insert(key(KeyCode.z, [.shift, .command]))
        set.insert(key(KeyCode.v, [.option, .shift, .command]))
        set.insert(key(KeyCode.q, [.control, .command]))
        set.insert(key(KeyCode.q, [.shift, .command]))
        set.insert(key(KeyCode.q, [.option, .shift, .command]))
        set.insert(key(KeyCode.d, [.control, .command]))
        set.insert(key(KeyCode.delete, [.option]))
        return set
    }()
}
