import Foundation

/// What AI did with one history row: the status line of the expanded row and the chip of the
/// collapsed one ("AI", "AI ✕") both read it, so the owner can see at a glance whether AI works.
enum HistoryAIStatus: Equatable, Sendable {
    /// The row has an AI version; mode, model and time when they were recorded; `unchanged` when
    /// the AI gave back the same text (so the two cards look alike for a reason).
    case enhanced(mode: String?, model: String?, ms: Int?, unchanged: Bool = false)
    /// A mode ran (or was meant to) and produced no text; the note says why.
    case skipped(note: String)
    /// Dictated with AI off.
    case none

    init(record: DictationRecord) {
        if record.enhancedText != nil {
            self = .enhanced(
                mode: Self.nonEmpty(record.enhancementMode),
                model: Self.nonEmpty(record.enhancementModel),
                ms: record.enhancementMs,
                unchanged: Self.sameText(record.enhancedText, record.text)
            )
        } else if let note = Self.nonEmpty(record.enhancementNote) {
            self = .skipped(note: note)
        } else {
            self = .none
        }
    }

    /// "AI: E-mail · openai/gpt-4.1-mini · 812 ms", "AI pominięte: Brak klucza OpenRouter", "Bez AI".
    var line: String {
        switch self {
        case .enhanced(let mode, let model, let ms, let unchanged):
            var parts: [String] = []
            if let mode { parts.append(mode) }
            if let model { parts.append(Enhancer.displayName(forModel: model)) }
            if let ms { parts.append(String(localized: "\(ms) ms")) }
            if unchanged { parts.append(String(localized: "bez zmian")) }
            guard !parts.isEmpty else { return String(localized: "Tekst poprawiony przez AI") }
            return String(localized: "AI: \(parts.joined(separator: " · "))")
        case .skipped(let note):
            return String(localized: "AI pominięte: \(note)")
        case .none:
            return String(localized: "Bez AI")
        }
    }

    /// The AI's text is the transcript as it was, ignoring only the whitespace around it.
    private static func sameText(_ enhanced: String?, _ raw: String) -> Bool {
        guard let enhanced else { return false }
        return enhanced.trimmingCharacters(in: .whitespacesAndNewlines) == raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
