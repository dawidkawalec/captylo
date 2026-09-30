import Foundation
import Testing
@testable import Captylo

/// The crash marker and the meeting suppression are covered: muting a real output device is
/// hardware (a suppression test would only reach it if the suppression were broken, and then
/// restores it).
@MainActor
struct AudioSystemMuteTests {
    private static func makeMute() throws -> (SystemMute, UserDefaults, String) {
        let suite = "com.captylo.app.tests.mute.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (SystemMute(settings: AppSettings(defaults: defaults), defaults: defaults), defaults, suite)
    }

    @Test func markerRoundTripsAndClears() throws {
        let (mute, defaults, suite) = try Self.makeMute()
        defer { defaults.removePersistentDomain(forName: suite) }
        let date = Date(timeIntervalSince1970: 1_000_000)

        #expect(mute.marker == nil)
        mute.recordMarker(uid: "BuiltInSpeakerDevice", at: date)
        #expect(mute.marker == SystemMute.Marker(uid: "BuiltInSpeakerDevice", mutedAt: date))

        mute.clearMarker()
        #expect(mute.marker == nil)
    }

    @Test func restoreWithoutOurMuteLeavesNoMarkerBehind() throws {
        let (mute, defaults, suite) = try Self.makeMute()
        defer { defaults.removePersistentDomain(forName: suite) }
        mute.restore()
        #expect(mute.marker == nil)
    }

    @Test func recoveryHonorsTheMarkerAge() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let recent = SystemMute.Marker(uid: "spk", mutedAt: now.addingTimeInterval(-600))
        let stale = SystemMute.Marker(uid: "spk", mutedAt: now.addingTimeInterval(-SystemMute.markerMaxAge - 1))
        let future = SystemMute.Marker(uid: "spk", mutedAt: now.addingTimeInterval(3600))

        #expect(SystemMute.uidToRecover(from: recent, now: now) == "spk")
        #expect(SystemMute.uidToRecover(from: stale, now: now) == nil)
        #expect(SystemMute.uidToRecover(from: future, now: now) == nil)
        #expect(SystemMute.uidToRecover(from: nil, now: now) == nil)
    }

    @Test func aSuppressedMuteNeverFires() async throws {
        let (mute, defaults, suite) = try Self.makeMute()
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { mute.restore() }
        AppSettings(defaults: defaults).muteWhileRecording = true
        mute.isSuppressed = true
        mute.muteIfEnabled(after: .milliseconds(5))
        try await Task.sleep(for: .milliseconds(60))
        #expect(!mute.isMutedByUs)
        #expect(mute.marker == nil)
    }

    /// A take scheduled its mute, then a meeting started before the delay ran out.
    @Test func suppressionCancelsAMuteAlreadyScheduled() async throws {
        let (mute, defaults, suite) = try Self.makeMute()
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { mute.restore() }
        AppSettings(defaults: defaults).muteWhileRecording = true
        mute.muteIfEnabled(after: .milliseconds(40))
        mute.isSuppressed = true
        try await Task.sleep(for: .milliseconds(100))
        #expect(!mute.isMutedByUs)
        #expect(mute.marker == nil)
    }

    @Test func recoveryConsumesTheMarker() throws {
        let (mute, defaults, suite) = try Self.makeMute()
        defer { defaults.removePersistentDomain(forName: suite) }
        // A UID no device has: nothing is touched, but the marker is gone afterwards.
        mute.recordMarker(uid: "captylo-test-no-such-device-\(UUID().uuidString)")
        mute.recoverAfterAbnormalExit()
        #expect(mute.marker == nil)
    }
}
