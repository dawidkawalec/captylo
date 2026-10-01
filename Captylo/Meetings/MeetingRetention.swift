import Foundation
import os

/// "Zachowuj nagrania spotkań": transcripts and notes stay; only the track files go.
///
/// The last post-processor of a meeting (speaker labels need the audio and run first): with
/// "Nie zachowuj" it removes that meeting's folder at once, and with any policy it then sweeps
/// older meetings, so an app that runs for weeks keeps trimming like the dictation retention
/// does after each save. The launch sweep in `AppState.startServices` covers the rest.
struct MeetingRetention: MeetingPostProcessing {
    let database: Database
    let policy: @Sendable () async -> MeetingAudioRetention
    let folder: @Sendable (UUID) -> URL
    let now: @Sendable () -> Date

    init(
        database: Database,
        policy: @escaping @Sendable () async -> MeetingAudioRetention,
        folder: @escaping @Sendable (UUID) -> URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.policy = policy
        self.folder = folder
        self.now = now
    }

    func process(meetingID: UUID) async {
        if await policy() == .none {
            await remove([meetingID])
        }
        await sweep()
    }

    /// Removes the audio of finished meetings older than the policy allows ("Nie zachowuj":
    /// all of them, e.g. right after the user picked it, or a meeting cut short by a crash).
    /// A meeting still recording or processing is never touched: its own `process` call
    /// decides, after the speaker labels have read its track.
    func sweep() async {
        guard let days = await policy().days else { return }
        let cutoff = now().addingTimeInterval(-Double(days) * 86_400)
        let candidates: [UUID]
        do {
            candidates = try await database.meetingsWithAudio(olderThan: cutoff)
        } catch {
            Log.data.error("Meeting audio retention skipped: \(error.localizedDescription, privacy: .public)")
            return
        }
        var finished: [UUID] = []
        for id in candidates {
            guard let status = try? await database.meeting(id: id)?.status else { continue }
            if status != .recording && status != .processing {
                finished.append(id)
            }
        }
        await remove(finished)
    }

    /// Deletes the folders and marks the rows. A folder that is still there after a failed
    /// delete keeps `hasAudio`, so the recording never stays on disk where nothing points at it.
    private func remove(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        let fileManager = FileManager.default
        let gone = ids.filter { id in
            let url = folder(id)
            do {
                try fileManager.removeItem(at: url)
            } catch {
                if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                    Log.data.error("Meeting audio could not be removed: \(error.localizedDescription, privacy: .public)")
                    return false
                }
            }
            return true
        }
        guard !gone.isEmpty else { return }
        do {
            try await database.setMeetingAudioRemoved(ids: gone)
            Log.data.info("Meeting audio retention: removed the audio of \(gone.count, privacy: .public) meeting(s)")
        } catch {
            Log.data.error("Meeting audio rows could not be updated: \(error.localizedDescription, privacy: .public)")
        }
    }
}
