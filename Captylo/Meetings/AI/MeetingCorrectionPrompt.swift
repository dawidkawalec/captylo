import Foundation

/// The pure half of "Poprawiaj transkrypt przez AI" (`CaptyloAITask.Kind.transcriptCorrection`,
/// the relay holds the instructions): batches of numbered lines, the data sent, the parser of the
/// answer (`numer|tekst` lines) and the guard that keeps a line the AI changed too much. A line is only
/// ever swapped for its fixed version: lines are never merged, split, dropped or added, so every
/// segment keeps its time, track and speaker.
enum MeetingCorrectionPrompt {
    /// One batch: at most this many lines...
    static let batchLines = 80
    /// ...and about this many characters of transcript.
    static let batchCharacters = 7_000

    /// The lines worth fixing (no echo, not empty) in time order, cut into batches.
    static func batches(_ segments: [MeetingSegmentRecord]) -> [[MeetingSegmentRecord]] {
        let lines = segments
            .filter { !$0.isEcho && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        var result: [[MeetingSegmentRecord]] = []
        var current: [MeetingSegmentRecord] = []
        var characters = 0
        for line in lines {
            if !current.isEmpty, current.count >= batchLines || characters + line.text.count > batchCharacters {
                result.append(current)
                current = []
                characters = 0
            }
            current.append(line)
            characters += line.text.count
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    /// Answer cap for a batch: about the batch's own length in tokens, with room to spare.
    static func maxTokens(for batch: [MeetingSegmentRecord]) -> Int {
        let characters = batch.reduce(0) { $0 + $1.text.count + 6 }
        return min(8_000, max(1_000, characters / 2 + 400))
    }

    /// The title and glossary for context, then the batch numbered from 1.
    static func user(title: String, glossary: [String], batch: [MeetingSegmentRecord]) -> String {
        var parts = ["Tytuł spotkania: \(title)"]
        let terms = glossary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !terms.isEmpty {
            parts.append("Słownik (pisownia nazw i terminów): " + terms.prefix(200).joined(separator: ", "))
        }
        let lines = batch.enumerated().map { index, segment in
            "\(index + 1)|" + oneLine(segment.text)
        }
        parts.append("Transkrypt:\n" + lines.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }

    /// Line number -> text from an answer; anything that is not `number|text` is skipped.
    static func parse(_ reply: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for raw in reply.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let bar = line.firstIndex(of: "|"),
                  let number = Int(line[..<bar].trimmingCharacters(in: .whitespaces)),
                  result[number] == nil else { continue }
            let text = line[line.index(after: bar)...].trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                result[number] = text
            }
        }
        return result
    }

    /// Whether `fixed` may replace `original`: still about as many words and characters. A model
    /// that summarizes, drops half a line or adds a sentence loses that line, not the transcript.
    static func accepts(_ fixed: String, for original: String) -> Bool {
        let before = words(original).count
        let after = words(fixed).count
        guard after > 0 else { return false }
        guard abs(after - before) <= max(2, before / 4) else { return false }
        let difference = abs(fixed.count - original.count)
        return difference <= 12 || Double(difference) <= Double(original.count) * 0.4
    }

    /// The fixed lines of one batch that differ from the original and pass `accepts`, carrying
    /// the new text, the text they had before the first fix and word times spread over the new words.
    static func changes(in batch: [MeetingSegmentRecord], reply: String) -> [MeetingSegmentRecord] {
        let fixed = parse(reply)
        return batch.enumerated().compactMap { index, segment in
            guard let text = fixed[index + 1], text != segment.text, accepts(text, for: segment.text) else { return nil }
            var changed = segment
            changed.originalText = segment.originalText ?? segment.text
            changed.text = text
            changed.words = retimed(segment, text: text)
            return changed
        }
    }

    /// Word times for the new text: the old times when the word count is the same, otherwise
    /// spread over the old span by word length.
    static func retimed(_ segment: MeetingSegmentRecord, text: String) -> [MeetingWord] {
        let tokens = words(text)
        guard !tokens.isEmpty else { return [] }
        if tokens.count == segment.words.count {
            return zip(tokens, segment.words).map { MeetingWord(text: $0, start: $1.start, end: $1.end) }
        }
        let start = segment.words.first?.start ?? segment.start
        let end = max(start, segment.words.last?.end ?? segment.end)
        let total = Double(tokens.reduce(0) { $0 + $1.count })
        var at = start
        return tokens.map { token in
            let length = total > 0 ? (end - start) * Double(token.count) / total : 0
            defer { at += length }
            return MeetingWord(text: token, start: at, end: at + length)
        }
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }
}
