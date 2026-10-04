import Foundation
import Testing
@testable import Captylo

/// The recorder's policy for exact zeros on the "Rozmówcy" track, one-second buffers on a fake clock.
struct MeetingSystemTrackWatchTests {
    private static let zero = [Float](repeating: 0, count: 16_000)
    private static let voice = [Float](repeating: 0.2, count: 16_000)
    private static let t0 = Date(timeIntervalSinceReferenceDate: 10_000)

    /// Drives a watch like the recorder's sink does; `rebuilt()` stands for the recorder
    /// restarting the tap, whose buffers then come from a new session.
    private struct Driver {
        var watch = SystemTrackWatch()
        var clock = 0
        var session = 1

        @discardableResult
        mutating func push(_ samples: [Float], playing: Bool = true) -> SystemTrackWatch.Report {
            clock += 1
            let silent = !samples.contains { $0 != 0 }
            return watch.observe(samples, session: session, silent: silent, expectingAudio: silent && playing,
                                 at: t0.addingTimeInterval(Double(clock)))
        }

        @discardableResult
        mutating func zeros(_ seconds: Int, playing: Bool = true) -> [SystemTrackWatch.Report] {
            (0..<seconds).map { _ in push(zero, playing: playing) }
        }

        @discardableResult
        mutating func voice() -> SystemTrackWatch.Report { push(MeetingSystemTrackWatchTests.voice) }

        mutating func rebuilt() { session += 1 }

        /// Zeros until the watch asks for its next rebuild; returns the run seconds it took.
        mutating func zerosUntilRebuild(limit: Int = 600) -> (seconds: Int, report: SystemTrackWatch.Report)? {
            for second in 1...limit {
                let report = push(zero)
                if report.rebuild { return (second, report) }
            }
            return nil
        }
    }

    /// The user presents in turns while the other side is quiet and the call plays exact zeros:
    /// nothing happens to the tap and no gap is kept, however many 6 s watchdog ticks go by.
    @Test func quietStretchesUnderHalfAMinuteLeaveTheTapAlone() {
        var driver = Driver()
        driver.voice()
        for _ in 0..<10 {
            let reports = driver.zeros(29)
            #expect(reports.allSatisfy { !$0.needsAction })
            #expect(!driver.voice().needsAction)
        }
    }

    @Test func theFirstRebuildIsQuietAndLateAudioLeavesNoGap() {
        var driver = Driver()
        driver.voice()
        let first = driver.zerosUntilRebuild()
        #expect(first?.seconds == 30)
        #expect(first?.report == SystemTrackWatch.Report(rebuild: true))
        driver.rebuilt()
        #expect(driver.zeros(3).allSatisfy { !$0.needsAction })
        // The other side speaks 3 s into the rebuilt tap: it was only quiet.
        #expect(!driver.voice().needsAction)
    }

    /// The HAL zero-buffer bug fixed by the rebuild: the gap is kept where the zeros began.
    @Test func audioRightAfterARebuildIsAGapWhereTheZerosBegan() {
        var driver = Driver()
        driver.voice()
        _ = driver.zerosUntilRebuild()
        driver.rebuilt()
        driver.zeros(2)
        #expect(driver.voice() == SystemTrackWatch.Report(gap: Self.t0.addingTimeInterval(1)))
    }

    @Test func audioFromTheOldTapBeforeTheRebuildIsNoRecovery() {
        var driver = Driver()
        driver.voice()
        _ = driver.zerosUntilRebuild()
        #expect(!driver.voice().needsAction)
    }

    /// Review focus 3: a rebuild that brought nothing back is retried with backoff for as long as
    /// the run lasts, and the user is warned once.
    @Test func rebuildsRepeatWithBackoffAndWarnOnce() throws {
        var driver = Driver()
        driver.voice()
        var at: [Int] = []
        var warnings: [Bool?] = []
        var total = 0
        for _ in 0..<6 {
            let found = driver.zerosUntilRebuild()
            let next = try #require(found)
            total += next.seconds
            at.append(total)
            warnings.append(next.report.warning)
            #expect(next.report.gap == nil)
            driver.rebuilt()
        }
        #expect(at == [30, 60, 120, 240, 360, 480])
        #expect(warnings == [nil, true, nil, nil, nil, nil])
    }

    @Test func audioRightAfterARetryClearsTheWarningAndKeepsTheGap() {
        var driver = Driver()
        driver.voice()
        _ = driver.zerosUntilRebuild()
        driver.rebuilt()
        #expect(driver.zerosUntilRebuild()?.report.warning == true)
        driver.rebuilt()
        #expect(driver.voice() == SystemTrackWatch.Report(warning: false, gap: Self.t0.addingTimeInterval(1)))
    }

    @Test func audioLongAfterAWarningClearsItWithoutAGap() {
        var driver = Driver()
        driver.voice()
        _ = driver.zerosUntilRebuild()
        driver.rebuilt()
        _ = driver.zerosUntilRebuild()
        driver.rebuilt()
        driver.zeros(10)
        #expect(driver.voice() == SystemTrackWatch.Report(warning: false))
    }

    /// The call ended while the rebuilt taps still heard nothing: the other side may be missing
    /// from where the zeros began. The next silent run starts its schedule from scratch.
    @Test func aWarningRunThatEndsWhenNothingPlaysIsAGap() {
        var driver = Driver()
        driver.voice()
        _ = driver.zerosUntilRebuild()
        driver.rebuilt()
        _ = driver.zerosUntilRebuild()
        driver.rebuilt()
        #expect(driver.push(Self.zero, playing: false) == SystemTrackWatch.Report(warning: false, gap: Self.t0.addingTimeInterval(1)))
        #expect(driver.zeros(29).allSatisfy { !$0.needsAction })
        #expect(driver.zeros(1).first?.rebuild == true)
    }

    @Test func aQuietRunThatEndsWhenNothingPlaysIsNoGap() {
        var driver = Driver()
        driver.voice()
        _ = driver.zerosUntilRebuild()
        driver.rebuilt()
        #expect(!driver.push(Self.zero, playing: false).needsAction)
        #expect(driver.watch.finish() == nil)
    }

    @Test func aMeetingThatStopsWhileWarningKeepsTheGapOnce() {
        var driver = Driver()
        driver.voice()
        _ = driver.zerosUntilRebuild()
        #expect(driver.watch.finish() == nil)
        driver.rebuilt()
        _ = driver.zerosUntilRebuild()
        #expect(driver.watch.finish() == Self.t0.addingTimeInterval(1))
        #expect(driver.watch.finish() == nil)
    }

    /// The tap is gone after a failed rebuild: the gap is kept at once and never twice.
    @Test func aFailedRebuildKeepsTheGapOnce() {
        var driver = Driver()
        #expect(driver.watch.rebuildFailed() == nil)
        driver.voice()
        driver.zeros(12)
        #expect(driver.watch.rebuildFailed() == nil)
        _ = driver.zerosUntilRebuild()
        driver.rebuilt()
        _ = driver.zerosUntilRebuild()
        #expect(driver.watch.rebuildFailed() == Self.t0.addingTimeInterval(1))
        #expect(driver.watch.rebuildFailed() == nil)
        #expect(driver.watch.finish() == nil)
    }

    @Test func noAccessAndFirstAudioComeFromTheWatchdog() {
        var driver = Driver()
        let reports = driver.zeros(64)
        #expect(reports.map(\.noAccess) == Array(repeating: false, count: 29) + [true] + Array(repeating: false, count: 34))
        #expect(!reports.contains { $0.warning != nil || $0.gap != nil })
        #expect(driver.voice() == SystemTrackWatch.Report(firstAudio: true))
        #expect(!driver.voice().needsAction)
    }

    /// A tap made before the grant can stay on zeros after "Allow": before any audio the tap is
    /// rebuilt after 8 s of zeros while something plays, then after 12, 20, 40 and every 120 s.
    @Test func zerosBeforeAnyAudioRebuildTheTapWithBackoff() {
        var driver = Driver()
        let reports = driver.zeros(400)
        let seconds = reports.enumerated().filter { $0.element.rebuild }.map { $0.offset + 1 }
        #expect(seconds == [8, 20, 40, 80, 200, 320])
        #expect(!reports.contains { $0.warning != nil || $0.gap != nil })
    }

    /// Zeros while nothing plays start the count again, and audio ends the pre-audio rebuilds.
    @Test func preAudioRebuildsRestartWhenNothingPlaysAndStopWithAudio() {
        var driver = Driver()
        driver.zeros(7)
        driver.zeros(1, playing: false)
        #expect(!driver.zeros(7).contains { $0.rebuild })
        #expect(driver.zeros(1).first?.rebuild == true)
        driver.voice()
        #expect(!driver.zeros(29).contains { $0.rebuild })
    }

    @Test func zerosWhileNothingPlaysNeverRebuild() {
        var driver = Driver()
        driver.voice()
        #expect(driver.zeros(300, playing: false).allSatisfy { !$0.needsAction })
    }

    @Test func emptyBuffersChangeNothing() {
        var driver = Driver()
        driver.voice()
        driver.zeros(29)
        for _ in 0..<10 { #expect(!driver.push([]).needsAction) }
        #expect(driver.zeros(1).first?.rebuild == true)
    }
}
