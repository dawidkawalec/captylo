import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Captylo

/// The tap itself needs Accessibility; only its pure state machine is covered here.
struct HotkeyTapTests {
    private func decide(
        _ state: inout HotkeyTap.State,
        _ type: CGEventType,
        _ keyCode: UInt16,
        _ flags: NSEvent.ModifierFlags = [],
        autorepeat: Bool = false,
        now: TimeInterval = 10
    ) -> HotkeyTap.Decision {
        HotkeyTap.decide(&state, type: type, keyCode: keyCode, flags: flags, isAutorepeat: autorepeat, now: now)
    }

    @Test func modifierOnlyHotkeyPassesThroughAndReportsDownUp() {
        var state = HotkeyTap.State(hotkey: .rightOption)
        let down = decide(&state, .flagsChanged, KeyCode.rightOption, [.option], now: 10)
        #expect(down == HotkeyTap.Decision(event: .down(at: 10), suppress: false))
        #expect(state.pressed)

        // Another modifier while held: no release.
        let shift = decide(&state, .flagsChanged, KeyCode.leftShift, [.option, .shift], now: 10.1)
        #expect(shift == .passThrough)

        let up = decide(&state, .flagsChanged, KeyCode.rightOption, [.shift], now: 10.4)
        #expect(up == HotkeyTap.Decision(event: .up(at: 10.4), suppress: false))
        #expect(!state.pressed)
    }

    @Test func comboHotkeyIsSuppressedOnDownRepeatAndUp() {
        var state = HotkeyTap.State(hotkey: Hotkey(kind: .key, keyCode: KeyCode.space, flags: [.control, .option]))
        let down = decide(&state, .keyDown, KeyCode.space, [.control, .option], now: 1)
        #expect(down == HotkeyTap.Decision(event: .down(at: 1), suppress: true))

        let repeatDown = decide(&state, .keyDown, KeyCode.space, [.control, .option], autorepeat: true, now: 1.3)
        #expect(repeatDown == HotkeyTap.Decision(event: nil, suppress: true))

        let up = decide(&state, .keyUp, KeyCode.space, [.control], now: 1.6)
        #expect(up == HotkeyTap.Decision(event: .up(at: 1.6), suppress: true))
        #expect(!state.pressed)

        // The same key without the modifiers is ordinary typing.
        let plain = decide(&state, .keyDown, KeyCode.space, [], now: 2)
        #expect(plain == .passThrough)
    }

    @Test func comboKeyUpOfOrdinaryTypingPassesThrough() {
        var state = HotkeyTap.State(hotkey: Hotkey(kind: .key, keyCode: KeyCode.space, flags: [.control, .option]))
        // Plain Space while the hotkey is ⌃⌥Space: both halves reach the app (no stuck key).
        #expect(decide(&state, .keyDown, KeyCode.space, [], now: 1) == .passThrough)
        #expect(decide(&state, .keyUp, KeyCode.space, [], now: 1.1) == .passThrough)
    }

    @Test func forceReleasedComboSwallowsOnlyItsOrphanKeyUp() {
        var state = HotkeyTap.State(hotkey: Hotkey(kind: .key, keyCode: KeyCode.space, flags: [.control, .option]))
        _ = decide(&state, .keyDown, KeyCode.space, [.control, .option], now: 1)
        #expect(HotkeyTap.forceRelease(&state), "a pending press is reported")
        #expect(state.swallowKeyUpOf == KeyCode.space)

        #expect(decide(&state, .keyUp, KeyCode.space, [.control, .option], now: 1.5) == HotkeyTap.Decision(event: nil, suppress: true))
        #expect(state.swallowKeyUpOf == nil)
        #expect(decide(&state, .keyUp, KeyCode.space, [], now: 2) == .passThrough, "only one keyUp is swallowed")
    }

    @Test func freshPressClearsTheOrphanWait() {
        var state = HotkeyTap.State(hotkey: Hotkey(kind: .key, keyCode: KeyCode.space, flags: [.control, .option]))
        _ = decide(&state, .keyDown, KeyCode.space, [.control, .option], now: 1)
        _ = HotkeyTap.forceRelease(&state)
        // The keyUp got lost while the tap was disabled; the next plain Space is ordinary typing.
        #expect(decide(&state, .keyDown, KeyCode.space, [], now: 3) == .passThrough)
        #expect(state.swallowKeyUpOf == nil)
        #expect(decide(&state, .keyUp, KeyCode.space, [], now: 3.1) == .passThrough)
    }

    @Test func forceReleaseOfAModifierHotkeyArmsNothing() {
        var state = HotkeyTap.State(hotkey: .rightOption)
        _ = decide(&state, .flagsChanged, KeyCode.rightOption, [.option], now: 1)
        #expect(HotkeyTap.forceRelease(&state))
        #expect(state.swallowKeyUpOf == nil)
        #expect(!HotkeyTap.forceRelease(&state), "nothing pending the second time")
    }

    @Test func nonModifierKeyDownWithinWindowReportsInterruptedOnce() {
        var state = HotkeyTap.State(hotkey: .rightOption)
        _ = decide(&state, .flagsChanged, KeyCode.rightOption, [.option], now: 10)
        let letter = decide(&state, .keyDown, KeyCode.a, [.option], now: 10.2)
        #expect(letter == HotkeyTap.Decision(event: .interrupted, suppress: false))
        let second = decide(&state, .keyDown, KeyCode.s, [.option], now: 10.3)
        #expect(second == .passThrough)
    }

    @Test func interruptionWindowIsOneSecondAndSkipsModifiersAndRepeats() {
        var state = HotkeyTap.State(hotkey: .rightOption)
        _ = decide(&state, .flagsChanged, KeyCode.rightOption, [.option], now: 10)
        #expect(decide(&state, .keyDown, KeyCode.leftShift, [.option, .shift], now: 10.1) == .passThrough)
        #expect(decide(&state, .keyDown, KeyCode.a, [.option], autorepeat: true, now: 10.1).event == nil)
        #expect(decide(&state, .keyDown, KeyCode.a, [.option], now: 11.2) == .passThrough)
    }

    @Test func escapeIsSwallowedOnlyWhileArmed() {
        var state = HotkeyTap.State(hotkey: .rightOption)
        #expect(decide(&state, .keyDown, KeyCode.escape) == .passThrough)

        state.escapeArmed = true
        #expect(decide(&state, .keyDown, KeyCode.escape) == HotkeyTap.Decision(event: .escape, suppress: true))
        #expect(decide(&state, .keyDown, KeyCode.escape, autorepeat: true) == HotkeyTap.Decision(event: nil, suppress: true))
        #expect(decide(&state, .keyUp, KeyCode.escape) == HotkeyTap.Decision(event: nil, suppress: true))

        // Modified Esc (for example ⌥⌘Esc) is never ours.
        #expect(decide(&state, .keyDown, KeyCode.escape, [.option, .command]) == .passThrough)
    }

    @Test func escapeWhileHoldingThePresetIsSwallowedAndNeverAnInterruption() {
        let cases: [(Hotkey, UInt16, NSEvent.ModifierFlags)] = [
            (.rightOption, KeyCode.rightOption, [.option]),
            (.fn, KeyCode.fn, [.function]),
            (.rightCommand, KeyCode.rightCommand, [.command]),
        ]
        for (hotkey, keyCode, flags) in cases {
            var state = HotkeyTap.State(hotkey: hotkey, escapeArmed: true)
            #expect(decide(&state, .flagsChanged, keyCode, flags, now: 10) == HotkeyTap.Decision(event: .down(at: 10), suppress: false))

            // Within the interruption window and after it: always our Esc, never passed on.
            #expect(decide(&state, .keyDown, KeyCode.escape, flags, now: 10.2) == HotkeyTap.Decision(event: .escape, suppress: true))
            #expect(decide(&state, .keyUp, KeyCode.escape, flags, now: 10.3) == HotkeyTap.Decision(event: nil, suppress: true))
            #expect(decide(&state, .keyDown, KeyCode.escape, flags, now: 12) == HotkeyTap.Decision(event: .escape, suppress: true))
            #expect(!state.interrupted)
            #expect(state.pressed)

            // An extra modifier on top of the held hotkey is still not ours.
            #expect(decide(&state, .keyDown, KeyCode.escape, flags.union(.shift), now: 12.5) == .passThrough)
        }
    }

    @Test func escapeKeyUpAfterDisarmIsStillSwallowed() {
        var state = HotkeyTap.State(hotkey: nil, escapeArmed: true)
        _ = decide(&state, .keyDown, KeyCode.escape)
        state.escapeArmed = false
        #expect(decide(&state, .keyUp, KeyCode.escape) == HotkeyTap.Decision(event: nil, suppress: true))
        #expect(decide(&state, .keyUp, KeyCode.escape) == .passThrough)
    }

    @Test func pausedTapMatchesNothing() {
        var state = HotkeyTap.State(hotkey: nil)
        #expect(decide(&state, .flagsChanged, KeyCode.rightOption, [.option]) == .passThrough)
        #expect(decide(&state, .keyDown, KeyCode.a) == .passThrough)
    }

    @Test func autorepeatCannotStartAPress() {
        var state = HotkeyTap.State(hotkey: Hotkey(kind: .key, keyCode: KeyCode.f13, flags: []))
        let repeated = decide(&state, .keyDown, KeyCode.f13, [.function], autorepeat: true)
        #expect(repeated == HotkeyTap.Decision(event: nil, suppress: true))
        #expect(!state.pressed)
    }
}
