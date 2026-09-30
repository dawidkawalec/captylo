import AppKit
import Foundation
import Testing
@testable import Captylo

struct HotkeyTests {
    // MARK: Modifier-only matching

    @Test func rightOptionPressRequiresExactFlagsAndSide() {
        let hotkey = Hotkey.rightOption
        #expect(hotkey.matchesPress(keyCode: KeyCode.rightOption, flags: [.option], isFlagsChanged: true))
        // Shift held: exact match fails (gotcha 39).
        #expect(!hotkey.matchesPress(keyCode: KeyCode.rightOption, flags: [.option, .shift], isFlagsChanged: true))
        // Left Option is a different key.
        #expect(!hotkey.matchesPress(keyCode: KeyCode.leftOption, flags: [.option], isFlagsChanged: true))
        // A keyDown never matches a modifier-only hotkey.
        #expect(!hotkey.matchesPress(keyCode: KeyCode.rightOption, flags: [.option], isFlagsChanged: false))
        // Device-dependent bits are ignored.
        #expect(hotkey.matchesPress(keyCode: KeyCode.rightOption, flags: [.option, .numericPad], isFlagsChanged: true))
    }

    @Test func rightOptionReleaseUsesTheKeyCodeOnly() {
        let hotkey = Hotkey.rightOption
        #expect(hotkey.matchesRelease(keyCode: KeyCode.rightOption, flags: [], isFlagsChanged: true))
        #expect(hotkey.matchesRelease(keyCode: KeyCode.rightOption, flags: [.shift], isFlagsChanged: true))
        #expect(!hotkey.matchesRelease(keyCode: KeyCode.leftOption, flags: [], isFlagsChanged: true))
        #expect(!hotkey.matchesRelease(keyCode: KeyCode.rightOption, flags: [], isFlagsChanged: false))
    }

    @Test func fnDoesNotFireOnArrowOrFunctionKeyChords() {
        let hotkey = Hotkey.fn
        #expect(hotkey.matchesPress(keyCode: KeyCode.fn, flags: [.function], isFlagsChanged: true))
        #expect(!hotkey.matchesPress(keyCode: KeyCode.leftArrow, flags: [.function, .numericPad], isFlagsChanged: false))
        #expect(!hotkey.matchesPress(keyCode: KeyCode.f5, flags: [.function], isFlagsChanged: false))
        #expect(!hotkey.matchesPress(keyCode: KeyCode.fn, flags: [.function, .command], isFlagsChanged: true))
    }

    @Test func rightCommandPreset() {
        let hotkey = Hotkey.rightCommand
        #expect(hotkey.matchesPress(keyCode: KeyCode.rightCommand, flags: [.command], isFlagsChanged: true))
        #expect(!hotkey.matchesPress(keyCode: KeyCode.leftCommand, flags: [.command], isFlagsChanged: true))
    }

    @Test func genericChordMatchesAnyKeyCodeAndReleasesWhenFlagsDrop() {
        let chord = Hotkey(kind: .modifierOnly, keyCode: KeyCode.generic, flags: [.control, .option])
        #expect(chord.isGenericChord)
        #expect(chord.matchesPress(keyCode: KeyCode.leftOption, flags: [.control, .option], isFlagsChanged: true))
        #expect(chord.matchesPress(keyCode: KeyCode.rightControl, flags: [.control, .option], isFlagsChanged: true))
        #expect(!chord.matchesPress(keyCode: KeyCode.leftOption, flags: [.control, .option, .shift], isFlagsChanged: true))
        #expect(!chord.matchesPress(keyCode: KeyCode.leftOption, flags: [.option], isFlagsChanged: true))

        #expect(chord.matchesRelease(keyCode: KeyCode.leftOption, flags: [.control], isFlagsChanged: true))
        #expect(!chord.matchesRelease(keyCode: KeyCode.leftShift, flags: [.control, .option, .shift], isFlagsChanged: true))
        #expect(!chord.matchesRelease(keyCode: KeyCode.leftOption, flags: [.control], isFlagsChanged: false))
    }

    // MARK: Key matching

    @Test func functionKeyStripsTheFunctionFlag() {
        let f5 = Hotkey(kind: .key, keyCode: KeyCode.f5, flags: [.function])
        #expect(f5.modifiers == 0)
        #expect(f5.matchesPress(keyCode: KeyCode.f5, flags: [.function], isFlagsChanged: false))
        #expect(f5.matchesPress(keyCode: KeyCode.f5, flags: [], isFlagsChanged: false))
        #expect(!f5.matchesPress(keyCode: KeyCode.f5, flags: [.function, .command], isFlagsChanged: false))
        #expect(!f5.matchesPress(keyCode: KeyCode.f13, flags: [.function], isFlagsChanged: false))
        #expect(f5.matchesRelease(keyCode: KeyCode.f5, flags: [.function], isFlagsChanged: false))
        #expect(!f5.matchesRelease(keyCode: KeyCode.f5, flags: [], isFlagsChanged: true))
    }

    @Test func keyComboMatchesExactModifiers() {
        let combo = Hotkey(kind: .key, keyCode: KeyCode.space, flags: [.control, .option])
        #expect(combo.matchesPress(keyCode: KeyCode.space, flags: [.control, .option], isFlagsChanged: false))
        #expect(!combo.matchesPress(keyCode: KeyCode.space, flags: [.control, .option, .shift], isFlagsChanged: false))
        #expect(!combo.matchesPress(keyCode: KeyCode.space, flags: [.control], isFlagsChanged: false))
        #expect(!combo.matchesPress(keyCode: KeyCode.space, flags: [.control, .option], isFlagsChanged: true))
        // Release ignores flags: the user may let go of a modifier before the key.
        #expect(combo.matchesRelease(keyCode: KeyCode.space, flags: [], isFlagsChanged: false))
        #expect(!combo.matchesRelease(keyCode: KeyCode.returnKey, flags: [], isFlagsChanged: false))
    }

    @Test func normalizeKeepsOnlyRelevantFlags() {
        #expect(Hotkey.normalize([.option, .numericPad, .capsLock]) == [.option])
        #expect(Hotkey.normalize([.function, .command], keyCode: KeyCode.f5) == [.command])
        #expect(Hotkey.normalize([.function, .command], keyCode: KeyCode.leftArrow) == [.command])
        #expect(Hotkey.normalize([.function], keyCode: KeyCode.fn) == [.function])
    }

    // MARK: Display

    @Test func displayNames() {
        #expect(Hotkey.rightOption.displayName == "Prawy ⌥")
        #expect(Hotkey.fn.displayName == "Fn")
        #expect(Hotkey.rightCommand.displayName == "Prawy ⌘")
        #expect(Hotkey(kind: .key, keyCode: KeyCode.space, flags: [.control, .option]).displayName == "⌃⌥Spacja")
        #expect(Hotkey(kind: .modifierOnly, keyCode: KeyCode.generic, flags: [.control, .option]).displayName == "⌃⌥")
        #expect(Hotkey(kind: .key, keyCode: KeyCode.f5, flags: []).displayName == "F5")
        #expect(Hotkey(kind: .key, keyCode: KeyCode.v, flags: [.command, .shift]).displayName == "⇧⌘V")
        #expect(Hotkey(kind: .modifierOnly, keyCode: KeyCode.leftShift, flags: [.shift]).displayName == "Lewy ⇧")
    }

    // MARK: Validation

    @Test func validationRules() {
        #expect(Hotkey.validate(.rightOption) == nil)
        #expect(Hotkey.validate(.fn) == nil)
        #expect(Hotkey.validate(.rightCommand) == nil)
        #expect(Hotkey.validate(Hotkey(kind: .key, keyCode: KeyCode.space, flags: [.control, .option])) == nil)
        #expect(Hotkey.validate(Hotkey(kind: .key, keyCode: KeyCode.f5, flags: [])) == nil)

        #expect(Hotkey.validate(Hotkey(kind: .modifierOnly, keyCode: KeyCode.generic, flags: [])) != nil)
        #expect(Hotkey.validate(Hotkey(kind: .key, keyCode: KeyCode.a, flags: [])) != nil)
        #expect(Hotkey.validate(Hotkey(kind: .key, keyCode: KeyCode.a, flags: [.shift])) != nil)
        #expect(Hotkey.validate(Hotkey(kind: .key, keyCode: KeyCode.c, flags: [.command])) != nil)
        #expect(Hotkey.validate(Hotkey(kind: .key, keyCode: KeyCode.q, flags: [.command])) != nil)
        #expect(Hotkey.validate(Hotkey(kind: .key, keyCode: KeyCode.delete, flags: [.option])) != nil)
        #expect(Hotkey.validate(Hotkey(kind: .key, keyCode: KeyCode.escape, flags: [.option, .command])) != nil)
        #expect(Hotkey.validate(Hotkey(kind: .key, keyCode: KeyCode.rightOption, flags: [.option])) != nil)
    }

    // MARK: Persistence

    @Test func codableRoundTripUsesStableKeys() throws {
        let data = try JSONEncoder().encode(Hotkey.rightOption)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["kind"] as? String == "modifierOnly")
        #expect(json["keyCode"] as? Int == 0x3D)
        #expect(json["modifiers"] as? UInt == NSEvent.ModifierFlags.option.rawValue)

        let decoded = try JSONDecoder().decode(Hotkey.self, from: data)
        #expect(decoded == Hotkey.rightOption)
    }

    @Test func keyCodeTable() {
        #expect(KeyCode.isFunctionKey(KeyCode.f5))
        #expect(!KeyCode.isFunctionKey(KeyCode.a))
        #expect(KeyCode.isModifierKey(KeyCode.rightOption))
        #expect(!KeyCode.isModifierKey(KeyCode.space))
        #expect(KeyCode.name(for: KeyCode.space) == "Spacja")
        #expect(KeyCode.name(for: KeyCode.a) == "A")
        #expect(KeyCode.name(for: 0x69) == "F13")
    }
}
