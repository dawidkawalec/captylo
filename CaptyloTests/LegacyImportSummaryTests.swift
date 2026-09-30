import Foundation
import Testing
@testable import Captylo

struct LegacyImportSummaryTests {
    private static let polish = Locale(identifier: "pl_PL")

    /// Polish grouping uses a no-break space; compare with plain spaces.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @Test func foundLineMatchesTheOwnersNumbers() {
        var report = LegacyImportReport()
        report.imported = 9_452
        report.skippedExisting = 806
        report.wordsFound = 525_310
        report.recordingsFound = 10_397
        #expect(Self.plain(LegacyImportSummary.found(report, locale: Self.polish)) == "Transkrypcje: 10 258 · słowa: 525 tys. · nagrania: 10 397")
    }

    @Test func compactNumbers() {
        #expect(Self.plain(LegacyImportSummary.compactNumber(912, locale: Self.polish)) == "912")
        // Polish typography groups from five digits on.
        #expect(Self.plain(LegacyImportSummary.compactNumber(9_999, locale: Self.polish)) == "9999")
        #expect(Self.plain(LegacyImportSummary.compactNumber(10_499, locale: Self.polish)) == "10 tys.")
        #expect(Self.plain(LegacyImportSummary.compactNumber(1_250_000, locale: Self.polish)) == "1,2 mln")
    }

    @Test func resultAndAudioNote() {
        var report = LegacyImportReport()
        report.imported = 9_452
        report.withAI = 2_600
        report.audioLinked = 9_400
        report.skippedEmpty = 236
        report.skippedPrewarm = 570
        #expect(Self.plain(LegacyImportSummary.result(report, locale: Self.polish)) == "Dodane wpisy: 9452 · z AI: 2600 · nagrania: 9400 · pominięte: 806")
        #expect(LegacyImportSummary.audioNote(report, locale: Self.polish) == nil)
        report.audioMissing = 3
        report.audioNotLinkable = 1
        #expect(LegacyImportSummary.audioNote(report, locale: Self.polish)?.hasSuffix(": 4") == true)
    }

    @Test func markerRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "captylo-marker-\(UUID().uuidString)/legacy-import.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var report = LegacyImportReport()
        report.imported = 3
        let marker = LegacyImportMarker(importedAt: Date(timeIntervalSince1970: 1_790_000_000), report: report)
        try marker.save(to: url)
        #expect(LegacyImportMarker.load(from: url) == marker)
        #expect(LegacyImportMarker.load(from: url.appending(path: "nope")) == nil)
    }
}
