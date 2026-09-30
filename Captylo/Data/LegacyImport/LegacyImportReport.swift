import Foundation

/// Counts of one import run (or a dry run, which counts what a real run would do). Printed as
/// JSON by `--import-legacy` and summarized in Ustawienia > Dane.
struct LegacyImportReport: Codable, Sendable, Equatable {
    var dryRun = false
    /// Old stores found on disk.
    var sourcesFound = 0
    /// `ZTRANSCRIPTION` rows over every source.
    var rowsFound = 0
    /// New history rows (in a dry run: rows that would be added).
    var imported = 0
    /// Rows whose id is already in Captylo (an earlier import, also when since deleted from Historia).
    var skippedExisting = 0
    /// The same id in two old stores: the first source (the newer app) wins.
    var skippedDuplicate = 0
    /// No text and not failed.
    var skippedEmpty = 0
    /// The old app's "[PREWARM]" warm-up rows.
    var skippedPrewarm = 0
    /// Imported rows with the `failed` status (error kept in `errorMessage`).
    var failedRowsImported = 0
    /// Imported rows with an AI version.
    var withAI = 0
    /// New `UsageStat` rows (one per imported completed row).
    var usageStatsAdded = 0
    /// Recordings hard-linked into `Recordings/` (or already there under the same name).
    var audioLinked = 0
    /// Rows that point at a recording that is no longer on disk.
    var audioMissing = 0
    /// Recordings on another volume: never copied (the disk is tight), the row keeps no audio.
    var audioNotLinkable = 0
    /// Recordings older than the "Usuwaj nagrania po" limit: retention would delete them at once.
    var audioSkippedByRetention = 0
    /// WAV files in the old recordings folders.
    var recordingsFound = 0
    var vocabularyAdded = 0
    var rulesAdded = 0
    /// Words of the imported completed rows (old counting rule).
    var totalWords = 0
    /// Words of every importable completed row found, imported before or not.
    var wordsFound = 0
    /// Wall time of the run.
    var seconds = 0.0

    /// Rows that can come over (new or already imported): what "Znaleziono" shows.
    var importableRows: Int { imported + skippedExisting }
}
