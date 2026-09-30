import Foundation
import Testing
@testable import Captylo

struct HistoryAIStatusTests {
    @Test func aiTextGivesModeModelAndTime() {
        let record = DictationRecord(
            text: "surowy tekst",
            enhancedText: "Poprawiony tekst.",
            enhancementModel: "openai/gpt-4.1-mini",
            enhancementMs: 812,
            enhancementMode: "E-mail"
        )
        let status = HistoryAIStatus(record: record)
        #expect(status == .enhanced(mode: "E-mail", model: "openai/gpt-4.1-mini", ms: 812))
        #expect(status.line.contains("E-mail"))
        #expect(status.line.contains("openai/gpt-4.1-mini"))
        #expect(status.line.contains("812"))
        #expect(status.line.hasPrefix("AI"))
    }

    @Test func rowsFromBeforeModesStillShowTheModel() {
        let record = DictationRecord(text: "a", enhancedText: "b", enhancementModel: "m", enhancementMs: 5)
        #expect(HistoryAIStatus(record: record) == .enhanced(mode: nil, model: "m", ms: 5))
    }

    @Test func aiTextWithoutAnyDetailsHasAPlainLine() {
        let status = HistoryAIStatus(record: DictationRecord(text: "a", enhancedText: "b"))
        #expect(status == .enhanced(mode: nil, model: nil, ms: nil))
        #expect(status.line == String(localized: "Tekst poprawiony przez AI"))
    }

    @Test func noteWithoutTextIsSkipped() {
        let note = EnhancementSkip.noKey.note
        let record = DictationRecord(text: "a b c d e", enhancementMode: "Czyszczenie", enhancementNote: note)
        let status = HistoryAIStatus(record: record)
        #expect(status == .skipped(note: note))
        #expect(status.line == String(localized: "AI pominięte: \(note)"))
    }

    @Test func aiTextWinsOverAStaleNote() {
        let record = DictationRecord(text: "a", enhancedText: "b", enhancementMode: "E-mail", enhancementNote: "stara notatka")
        #expect(HistoryAIStatus(record: record) == .enhanced(mode: "E-mail", model: nil, ms: nil))
    }

    @Test func noAIFieldsMeansBezAI() {
        let status = HistoryAIStatus(record: DictationRecord(text: "a"))
        #expect(status == .none)
        #expect(status.line == String(localized: "Bez AI"))
    }

    @Test func blankNoteAndModeCountAsMissing() {
        let record = DictationRecord(text: "a", enhancementMode: "  ", enhancementNote: " \n")
        #expect(HistoryAIStatus(record: record) == .none)
    }

    @Test func applyingAnOutcomeFeedsTheStatus() {
        var record = DictationRecord(text: "jeden dwa trzy cztery")
        record.applyEnhancement(.failed(.deadline(seconds: 3), ms: 3000), mode: "Czyszczenie")
        #expect(HistoryAIStatus(record: record) == .skipped(note: EnhancementFailure.deadline(seconds: 3).note))
        record.applyEnhancement(.enhanced(text: "Jeden, dwa, trzy, cztery.", ms: 700, model: "m"), mode: "Czyszczenie")
        #expect(HistoryAIStatus(record: record) == .enhanced(mode: "Czyszczenie", model: "m", ms: 700))
    }

    @MainActor
    @Test func previewOpensARewriteRowFirst() {
        let records = DesignPreviewData.sampleRecords(now: Date())
        let id = DesignPreviewData.historyRowToExpand(in: records)
        let row = records.first { $0.id == id }
        #expect(row?.enhancedText != nil)
        #expect(row?.enhancementMode != BuiltInAIModes.cleanup.name)
    }

    @MainActor
    @Test func previewFallsBackToAnyAIRow() {
        let cleanup = DictationRecord(text: "a", enhancedText: "b", enhancementMode: BuiltInAIModes.cleanup.name)
        let plain = DictationRecord(text: "c")
        #expect(DesignPreviewData.historyRowToExpand(in: [plain, cleanup]) == cleanup.id)
        #expect(DesignPreviewData.historyRowToExpand(in: [plain]) == nil)
    }
}
