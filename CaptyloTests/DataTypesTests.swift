import Foundation
import Testing
@testable import Captylo

struct DataTypesTests {
    @Test func dictionaryDataDecodesMissingKeysToDefaults() throws {
        let json = #"{"vocabulary":["Captylo"]}"#.data(using: .utf8)!
        let data = try JSONDecoder().decode(DictionaryData.self, from: json)
        #expect(data.version == DictionaryData.currentVersion)
        #expect(data.vocabulary == ["Captylo"])
        #expect(data.replacements.isEmpty)
        #expect(data.fillerWords == DictionaryData.defaultFillerWords)
        #expect(DictionaryData.defaultFillerWords == ["yyy", "yy", "eee", "ee", "mmm", "hmm", "hm", "um", "uh", "uhm"])
    }

    @Test func replacementRuleWithoutIDGetsOne() throws {
        let json = #"{"replacements":[{"triggers":["kap tylo"],"replacement":"Captylo"}]}"#.data(using: .utf8)!
        let data = try JSONDecoder().decode(DictionaryData.self, from: json)
        let rule = try #require(data.replacements.first)
        #expect(rule.triggers == ["kap tylo"])
        #expect(rule.replacement == "Captylo")

        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(DictionaryData.self, from: encoded)
        #expect(decoded == data)
    }

    @Test func dictationRecordMapsToModelAndBack() {
        let record = DictationRecord(
            text: "Cześć",
            enhancedText: "Cześć!",
            status: .completed,
            source: .file,
            audioDuration: 2.5,
            audioFileName: "x.wav",
            language: "pl",
            modelName: "parakeet-tdt-0.6b-v3",
            transcriptionMs: 120,
            enhancementModel: "openai/gpt-4.1-mini",
            enhancementMs: 640,
            wordCount: 1
        )
        let model = Dictation(record)
        #expect(model.finalText == "Cześć!")
        #expect(model.status == "completed")
        #expect(model.source == "file")
        #expect(model.record == record)

        var updated = record
        updated.text = "Nowy tekst"
        updated.enhancedText = nil
        model.apply(updated)
        #expect(model.finalText == "Nowy tekst")
        #expect(model.id == record.id)

        let stat = UsageStat(record)
        #expect(stat.dictationID == record.id)
        #expect(stat.wordCount == 1)
        #expect(stat.audioDuration == 2.5)
        #expect(stat.source == "file")
    }

    @Test func modelDefaults() {
        let dictation = Dictation()
        #expect(dictation.status == "completed")
        #expect(dictation.source == "dictation")
        #expect(dictation.finalText == "")
        #expect(dictation.record.status == .completed)
    }

    @Test func appPaths() {
        #expect(AppPaths.dataDirectory.path(percentEncoded: false).hasSuffix("Application Support/Captylo/"))
        #expect(AppPaths.store.lastPathComponent == "Captylo.store")
        #expect(AppPaths.dictionaryJSON.lastPathComponent == "dictionary.json")
        #expect(AppPaths.recordings.lastPathComponent == "Recordings")
        let id = UUID()
        #expect(AppPaths.recordingURL(for: id).lastPathComponent == "\(id.uuidString).wav")
        #expect(AppPaths.recordingURL(fileName: "a.wav").deletingLastPathComponent() == AppPaths.recordings)
        #expect(AppPaths.parakeetModelDir.lastPathComponent == "parakeet-tdt-0.6b-v3")
    }

    @Test func snapshotAndTrendTypes() {
        #expect(DashboardSnapshot.empty.sessions == 0)
        #expect(DashboardSnapshot.empty.wpm == nil)
        #expect(DashboardSnapshot.rangeOptions == [7, 14, 30])
        let bucket = DayBucket(date: Date(timeIntervalSince1970: 0), words: 10, minutes: 1.5, sessions: 2)
        #expect(bucket.value(for: .words) == 10)
        #expect(bucket.value(for: .minutes) == 1.5)
        #expect(bucket.value(for: .sessions) == 2)
        #expect(TrendMode(rawValue: "daily") == .daily)
        #expect(TrendMetric(rawValue: "words") == .words)
    }

    @Test func enhancementOutcomeText() {
        #expect(EnhancementOutcome.enhanced(text: "A", ms: 1, model: "m").text == "A")
        #expect(EnhancementOutcome.skipped(.noKey).text == nil)
        #expect(EnhancementOutcome.skipped(.noKey).ms == nil)
        #expect(EnhancementOutcome.failed(.deadline(seconds: 3), ms: 3000).text == nil)
        #expect(EnhancementOutcome.failed(.deadline(seconds: 3), ms: 3000).ms == 3000)
    }

    @Test func errorsHavePolishDescriptions() {
        #expect(DictationError.emptyResult.errorDescription == "Nic nie usłyszałem.")
        #expect(DictationError.stt(.unauthorized).errorDescription == "Nieprawidłowy klucz API")
        #expect(STTError.server(500, "boom").errorDescription == "Błąd serwera (500).")
        #expect(DictationError.noMicrophone(lidClosed: true).errorDescription?.contains("Pokrywa") == true)
    }
}
