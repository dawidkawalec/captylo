import Foundation

/// The AI notes Markdown as the "Notatki AI" tab lays it out: sections under their headings,
/// each a list of rows (bullets, checkable tasks, plain lines) whose `[mm:ss]` citations are
/// pulled out for the play stamps (`MeetingCitations`). Inline Markdown (bold, italics) stays
/// in the row text. The raw Markdown is still what "Kopiuj" and the export use.
struct MeetingNotesDocument: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        /// Inline Markdown without the citations.
        let text: String
        /// Cited meeting seconds, in order.
        let citations: [Double]
    }

    enum Item: Equatable, Sendable {
        case bullet(Line)
        /// A bullet under "Zadania" (what `MeetingNotesParser.actionItems` reads), or one written
        /// "- [ ]" / "- [x]" anywhere. `index` counts the tasks of the whole document from 0.
        case task(index: Int, line: Line, done: Bool)
        case paragraph(Line)

        var line: Line {
            switch self {
            case .bullet(let line), .paragraph(let line): return line
            case .task(_, let line, _): return line
            }
        }
    }

    struct Section: Equatable, Sendable {
        /// The heading without "#" (and a trailing colon); nil for lines before the first heading.
        let title: String?
        let items: [Item]
    }

    let sections: [Section]

    /// Every task, in order.
    var tasks: [Line] {
        sections.flatMap(\.items).compactMap { item in
            if case .task(_, let line, _) = item { return line }
            return nil
        }
    }

    init(markdown: String) {
        var sections: [Section] = []
        var title: String?
        var items: [Item] = []
        var inTasks = false
        var taskCount = 0

        func close() {
            if title != nil || !items.isEmpty {
                sections.append(Section(title: title, items: items))
            }
        }

        for raw in markdown.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                let heading = line.drop { $0 == "#" }
                    .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":")))
                guard !heading.isEmpty else { continue }
                close()
                title = heading
                items = []
                inTasks = MeetingSearch.fold(heading) == "zadania"
                continue
            }
            if let body = Self.bulletBody(line) {
                if let (done, rest) = Self.checkbox(body) {
                    items.append(.task(index: taskCount, line: MeetingCitations.split(rest), done: done))
                    taskCount += 1
                } else if inTasks {
                    items.append(.task(index: taskCount, line: MeetingCitations.split(body), done: false))
                    taskCount += 1
                } else {
                    items.append(.bullet(MeetingCitations.split(body)))
                }
            } else {
                items.append(.paragraph(MeetingCitations.split(line)))
            }
        }
        close()
        self.sections = sections
    }

    /// The text after "- " or "* ", nil for any other line.
    private static func bulletBody(_ line: String) -> String? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
        let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    /// "[ ] text" or "[x] text": whether it is checked and the text after the box.
    private static func checkbox(_ body: String) -> (Bool, String)? {
        let lowered = body.lowercased()
        for (prefix, done) in [("[ ] ", false), ("[x] ", true)] where lowered.hasPrefix(prefix) {
            let rest = body.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : (done, rest)
        }
        return nil
    }
}
