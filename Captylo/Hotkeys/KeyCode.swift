/// Carbon virtual key codes (`kVK_*`). Letters and punctuation follow the ANSI layout;
/// modifier and navigation keys are layout independent (brief 5.4).
enum KeyCode {
    /// Marker for a multi-modifier chord stored without a side-specific key.
    static let generic: UInt16 = .max

    // Modifiers
    static let fn: UInt16 = 0x3F
    static let rightOption: UInt16 = 0x3D
    static let leftOption: UInt16 = 0x3A
    static let rightCommand: UInt16 = 0x36
    static let leftCommand: UInt16 = 0x37
    static let rightControl: UInt16 = 0x3E
    static let leftControl: UInt16 = 0x3B
    static let rightShift: UInt16 = 0x3C
    static let leftShift: UInt16 = 0x38
    static let capsLock: UInt16 = 0x39

    // Named keys
    static let escape: UInt16 = 0x35
    static let returnKey: UInt16 = 0x24
    static let tab: UInt16 = 0x30
    static let space: UInt16 = 0x31
    static let delete: UInt16 = 0x33
    static let forwardDelete: UInt16 = 0x75
    static let home: UInt16 = 0x73
    static let end: UInt16 = 0x77
    static let pageUp: UInt16 = 0x74
    static let pageDown: UInt16 = 0x79
    static let leftArrow: UInt16 = 0x7B
    static let rightArrow: UInt16 = 0x7C
    static let downArrow: UInt16 = 0x7D
    static let upArrow: UInt16 = 0x7E
    static let help: UInt16 = 0x72

    // Letters used by the reserved-shortcut list and the paster
    static let a: UInt16 = 0x00
    static let s: UInt16 = 0x01
    static let d: UInt16 = 0x02
    static let f: UInt16 = 0x03
    static let h: UInt16 = 0x04
    static let z: UInt16 = 0x06
    static let x: UInt16 = 0x07
    static let c: UInt16 = 0x08
    static let v: UInt16 = 0x09
    static let b: UInt16 = 0x0B
    static let q: UInt16 = 0x0C
    static let w: UInt16 = 0x0D
    static let t: UInt16 = 0x11
    static let o: UInt16 = 0x1F
    static let u: UInt16 = 0x20
    static let i: UInt16 = 0x22
    static let p: UInt16 = 0x23
    static let n: UInt16 = 0x2D
    static let m: UInt16 = 0x2E
    static let comma: UInt16 = 0x2B

    // F-keys
    static let f5: UInt16 = 0x60
    static let f13: UInt16 = 0x69

    /// F1...F20 by key code.
    static let functionKeys: [UInt16: Int] = [
        0x7A: 1, 0x78: 2, 0x63: 3, 0x76: 4, 0x60: 5, 0x61: 6, 0x62: 7, 0x64: 8, 0x65: 9, 0x6D: 10,
        0x67: 11, 0x6F: 12, 0x69: 13, 0x6B: 14, 0x71: 15, 0x6A: 16, 0x40: 17, 0x4F: 18, 0x50: 19, 0x5A: 20,
    ]

    static let modifierKeys: Set<UInt16> = [
        fn, rightOption, leftOption, rightCommand, leftCommand,
        rightControl, leftControl, rightShift, leftShift, capsLock,
    ]

    /// Keys for which macOS always sets `.function` in the flags.
    static let navigationKeys: Set<UInt16> = [
        forwardDelete, home, end, pageUp, pageDown, leftArrow, rightArrow, downArrow, upArrow, help,
    ]

    static func isFunctionKey(_ code: UInt16) -> Bool {
        functionKeys[code] != nil
    }

    static func isModifierKey(_ code: UInt16) -> Bool {
        modifierKeys.contains(code)
    }

    /// True for keys whose `.function` flag carries no information (F-keys and navigation keys).
    static func stripsFunctionFlag(_ code: UInt16) -> Bool {
        isFunctionKey(code) || navigationKeys.contains(code)
    }

    /// Human readable key name (ANSI layout, Polish names for named keys).
    static func name(for code: UInt16) -> String {
        if let number = functionKeys[code] { return "F\(number)" }
        if let named = namedKeys[code] { return named }
        if let ansi = ansiNames[code] { return ansi }
        return String(localized: "Klawisz \(String(code, radix: 16, uppercase: true))")
    }

    private static let namedKeys: [UInt16: String] = [
        escape: "Esc",
        returnKey: "Return",
        tab: "Tab",
        space: String(localized: "Spacja"),
        delete: "⌫",
        forwardDelete: "⌦",
        home: "Home",
        end: "End",
        pageUp: "Page Up",
        pageDown: "Page Down",
        leftArrow: "←",
        rightArrow: "→",
        downArrow: "↓",
        upArrow: "↑",
        help: "Help",
    ]

    private static let ansiNames: [UInt16: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
        0x08: "C", 0x09: "V", 0x0A: "§", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
        0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
        0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O",
        0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K",
        0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",
    ]
}
