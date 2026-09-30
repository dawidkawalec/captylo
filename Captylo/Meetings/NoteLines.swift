import Foundation

/// Keeps the meeting time of each line of the user's notes while the text is being edited.
enum NoteLines {
    /// One entry per non-empty line of `text`, in order. A line whose text equals an old line
    /// not matched yet keeps that line (id and time); every other line is stamped with `now`.
    static func update(_ old: [MeetingNoteLine], text: String, now: Double) -> [MeetingNoteLine] {
        var unused = old
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if let index = unused.firstIndex(where: { $0.text == line }) {
                return unused.remove(at: index)
            }
            return MeetingNoteLine(text: line, at: now)
        }
    }
}
