import Foundation

/// Events emitted by `HotkeyTap` and consumed by `HotkeyController`.
/// Times are `ProcessInfo.processInfo.systemUptime`, never `CGEvent.timestamp`.
enum HotkeyEvent: Sendable, Equatable {
    case down(at: TimeInterval)
    case up(at: TimeInterval)
    /// A non-modifier key was pressed within the interruption window after `down` (accidental start).
    case interrupted
    /// Esc pressed while the widget is visible (the key is swallowed by the tap).
    case escape
}
