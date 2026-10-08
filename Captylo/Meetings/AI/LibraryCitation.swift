import Foundation

/// A `[S1 12:34]` or `[N1]` citation in a "Zapytaj wszystkie spotkania" answer: the meeting it
/// names (its number in the prompt, `LibraryAskContext.sources` order) and the moment, `[S1]`
/// for the meeting alone, or a note (`LibraryAskContext.notes` order). A number the answer was
/// not given (`[S9]`, `[N9]`), a plain `[12:34]`, a lowercase `[s1 ...]` or an impossible time
/// stay plain text.
struct LibraryCitation: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case meeting
        case note
    }

    /// Where it sits in the parsed text.
    var range: Range<String.Index>
    var kind: Kind
    /// 1-based, as in the prompt (`S` or `N` numbers).
    var number: Int
    /// The meeting or the note it names.
    var targetID: UUID
    /// Seconds from the meeting start; nil for `[S1]` and notes.
    var seconds: Double?

    var meetingID: UUID? { kind == .meeting ? targetID : nil }
    var noteID: UUID? { kind == .note ? targetID : nil }

    /// "S1 12:34", "S2 1:02:03", "S1" or "N1": the button title.
    var label: String {
        if kind == .note { return "N\(number)" }
        guard let seconds else { return "S\(number)" }
        return "S\(number) \(MeetingTime.clock(seconds))"
    }

    /// One line of an answer as the panel lays it out: the text without its citations (inline
    /// Markdown kept) and the citations in order.
    struct Line: Sendable, Equatable {
        var isBullet: Bool
        var text: String
        var citations: [LibraryCitation]
    }

    /// `[S1 12:34]`, `[S1 1:02:03]`, `[S1, 12:34]`, `[S1]` or `[N1]`.
    private static let regex = try! NSRegularExpression(pattern: #"\[(?:S(\d{1,2})(?:,?\s+(?:(\d+):)?(\d{1,2}):(\d{2}))?|N(\d{1,2}))\]"#)
    /// Longest meeting a citation can point into (also keeps the arithmetic far from overflow).
    private static let maxHours = 99

    /// Every valid citation of `markdown`, in order. `meetings[0]` is `S1`, `notes[0]` is `N1`.
    static func parse(_ markdown: String, meetings: [UUID], notes: [UUID] = []) -> [LibraryCitation] {
        let ns = markdown as NSString
        return regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            citation(match, in: markdown, meetings: meetings, notes: notes)
        }
    }

    /// The answer as lines: blank lines dropped, "- " and "* " bullets marked, "#" headings as
    /// plain lines, each without its citations (and the space before each).
    static func lines(_ markdown: String, meetings: [UUID], notes: [UUID] = []) -> [Line] {
        markdown.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            var isBullet = false
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                isBullet = true
                line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#") {
                line = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { return nil }
            let citations = parse(line, meetings: meetings, notes: notes)
            var text = ""
            var cursor = line.startIndex
            for citation in citations {
                var lower = citation.range.lowerBound
                while lower > cursor, line[line.index(before: lower)].isWhitespace {
                    lower = line.index(before: lower)
                }
                text += line[cursor..<lower]
                cursor = citation.range.upperBound
            }
            text += line[cursor...]
            return Line(isBullet: isBullet, text: text.trimmingCharacters(in: .whitespaces), citations: citations)
        }
    }

    private static func citation(_ match: NSTextCheckingResult, in text: String, meetings: [UUID], notes: [UUID]) -> LibraryCitation? {
        func number(_ group: Int) -> Int? {
            guard let range = Range(match.range(at: group), in: text) else { return nil }
            return Int(text[range])
        }
        guard let range = Range(match.range, in: text) else { return nil }
        if let note = number(5) {
            guard note >= 1, note <= notes.count else { return nil }
            return LibraryCitation(range: range, kind: .note, number: note, targetID: notes[note - 1], seconds: nil)
        }
        guard let index = number(1), index >= 1, index <= meetings.count else { return nil }
        var seconds: Double?
        if match.range(at: 3).location != NSNotFound {
            guard let minutes = number(3), let secs = number(4), secs < 60 else { return nil }
            if match.range(at: 2).location != NSNotFound {
                guard let hours = number(2), hours <= maxHours, minutes < 60 else { return nil }
                seconds = Double(hours * 3600 + minutes * 60 + secs)
            } else {
                seconds = Double(minutes * 60 + secs)
            }
        }
        return LibraryCitation(range: range, kind: .meeting, number: index, targetID: meetings[index - 1], seconds: seconds)
    }
}
