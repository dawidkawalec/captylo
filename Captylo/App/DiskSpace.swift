import Foundation

/// Free space on the data volume. A full disk makes recordings, the model's Neural Engine compile
/// and even the system log fail without a word, so dictation warns before it records.
enum DiskSpace {
    /// Below this the warning shows: a take is a few MB, but the model's compile writes about 2 GB.
    static let lowBytes: Int64 = 1_000_000_000
    /// The warning repeats at most this often.
    static let warningInterval: TimeInterval = 10 * 60

    /// Bytes available for important data on the volume of `url`, nil when macOS does not say.
    static func availableBytes(at url: URL = AppPaths.dataDirectory) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Whether to warn now: the space is low and the last warning is older than `warningInterval`.
    static func shouldWarn(available: Int64?, lastWarning: Date?, now: Date) -> Bool {
        guard let available, available < lowBytes else { return false }
        guard let lastWarning else { return true }
        return now.timeIntervalSince(lastWarning) >= warningInterval
    }
}
