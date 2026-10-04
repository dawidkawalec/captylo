import Foundation

/// Reads structure back out of the AI notes Markdown.
enum MeetingNotesParser {
    /// Bullet lines ("- " or "* ") under "## Zadania", until the next "## " heading.
    static func actionItems(in markdown: String) -> [String] {
        var inside = false
        var items: [String] = []
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                let heading = line.dropFirst(3).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":")))
                inside = heading.lowercased() == "zadania"
                continue
            }
            if inside, line.hasPrefix("- ") || line.hasPrefix("* ") {
                let item = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !item.isEmpty {
                    items.append(item)
                }
            }
        }
        return items
    }
}
