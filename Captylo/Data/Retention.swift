import Foundation

/// Audio retention (P1): drops WAVs older than N days and forgets them on their rows.
/// Transcripts and `UsageStat` are never touched. Run at launch and after each save.
@MainActor
enum Retention {
    /// `days` 0 = off. `now` and `recordings` are injectable for tests.
    static func run(days: Int, database: Database, now: Date = Date(), recordings: URL = AppPaths.recordings) async {
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)

        var fileNames = Set<String>()
        do {
            fileNames.formUnion(try await database.clearAudio(olderThan: cutoff))
        } catch {
            Log.data.error("Retention: clearing audio rows failed: \(error.localizedDescription, privacy: .public)")
        }

        let removed = await Task.detached(priority: .utility) {
            removeFiles(named: fileNames, plusOlderThan: cutoff, in: recordings)
        }.value
        if removed > 0 {
            Log.data.info("Retention: removed \(removed) recordings older than \(days) days")
        }
    }

    /// A WAV younger than this may belong to a take or file whose row is not saved yet.
    static let orphanMinimumAge: TimeInterval = 600

    /// Launch sweep, independent of the retention setting: deletes `Recordings/*.wav` that no row
    /// points at (a save that failed, takes from a session on the in-memory fallback store), so
    /// no private recording stays on disk where Historia cannot show or delete it. Never run it
    /// against the in-memory fallback store (it has no rows). Returns the number removed.
    @discardableResult
    static func sweepOrphans(database: Database, now: Date = Date(), recordings: URL = AppPaths.recordings) async -> Int {
        let referenced: Set<String>
        do {
            referenced = try await database.referencedAudioFileNames()
        } catch {
            Log.data.error("Orphan sweep skipped: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        let cutoff = now.addingTimeInterval(-orphanMinimumAge)
        let removed = await Task.detached(priority: .utility) {
            removeOrphans(keeping: referenced, olderThan: cutoff, in: recordings)
        }.value
        if removed > 0 {
            Log.data.info("Removed \(removed) recordings without a history row")
        }
        return removed
    }

    nonisolated static func removeOrphans(keeping referenced: Set<String>, olderThan cutoff: Date, in directory: URL) -> Int {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var removed = 0
        for entry in entries where entry.pathExtension.lowercased() == "wav" && !referenced.contains(entry.lastPathComponent) {
            guard
                let values = try? entry.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true,
                let date = values.creationDate ?? values.contentModificationDate,
                date < cutoff
            else { continue }
            do {
                try fileManager.removeItem(at: entry)
                removed += 1
            } catch {
                Log.data.error("Orphan sweep: could not remove \(entry.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return removed
    }

    /// Deletes the named files plus every other WAV whose creation date is before `cutoff`
    /// (orphans of rows deleted earlier). Returns the number of files removed.
    nonisolated static func removeFiles(named fileNames: Set<String>, plusOlderThan cutoff: Date, in directory: URL) -> Int {
        let fileManager = FileManager.default
        var targets = fileNames.map { directory.appending(path: $0) }

        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        if let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) {
            for entry in entries where entry.pathExtension.lowercased() == "wav" {
                guard
                    let values = try? entry.resourceValues(forKeys: Set(keys)),
                    values.isRegularFile == true,
                    let date = values.creationDate ?? values.contentModificationDate,
                    date < cutoff
                else { continue }
                targets.append(entry)
            }
        }

        var removed = 0
        for url in Set(targets.map(\.standardizedFileURL)) {
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                Log.data.error("Retention: could not remove \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return removed
    }
}
