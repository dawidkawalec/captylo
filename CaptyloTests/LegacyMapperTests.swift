import Foundation
import Testing
@testable import Captylo

struct LegacyMapperTests {
    private static let path = "/Users/x/Library/Application Support/com.dawidkawalec.VocaType/default.store"

    private static func mapped(_ row: LegacyRow) -> LegacyMappedRow? {
        guard case .importRow(let mapped) = LegacyMapper.map(row, sourcePath: path) else { return nil }
        return mapped
    }

    @Test func completedRowKeepsEveryField() throws {
        let id = UUID()
        let row = LegacyRow(
            pk: 7, id: id, timestamp: 788_745_334.19, duration: 12.5, transcriptionDuration: 0.4216,
            text: "  raz dwa trzy \n", status: "completed",
            audioFileURL: "file:///Users/x/Library/Application%20Support/com.prakashjoshipax.VocaType/Recordings/165F245C-DA2A-4B9C-803F-D36222109DB5.wav",
            transcriptionModelName: "Parakeet V3", promptName: "Default"
        )
        let result = try #require(Self.mapped(row))
        let record = result.record
        #expect(record.id == id)
        #expect(record.createdAt == Date(timeIntervalSinceReferenceDate: 788_745_334.19))
        #expect(record.text == "raz dwa trzy")
        #expect(record.status == .completed)
        #expect(record.errorMessage == nil)
        #expect(record.source == .imported)
        #expect(record.audioDuration == 12.5)
        #expect(record.audioFileName == nil)
        #expect(record.language == nil)
        #expect(record.modelName == "Parakeet V3")
        #expect(record.transcriptionMs == 422)
        #expect(record.wordCount == 3)
        // No AI ran: the prompt name alone does not make it an AI row.
        #expect(record.enhancedText == nil)
        #expect(record.enhancementMode == nil)
        #expect(record.enhancementModel == nil)
        #expect(result.sourceAudioFileName == "165F245C-DA2A-4B9C-803F-D36222109DB5.wav")
        #expect(result.createsUsageStat)
        #expect(!result.hasAI)
    }

    @Test func failedTextBecomesTheErrorMessage() throws {
        let row = LegacyRow(pk: 1, id: UUID(), text: "Transcription Failed: Failed to load the transcription model", status: "completed")
        let record = try #require(Self.mapped(row)).record
        #expect(record.status == .failed)
        #expect(record.text == "")
        #expect(record.errorMessage == "Transcription Failed: Failed to load the transcription model")
        #expect(record.wordCount == 0)
        #expect(try #require(Self.mapped(row)).createsUsageStat == false)
    }

    @Test func failedStatusWithoutTextStillImports() throws {
        let record = try #require(Self.mapped(LegacyRow(pk: 1, id: UUID(), text: nil, status: "failed"))).record
        #expect(record.status == .failed)
        #expect(record.text == "")
        #expect(record.errorMessage?.isEmpty == false)
    }

    @Test func pendingWithTextIsCompleted() throws {
        let record = try #require(Self.mapped(LegacyRow(pk: 1, id: UUID(), text: "Ok, wygląda dobrze", status: "pending"))).record
        #expect(record.status == .completed)
        #expect(record.text == "Ok, wygląda dobrze")
    }

    @Test func emptyAndPrewarmRowsAreSkipped() {
        #expect(LegacyMapper.map(LegacyRow(pk: 1, text: "   ", status: "completed"), sourcePath: Self.path) == .skipEmpty)
        #expect(LegacyMapper.map(LegacyRow(pk: 2, text: nil, status: "pending"), sourcePath: Self.path) == .skipEmpty)
        #expect(LegacyMapper.map(LegacyRow(pk: 3, text: "[PREWARM] ", status: "pending"), sourcePath: Self.path) == .skipPrewarm)
    }

    @Test func enhancedTextComesWithItsAIFields() throws {
        let row = LegacyRow(
            pk: 1, id: UUID(), enhancementDuration: 1.25, text: "to jest tekst", enhancedText: "To jest tekst, poprawione.",
            status: "completed", enhancementModelName: "gemini-2.5-flash", promptName: "Gramatik", powerModeName: "Praca"
        )
        let result = try #require(Self.mapped(row))
        #expect(result.record.enhancedText == "To jest tekst, poprawione.")
        #expect(result.record.enhancementModel == "gemini-2.5-flash")
        #expect(result.record.enhancementMs == 1250)
        #expect(result.record.enhancementMode == "Gramatik")
        #expect(result.record.enhancementNote == nil)
        // Old rule over the delivered (AI) text.
        #expect(result.record.wordCount == 4)
        #expect(result.hasAI)
    }

    @Test func failedEnhancementBecomesANote() throws {
        let row = LegacyRow(
            pk: 1, id: UUID(), enhancementDuration: 3, text: "a b c", enhancedText: "Enhancement failed: rateLimitExceeded",
            status: "completed", enhancementModelName: "gpt-5.1", powerModeName: "Mail"
        )
        let record = try #require(Self.mapped(row)).record
        #expect(record.enhancedText == nil)
        #expect(record.enhancementNote == "Enhancement failed: rateLimitExceeded")
        #expect(record.enhancementMode == "Mail")
        #expect(record.enhancementModel == "gpt-5.1")
        #expect(record.wordCount == 3)
    }

    @Test func wordCountUsesTheOldSpaceRule() throws {
        let record = try #require(Self.mapped(LegacyRow(pk: 1, id: UUID(), text: "jeden  dwa\ntrzy - ok", status: "completed"))).record
        #expect(record.wordCount == WordCounter.legacyCount("jeden  dwa\ntrzy - ok"))
        #expect(record.wordCount == 4)
    }

    @Test func rowsWithoutIDGetAStableID() throws {
        let first = try #require(Self.mapped(LegacyRow(pk: 42, text: "bez id", status: "completed"))).record.id
        let again = try #require(Self.mapped(LegacyRow(pk: 42, text: "bez id", status: "completed"))).record.id
        let otherPK = LegacyMapper.deterministicID(sourcePath: Self.path, pk: 43)
        let otherStore = LegacyMapper.deterministicID(sourcePath: "/tmp/other.store", pk: 42)
        #expect(first == again)
        #expect(first != otherPK)
        #expect(first != otherStore)
        // Version 5 layout, RFC 4122 variant.
        #expect(first.uuidString.dropFirst(14).first == "5")
        #expect("89AB".contains(first.uuidString.dropFirst(19).first ?? "x"))
    }

    @Test func audioFileNameFromTheOldURL() {
        #expect(LegacyMapper.audioFileName(from: "file:///a/Application%20Support/Recordings/X%201.wav") == "X 1.wav")
        #expect(LegacyMapper.audioFileName(from: "/Users/x/Application Support/Recordings/Y.wav") == "Y.wav")
        #expect(LegacyMapper.audioFileName(from: nil) == nil)
        #expect(LegacyMapper.audioFileName(from: "  ") == nil)
        #expect(LegacyMapper.audioFileName(from: "file:///") == nil)
    }

    @Test func uuidFromBlobKeepsTheByteOrder() {
        let id = UUID(uuidString: "00630B62-27AB-42DE-B54B-8D5DCB32BFD6")!
        var raw = id.uuid
        let decoded = withUnsafeBytes(of: &raw) { LegacyStoreReader.uuid(fromBytes: $0) }
        #expect(decoded == id)
        #expect([UInt8](repeating: 1, count: 15).withUnsafeBytes { LegacyStoreReader.uuid(fromBytes: $0) } == nil)
    }

    @Test func vocabularyIsTrimmedAndDeduped() {
        #expect(LegacyMapper.vocabulary([" Captylo ", "captylo", "", "Kawalec"]) == ["Captylo", "Kawalec"])
    }

    @Test func replacementsAreGroupedByReplacement() {
        let rules = LegacyMapper.rules([
            LegacyReplacementRow(original: "kaptylo, kapitylo", replacement: "Captylo", isEnabled: true),
            LegacyReplacementRow(original: "wył", replacement: "wyłącznie", isEnabled: false),
            LegacyReplacementRow(original: "kaptilo, Kaptylo", replacement: " Captylo ", isEnabled: true),
            LegacyReplacementRow(original: " , ", replacement: "nic", isEnabled: true),
            LegacyReplacementRow(original: "gpt", replacement: "GPT", isEnabled: true),
        ])
        #expect(rules.map(\.replacement) == ["Captylo", "GPT"])
        #expect(rules.first?.triggers == ["kaptylo", "kapitylo", "kaptilo"])
        #expect(rules.last?.triggers == ["gpt"])
    }
}
