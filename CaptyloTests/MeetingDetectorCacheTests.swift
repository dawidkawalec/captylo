import Foundation
import Testing
@testable import Captylo

struct MeetingDetectorCacheTests {
    @Test func bothTracksShareOneLoad() async throws {
        let loader = CountingDetectorLoader()
        let cache = SpeechDetectorCache { try await loader.load() }
        async let me = cache.detector()
        async let them = cache.detector()
        _ = try await (me, them)
        _ = try await cache.detector()
        #expect(await loader.loads == 1)
    }

    @Test func aFailedLoadIsTriedAgainOnTheNextCall() async throws {
        let loader = CountingDetectorLoader(failures: 1)
        let cache = SpeechDetectorCache { try await loader.load() }
        await #expect(throws: ScriptedFailure.self) { try await cache.detector() }
        _ = try await cache.detector()
        _ = try await cache.detector()
        #expect(await loader.loads == 2)
    }
}
