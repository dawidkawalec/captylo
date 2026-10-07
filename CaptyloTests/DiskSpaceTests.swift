import Foundation
import Testing
@testable import Captylo

struct DiskSpaceTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func warnsOnlyBelowTheThreshold() {
        #expect(DiskSpace.shouldWarn(available: 500_000_000, lastWarning: nil, now: now))
        #expect(!DiskSpace.shouldWarn(available: 5_000_000_000, lastWarning: nil, now: now))
        #expect(!DiskSpace.shouldWarn(available: DiskSpace.lowBytes, lastWarning: nil, now: now))
        #expect(!DiskSpace.shouldWarn(available: nil, lastWarning: nil, now: now), "unknown space never warns")
    }

    @Test func repeatsAtMostEveryInterval() {
        let low: Int64 = 100_000_000
        #expect(!DiskSpace.shouldWarn(available: low, lastWarning: now.addingTimeInterval(-60), now: now))
        #expect(DiskSpace.shouldWarn(available: low, lastWarning: now.addingTimeInterval(-DiskSpace.warningInterval), now: now))
    }

    @Test func readsTheDataVolume() {
        let bytes = DiskSpace.availableBytes(at: FileManager.default.temporaryDirectory)
        #expect((bytes ?? 0) > 0)
    }
}
