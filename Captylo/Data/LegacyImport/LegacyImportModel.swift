import Foundation
import Observation

/// State of Ustawienia > Dane > "Import ze starego VocaType": a cached dry run for the "found"
/// line, the running import with its progress, the result and the last import marker.
@MainActor
@Observable
final class LegacyImportModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case importing(processed: Int, total: Int)
    }

    private(set) var phase: Phase = .idle
    /// Dry run of the current data (cached; refreshed after an import).
    private(set) var scan: LegacyImportReport?
    /// Result of the import run in this session.
    private(set) var result: LegacyImportReport?
    /// Polish message of the last failure (scan or import).
    private(set) var errorMessage: String?
    /// Last finished import in this data folder (`legacy-import.json`).
    private(set) var lastImport: LegacyImportMarker?
    /// No old store on this Mac (or the store is unavailable): nothing to offer.
    private(set) var sourcesMissing = false

    @ObservationIgnored private let sources: () -> [LegacySource]
    @ObservationIgnored private let database: Database
    @ObservationIgnored private let dictionary: DictionaryStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let stats: StatsTicker
    @ObservationIgnored private let markerURL: URL
    @ObservationIgnored private let recordingsDirectory: URL
    @ObservationIgnored private let storeAvailable: Bool
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        sources: @escaping () -> [LegacySource] = { LegacySource.discover() },
        database: Database,
        dictionary: DictionaryStore,
        settings: AppSettings,
        stats: StatsTicker,
        storeAvailable: Bool,
        markerURL: URL = LegacyImportMarker.defaultURL,
        recordingsDirectory: URL = AppPaths.recordings
    ) {
        self.sources = sources
        self.database = database
        self.dictionary = dictionary
        self.settings = settings
        self.stats = stats
        self.storeAvailable = storeAvailable
        self.markerURL = markerURL
        self.recordingsDirectory = recordingsDirectory
    }

    var isBusy: Bool { phase != .idle }

    var canImport: Bool { !isBusy && !sourcesMissing && storeAvailable && scan != nil }

    /// Fraction for the progress bar while importing.
    var progress: Double? {
        guard case .importing(let processed, let total) = phase, total > 0 else { return nil }
        return Double(processed) / Double(total)
    }

    /// Called when the Settings row appears: loads the marker and runs the dry run once.
    func prepare() {
        lastImport = LegacyImportMarker.load(from: markerURL)
        guard scan == nil, phase == .idle else { return }
        rescan()
    }

    func rescan() {
        guard phase == .idle else { return }
        let found = sources()
        guard !found.isEmpty else {
            sourcesMissing = true
            return
        }
        sourcesMissing = false
        phase = .scanning
        let importer = makeImporter(found)
        task = Task { [weak self] in
            do {
                let report = try await importer.run(dryRun: true)
                self?.finishScan(report, error: nil)
            } catch {
                self?.finishScan(nil, error: error)
            }
        }
    }

    /// The real import (after the confirmation dialog).
    func startImport() {
        guard canImport else { return }
        if let blocking = LegacyImportGuard.blockingError(checkOtherCaptylo: true) {
            errorMessage = blocking.errorDescription
            return
        }
        errorMessage = nil
        result = nil
        let found = sources()
        let importer = makeImporter(found)
        let days = settings.audioRetentionDays
        let cutoff: Date? = days > 0 ? Date().addingTimeInterval(-Double(days) * 86_400) : nil
        phase = .importing(processed: 0, total: scan?.rowsFound ?? 0)
        let progress: LegacyImporter.Progress = { [weak self] processed, total in
            Task { @MainActor [weak self] in
                self?.updateProgress(processed: processed, total: total)
            }
        }
        task = Task { [weak self] in
            do {
                let report = try await importer.run(dryRun: false, audioCutoff: cutoff, progress: progress)
                self?.finishImport(report, error: nil)
            } catch {
                self?.finishImport(nil, error: error)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: Private

    private func makeImporter(_ found: [LegacySource]) -> LegacyImporter {
        let dictionary = self.dictionary
        return LegacyImporter(
            sources: found,
            database: database,
            recordingsDirectory: recordingsDirectory,
            mergeDictionary: { words, rules in
                await MainActor.run { dictionary.mergeImported(vocabulary: words, rules: rules) }
            }
        )
    }

    private func updateProgress(processed: Int, total: Int) {
        guard case .importing(let current, _) = phase, processed >= current else { return }
        phase = .importing(processed: processed, total: total)
    }

    private func finishScan(_ report: LegacyImportReport?, error: (any Error)?) {
        phase = .idle
        if let report {
            scan = report
        } else if let error {
            errorMessage = Self.message(for: error)
            sourcesMissing = (error as? LegacyImportError) == .noSources
        }
    }

    private func finishImport(_ report: LegacyImportReport?, error: (any Error)?) {
        phase = .idle
        // Rows saved before a failure or cancel are real: the dashboard and history reload either way.
        stats.bump()
        guard let report else {
            errorMessage = error.map(Self.message(for:))
            rescan()
            return
        }
        result = report
        let marker = LegacyImportMarker(importedAt: Date(), report: report)
        do {
            try marker.save(to: markerURL)
        } catch {
            Log.data.error("Could not save the legacy import marker: \(error.localizedDescription, privacy: .public)")
        }
        lastImport = marker
        rescan()
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
