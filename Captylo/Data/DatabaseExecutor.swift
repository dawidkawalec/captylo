import Foundation
import SwiftData

/// Serial executor for `Database` backed by its own dispatch queue.
///
/// SwiftData's `DefaultSerialModelExecutor` runs each job on the thread that enqueued it, so a
/// save or dashboard fetch awaited from main-actor code ran on the main thread (measured on
/// macOS 26; macOS 14/15 also bind it to the creating thread). A dedicated queue keeps every
/// store read and write off the main thread no matter who calls (gotcha 10).
final class DatabaseExecutor: SerialModelExecutor, @unchecked Sendable {
    /// Touched only by jobs running on `queue`.
    let modelContext: ModelContext
    private let queue = DispatchQueue(label: "com.captylo.app.database", qos: .userInitiated)

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async {
            unownedJob.runSynchronously(on: executor)
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
