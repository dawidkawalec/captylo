import Foundation

/// Where our pasted text sits in a text field, and how to find it again after the user edited
/// it (pure, UTF-16 offsets like the Accessibility API). The paste is located by diffing the
/// field before and after Cmd+V; later the text between the same neighbours is our text as the
/// user left it.
enum EditSpan {
    /// Characters of context kept on each side of the paste.
    static let contextLength = 40

    struct Anchor: Equatable, Sendable {
        /// Text right before the paste ("" when it starts the field).
        var prefix: String
        /// Text right after the paste ("" when it ends the field).
        var suffix: String
        /// UTF-16 offset of the paste in the field when it landed.
        var location: Int
    }

    /// The range that changed between `before` and `after` (common prefix and suffix removed),
    /// as it is in `after`.
    static func inserted(before: String, after: String) -> NSRange {
        let a = Array(before.utf16)
        let b = Array(after.utf16)
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] {
            start += 1
        }
        var tail = 0
        while tail < a.count - start, tail < b.count - start, a[a.count - 1 - tail] == b[b.count - 1 - tail] {
            tail += 1
        }
        return NSRange(location: start, length: b.count - start - tail)
    }

    /// Finds the paste of `delivered` in `after`: the changed range when it matches (a selection
    /// the paste replaced is fine), otherwise the occurrence closest to it. Nil when the field
    /// does not contain the text (the app changed it on paste, or the paste went elsewhere).
    static func locate(delivered: String, before: String, after: String) -> NSRange? {
        let text = delivered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let ns = after as NSString
        let changed = inserted(before: before, after: after)
        let changedText = ns.substring(with: changed)
        if changedText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            let leading = changedText.utf16.count - changedText.drop(while: \.isWhitespace).utf16.count
            return NSRange(location: changed.location + leading, length: (text as NSString).length)
        }
        return nearestOccurrence(of: text, in: ns, near: changed.location)
    }

    static func anchor(in after: String, paste: NSRange) -> Anchor {
        let ns = after as NSString
        let prefixStart = max(0, paste.location - contextLength)
        let prefix = ns.substring(with: NSRange(location: prefixStart, length: paste.location - prefixStart))
        let end = paste.location + paste.length
        let suffix = ns.substring(with: NSRange(location: end, length: min(contextLength, ns.length - end)))
        return Anchor(prefix: prefix, suffix: suffix, location: paste.location)
    }

    /// Our text as it is now: what lies between the prefix (the occurrence ending closest to the
    /// original spot) and the next suffix. Nil when a neighbour was edited away.
    static func extract(from value: String, anchor: Anchor) -> String? {
        let ns = value as NSString
        var start = 0
        if !anchor.prefix.isEmpty {
            guard let found = nearestOccurrence(of: anchor.prefix, in: ns, near: anchor.location - (anchor.prefix as NSString).length) else {
                return nil
            }
            start = found.location + found.length
        }
        var end = ns.length
        if !anchor.suffix.isEmpty {
            let found = ns.range(of: anchor.suffix, range: NSRange(location: start, length: ns.length - start))
            guard found.location != NSNotFound else { return nil }
            end = found.location
        }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    private static func nearestOccurrence(of needle: String, in haystack: NSString, near location: Int) -> NSRange? {
        var best: NSRange?
        var searchStart = 0
        while searchStart <= haystack.length {
            let found = haystack.range(of: needle, range: NSRange(location: searchStart, length: haystack.length - searchStart))
            guard found.location != NSNotFound else { break }
            if best == nil || abs(found.location - location) < abs(best!.location - location) {
                best = found
            }
            searchStart = found.location + max(found.length, 1)
        }
        return best
    }
}
