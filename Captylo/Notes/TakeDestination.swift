import Foundation

/// Where a take's text goes: pasted at the cursor (dictation), a new voice note (⌃⌥⌘N), or the
/// end of an open note (the microphone in Notatki).
enum TakeDestination: Sendable, Equatable {
    case paste
    case newNote
    case appendToNote(UUID)

    /// What a press of ⌃⌥⌘N does.
    enum ShortcutPress: Equatable {
        case start(TakeDestination)
        case stop
        case ignore
    }

    /// Idle starts a voice note; a take that records (of any destination) is stopped as what it
    /// is; while a take is transcribed nothing happens.
    static func forShortcutPress(phase: DictationPhase, current: TakeDestination?) -> ShortcutPress {
        if phase == .idle { return .start(.newNote) }
        if phase.isCapturing { return .stop }
        return .ignore
    }
}
