import Foundation

/// Immutable ICU regex wrapper. `NSRegularExpression` is documented as thread-safe but is not
/// marked `Sendable`, so the text module keeps every precompiled pattern behind this value type.
struct ICUPattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String, options: NSRegularExpression.Options = []) throws {
        regex = try NSRegularExpression(pattern: pattern, options: options)
    }

    /// For patterns fixed at compile time. A malformed literal is a programming error.
    static func fixed(_ pattern: String, options: NSRegularExpression.Options = []) -> ICUPattern {
        do {
            return try ICUPattern(pattern, options: options)
        } catch {
            fatalError("Invalid ICU pattern \(pattern): \(error)")
        }
    }

    /// Replaces every match using ICU template semantics (`$1`, `\` are special).
    /// Pass `NSRegularExpression.escapedTemplate(for:)` for a literal replacement.
    func replacing(in text: String, withTemplate template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: fullRange(text), withTemplate: template)
    }

    func removing(from text: String) -> String {
        replacing(in: text, withTemplate: "")
    }

    func matches(in text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: fullRange(text))
    }

    /// Rebuilds `text` by replacing each match with the output of `transform` (match, text before it).
    func rewrite(_ text: String, _ transform: (NSTextCheckingResult, NSString) -> String) -> String {
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in matches(in: text) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(match, source)
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }

    private func fullRange(_ text: String) -> NSRange {
        NSRange(text.startIndex..., in: text)
    }
}
