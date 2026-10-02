/// The single word-count rule used for stats (brief section 6): tokens split on whitespace
/// that contain at least one letter or digit. Computed once at save on the delivered text.
enum WordCounter {
    static func count(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).reduce(0) { total, token in
            total + (isWord(token) ? 1 : 0)
        }
    }

    private static func isWord(_ token: Substring) -> Bool {
        token.contains { $0.isLetter || $0.isNumber }
    }
}
