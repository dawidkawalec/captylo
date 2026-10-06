/// Late-bound hop from `HotkeyTap` to `HotkeyController`: the tap is created first (the
/// controller needs it), so its callback resolves the controller through this box.
/// `HotkeyTap` already invokes the callback on the main actor.
@MainActor
final class HotkeyRelay {
    weak var controller: HotkeyController?
    /// Runs before every dictation hotkey event ("Popraw" closes its panel).
    var willHandle: (() -> Void)?

    func handle(_ event: HotkeyEvent) {
        willHandle?()
        controller?.handle(event)
    }
}
