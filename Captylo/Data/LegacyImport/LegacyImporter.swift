import Foundation

/// Brings the old app's history into Captylo (brief Appendix A): rows, AI versions, `UsageStat`s,
/// recordings (hard links, never copies) and the dictionary. Idempotent: ids already in Captylo
/// are skipped, so a second run adds nothing. A dry run reads and counts but writes nothing.
///
/// The caller checks that neither the old app nor another Captylo on the same store is running
/// (`LegacyImportGuard`, main actor) before `run`.
actor LegacyImporter {
    typealias DictionaryMerge = @Sendable (_ vocabulary: [String], _ rules: [ReplacementRule]) async -> (vocabulary: Int, rules: Int)
    typealias Progress = @Sendable (_ processed: Int, _ total: Int) -> Void

    static let pageSize = 1000
    static let batchSize = 500

    private let sources: [LegacySource]
    private let database: Database?
    private let recordingsDirectory: URL
    private let tempRoot: URL
    private let mergeDictionary: DictionaryMerge?

    /// - Parameters:
    ///   - database: target store; nil only for a dry run without one (then nothing counts as existing).
    ///   - recordingsDirectory: Captylo's `Recordings/` (the links land here).
    ///   - mergeDictionary: merges the old words and rules (main-actor `DictionaryStore`).
    init(
        sources: [LegacySource],
        database: Database?,
        recordingsDirectory: URL = AppPaths.recordings,
        tempRoot: URL = FileManager.default.temporaryDirectory,
        mergeDictionary: DictionaryMerge? = nil
    ) {
        self.sources = sources
        self.database = database
        self.recordingsDirectory = recordingsDirectory
        self.tempRoot = tempRoot
        self.mergeDictionary = mergeDictionary
    }

    /// - Parameter audioCutoff: recordings of rows older than this are not linked ("Usuwaj
    ///   nagrania po" would delete them right away); nil links every recording.
    func run(dryRun: Bool, audioCutoff: Date? = nil, progress: Progress? = nil) async throws -> LegacyImportReport {
        do {
            return try await perform(dryRun: dryRun, audioCutoff: audioCutoff, progress: progress)
        } catch is CancellationError {
            throw LegacyImportError.cancelled
        }
    }

    // MARK: Run

    private func perform(dryRun: Bool, audioCutoff: Date?, progress: Progress?) async throws -> LegacyImportReport {
        let clock = ContinuousClock()
        let started = clock.now
        guard !sources.isEmpty else { throw LegacyImportError.noSources }
        guard dryRun || database != nil else { throw LegacyImportError.storeUnavailable }

        var report = LegacyImportReport()
        report.dryRun = dryRun
        report.sourcesFound = sources.count

        var known = Set<UUID>()
        if let database {
            do {
                known = try await database.knownDictationIDs()
            } catch {
                throw LegacyImportError.readFailed(error.localizedDescription)
            }
        }
        if !dryRun {
            do {
                try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
            } catch {
                throw LegacyImportError.saveFailed(error.localizedDescription)
            }
        }
        report.recordingsFound = countRecordings()

        let readers = try sources.map { source in
            (source: source, reader: try LegacyStoreReader(storeURL: source.storeURL, tempRoot: tempRoot))
        }
        defer {
            for entry in readers {
                entry.reader.close()
            }
        }
        let total = try readers.reduce(0) { $0 + (try $1.reader.transcriptionCount()) }
        report.rowsFound = total
        progress?(0, total)

        var processed = 0
        var seen = Set<UUID>()
        for (source, reader) in readers {
            let audioFolders = audioSearchFolders(preferring: source)
            var lastPK = Int64.min
            var batch: [LegacyMappedRow] = []
            while true {
                try Task.checkCancellation()
                let page = try reader.transcriptions(afterPK: lastPK, limit: Self.pageSize)
                guard let last = page.last else { break }
                lastPK = last.pk
                for row in page {
                    switch LegacyMapper.map(row, sourcePath: source.storePath) {
                    case .skipPrewarm:
                        report.skippedPrewarm += 1
                    case .skipEmpty:
                        report.skippedEmpty += 1
                    case .importRow(let mapped):
                        // The same id in an earlier source: that copy wins.
                        guard seen.insert(mapped.record.id).inserted else {
                            report.skippedDuplicate += 1
                            continue
                        }
                        if mapped.createsUsageStat {
                            report.wordsFound += mapped.record.wordCount
                        }
                        guard !known.contains(mapped.record.id) else {
                            report.skippedExisting += 1
                            continue
                        }
                        batch.append(mapped)
                    }
                    if batch.count >= Self.batchSize {
                        try await commit(batch, audioFolders: audioFolders, dryRun: dryRun, audioCutoff: audioCutoff, report: &report)
                        batch.removeAll(keepingCapacity: true)
                    }
                }
                processed += page.count
                progress?(processed, total)
            }
            try await commit(batch, audioFolders: audioFolders, dryRun: dryRun, audioCutoff: audioCutoff, report: &report)
        }

        try await importDictionary(readers: readers, dryRun: dryRun, report: &report)

        let elapsed = (clock.now - started).components
        report.seconds = ((Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) * 100).rounded() / 100
        Log.data.info("Legacy import \(dryRun ? "dry run" : "run", privacy: .public): \(report.imported) new of \(report.rowsFound) rows, \(report.audioLinked) recordings linked in \(report.seconds) s")
        return report
    }

    // MARK: Batches

    /// Links the audio of one batch, then inserts it in one save. When the save fails the links
    /// made for this batch are removed again (the old files are never touched).
    private func commit(
        _ batch: [LegacyMappedRow],
        audioFolders: [URL],
        dryRun: Bool,
        audioCutoff: Date?,
        report: inout LegacyImportReport
    ) async throws {
        guard !batch.isEmpty else { return }
        try Task.checkCancellation()
        var createdLinks: [URL] = []
        var records: [DictationRecord] = []
        records.reserveCapacity(batch.count)
        var counts = report
        for mapped in batch {
            var record = mapped.record
            record.audioFileName = linkAudio(
                named: mapped.sourceAudioFileName,
                createdAt: record.createdAt,
                folders: audioFolders,
                dryRun: dryRun,
                audioCutoff: audioCutoff,
                createdLinks: &createdLinks,
                report: &counts
            )
            records.append(record)
        }
        if !dryRun, let database {
            do {
                try await database.insertImported(records)
            } catch {
                for link in createdLinks {
                    try? FileManager.default.removeItem(at: link)
                }
                throw LegacyImportError.saveFailed(error.localizedDescription)
            }
        }
        for record in records {
            counts.imported += 1
            if record.status == .failed {
                counts.failedRowsImported += 1
            } else {
                counts.usageStatsAdded += 1
                counts.totalWords += record.wordCount
            }
            if record.enhancedText != nil {
                counts.withAI += 1
            }
        }
        report = counts
    }

    // MARK: Audio

    /// The source's own recordings folder first, then the others (a row may point across).
    private func audioSearchFolders(preferring source: LegacySource) -> [URL] {
        var folders = [source.recordingsURL]
        for other in sources where !folders.contains(other.recordingsURL) {
            folders.append(other.recordingsURL)
        }
        return folders
    }

    /// Resolves the old recording and hard-links it as `Recordings/<same name>`. Returns the name
    /// to store on the row, or nil (missing, retention, other volume). Never copies: the disk is
    /// tight and a link costs nothing.
    private func linkAudio(
        named name: String?,
        createdAt: Date,
        folders: [URL],
        dryRun: Bool,
        audioCutoff: Date?,
        createdLinks: inout [URL],
        report: inout LegacyImportReport
    ) -> String? {
        guard let name else { return nil }
        let fileManager = FileManager.default
        guard let source = folders
            .map({ $0.appending(path: name) })
            .first(where: { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) })
        else {
            report.audioMissing += 1
            return nil
        }
        if let audioCutoff, createdAt < audioCutoff {
            report.audioSkippedByRetention += 1
            return nil
        }
        let target = recordingsDirectory.appending(path: name)
        if fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
            report.audioLinked += 1
            return name
        }
        if dryRun {
            if sameVolume(source.deletingLastPathComponent(), recordingsDirectory) {
                report.audioLinked += 1
                return name
            }
            report.audioNotLinkable += 1
            return nil
        }
        do {
            try fileManager.linkItem(at: source, to: target)
            createdLinks.append(target)
            report.audioLinked += 1
            return name
        } catch {
            Log.data.error("Legacy import: could not link \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            report.audioNotLinkable += 1
            return nil
        }
    }

    private var volumeCache: [URL: String] = [:]

    /// True when both folders (or their nearest existing parents) sit on the same volume.
    private func sameVolume(_ first: URL, _ second: URL) -> Bool {
        guard let a = volumeID(of: first), let b = volumeID(of: second) else { return false }
        return a == b
    }

    private func volumeID(of url: URL) -> String? {
        if let cached = volumeCache[url] { return cached }
        var current = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: current.path(percentEncoded: false)), current.pathComponents.count > 1 {
            current = current.deletingLastPathComponent()
        }
        guard let identifier = try? current.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else { return nil }
        let id = String(describing: identifier)
        volumeCache[url] = id
        return id
    }

    /// WAV files in the distinct recordings folders of the sources.
    private func countRecordings() -> Int {
        var seen = Set<URL>()
        var count = 0
        for source in sources where seen.insert(source.recordingsURL.standardizedFileURL).inserted {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: source.recordingsURL.path(percentEncoded: false))) ?? []
            count += names.lazy.filter { $0.lowercased().hasSuffix(".wav") }.count
        }
        return count
    }

    // MARK: Dictionary

    /// Words and rules, source by source (so the newer app's spelling wins): the tables in
    /// `default.store`, then its `dictionary.store`. A dictionary that cannot be read is logged
    /// and skipped: the history import still counts.
    private func importDictionary(
        readers: [(source: LegacySource, reader: LegacyStoreReader)],
        dryRun: Bool,
        report: inout LegacyImportReport
    ) async throws {
        var words: [String] = []
        var replacements: [LegacyReplacementRow] = []
        for (source, reader) in readers {
            do {
                words += try reader.vocabulary()
                replacements += try reader.replacements()
            } catch {
                Log.data.error("Legacy import: dictionary tables unreadable: \(error.localizedDescription, privacy: .public)")
            }
            guard let url = source.existingDictionaryStoreURL else { continue }
            do {
                let dictionaryReader = try LegacyStoreReader(storeURL: url, tempRoot: tempRoot)
                defer { dictionaryReader.close() }
                words += try dictionaryReader.vocabulary()
                replacements += try dictionaryReader.replacements()
            } catch {
                Log.data.error("Legacy import: \(url.lastPathComponent, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
            }
        }
        let vocabulary = LegacyMapper.vocabulary(words)
        let rules = LegacyMapper.rules(replacements)
        if dryRun {
            report.vocabularyAdded = vocabulary.count
            report.rulesAdded = rules.count
            return
        }
        guard !vocabulary.isEmpty || !rules.isEmpty, let mergeDictionary else { return }
        try Task.checkCancellation()
        let added = await mergeDictionary(vocabulary, rules)
        report.vocabularyAdded = added.vocabulary
        report.rulesAdded = added.rules
    }
}
