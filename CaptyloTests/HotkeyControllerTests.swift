import AppKit
import Foundation
import Testing
@testable import Captylo

// MARK: - Fakes

@MainActor
final class FakeClock {
    var now: TimeInterval = 100

    func advance(_ seconds: TimeInterval) {
        now += seconds
    }
}

@MainActor
final class FakeRecorderCoordinator: RecorderCoordinator {
    enum Call: Equatable {
        case start, stop, cancel, togglePause
    }

    var phase: DictationPhase = .idle
    var isWidgetVisible = false
    var calls: [Call] = []

    func start() async {
        calls.append(.start)
        phase = .recording
        isWidgetVisible = true
    }

    func stop() async {
        calls.append(.stop)
        phase = .idle
        isWidgetVisible = false
    }

    func cancel() async {
        calls.append(.cancel)
        phase = .idle
        isWidgetVisible = false
    }

    func togglePause() {
        calls.append(.togglePause)
    }
}

/// A coordinator whose `stop()` stays in `.transcribing` until `cancel()` or `releaseStop()`.
@MainActor
final class SlowStopCoordinator: RecorderCoordinator {
    var phase: DictationPhase = .idle
    var isWidgetVisible = false
    var calls: [FakeRecorderCoordinator.Call] = []
    private(set) var stopFinished = false
    /// True when `cancel()` ran while `stop()` was still suspended.
    private(set) var cancelledWhileStopping = false
    private var pendingStop: CheckedContinuation<Void, Never>?

    func start() async {
        calls.append(.start)
        phase = .recording
        isWidgetVisible = true
    }

    func stop() async {
        calls.append(.stop)
        phase = .transcribing
        await withCheckedContinuation { pendingStop = $0 }
        stopFinished = true
        phase = .idle
        isWidgetVisible = false
    }

    func cancel() async {
        calls.append(.cancel)
        cancelledWhileStopping = pendingStop != nil
        phase = .idle
        isWidgetVisible = false
        releaseStop()
    }

    func togglePause() {
        calls.append(.togglePause)
    }

    func releaseStop() {
        pendingStop?.resume()
        pendingStop = nil
    }
}

@MainActor
final class FakeToasts: ToastPresenting {
    var infos: [String] = []
    var errors: [String] = []

    func showInfo(_ message: String) { infos.append(message) }
    func showError(_ message: String) { errors.append(message) }
    func showAction(message: String, buttonTitle: String, action: @escaping @MainActor () -> Void) {
        infos.append(message)
    }
}

@MainActor
struct HotkeyControllerHarness {
    let clock = FakeClock()
    let coordinator = FakeRecorderCoordinator()
    let toasts = FakeToasts()
    let tap = HotkeyTap(onEvent: { _ in })
    let controller: HotkeyController

    init() {
        let clock = self.clock
        controller = HotkeyController(
            tap: tap,
            coordinator: coordinator,
            toasts: toasts,
            clock: { clock.now }
        )
    }

    /// Sends the event stamped with the fake clock and lets the queued coordinator calls run.
    func send(_ event: HotkeyEvent) async {
        controller.handle(event)
        await controller.awaitPendingOperations()
    }

    func down() async { await send(.down(at: clock.now)) }
    func up() async { await send(.up(at: clock.now)) }
}

// MARK: - Controller

@MainActor
struct HotkeyControllerTests {
    @Test func tapLatchesAndSecondTapStops() async {
        let h = HotkeyControllerHarness()
        await h.down()
        #expect(h.coordinator.calls == [.start])
        #expect(h.controller.isPushToTalkActive)

        h.clock.advance(0.2)
        await h.up()
        #expect(h.coordinator.calls == [.start], "a short tap latches: no stop on release")
        #expect(!h.controller.isPushToTalkActive)
        #expect(h.coordinator.phase == .recording)

        h.clock.advance(2)
        await h.down()
        #expect(h.coordinator.calls == [.start, .stop])
        #expect(!h.controller.isPushToTalkActive)
        h.clock.advance(0.1)
        await h.up()
        #expect(h.coordinator.calls == [.start, .stop], "the release of a stopping press does nothing")
    }

    @Test func holdIsPushToTalk() async {
        let h = HotkeyControllerHarness()
        await h.down()
        h.clock.advance(0.5)
        await h.up()
        #expect(h.coordinator.calls == [.start, .stop])
        #expect(h.coordinator.phase == .idle)
    }

    @Test func holdJustBelowThresholdLatches() async {
        let h = HotkeyControllerHarness()
        await h.down()
        h.clock.advance(0.49)
        await h.up()
        #expect(h.coordinator.calls == [.start])
    }

    @Test func cooldownDropsASecondDown() async {
        let h = HotkeyControllerHarness()
        await h.down()
        h.clock.advance(0.1)
        await h.up()
        h.clock.advance(0.1)
        await h.down()
        #expect(h.coordinator.calls == [.start], "a down 0.2 s after the previous one is dropped")
        h.clock.advance(0.1)
        await h.up()

        h.clock.advance(0.3)
        await h.down()
        #expect(h.coordinator.calls == [.start, .stop])
    }

    @Test func duplicateDownWhilePressedIsIgnored() async {
        let h = HotkeyControllerHarness()
        await h.down()
        h.clock.advance(1)
        await h.down()
        #expect(h.coordinator.calls == [.start])
    }

    @Test func interruptionCancelsOnlyThePressThatStartedRecording() async {
        let h = HotkeyControllerHarness()
        await h.down()
        h.clock.advance(0.3)
        await h.send(.interrupted)
        #expect(h.coordinator.calls == [.start, .cancel])
        #expect(h.toasts.infos.isEmpty, "the accidental-start cancel is silent")
        #expect(!h.controller.isPushToTalkActive)

        h.clock.advance(0.5)
        await h.up()
        #expect(h.coordinator.calls == [.start, .cancel], "the release after a cancel does not stop")

        // Latch a recording, then press again to stop it: an interruption must not cancel.
        h.clock.advance(1)
        await h.down()
        h.clock.advance(0.1)
        await h.up()
        #expect(h.coordinator.phase == .recording)
        h.clock.advance(1)
        await h.down()
        #expect(h.coordinator.calls == [.start, .cancel, .start, .stop])
        h.clock.advance(0.2)
        await h.send(.interrupted)
        #expect(h.coordinator.calls == [.start, .cancel, .start, .stop])
    }

    @Test func interruptionOutsideTheWindowIsIgnored() async {
        let h = HotkeyControllerHarness()
        await h.down()
        h.clock.advance(1.2)
        await h.send(.interrupted)
        #expect(h.coordinator.calls == [.start])
    }

    @Test func interruptionArrivingBeforeItsDownSwallowsThatDown() async {
        let h = HotkeyControllerHarness()
        await h.send(.interrupted)
        await h.down()
        #expect(h.coordinator.calls.isEmpty)
        h.clock.advance(0.1)
        await h.up()

        h.clock.advance(1)
        await h.down()
        #expect(h.coordinator.calls == [.start], "the next real press starts normally")
    }

    @Test func escapeOnceShowsToastOnly() async {
        let h = HotkeyControllerHarness()
        await h.down()
        h.clock.advance(0.1)
        await h.up()
        await h.send(.escape)
        #expect(h.toasts.infos == ["Naciśnij Esc ponownie, aby anulować"])
        #expect(h.coordinator.calls == [.start])
    }

    @Test func escapeTwiceWithinWindowCancels() async {
        let h = HotkeyControllerHarness()
        await h.down()
        h.clock.advance(0.1)
        await h.up()
        await h.send(.escape)
        h.clock.advance(1.4)
        await h.send(.escape)
        #expect(h.coordinator.calls == [.start, .cancel])
        #expect(h.toasts.infos.count == 1)
    }

    @Test func escapeTwiceTooFarApartDoesNotCancel() async {
        let h = HotkeyControllerHarness()
        await h.down()
        h.clock.advance(0.1)
        await h.up()
        await h.send(.escape)
        h.clock.advance(2)
        await h.send(.escape)
        #expect(h.coordinator.calls == [.start])
        #expect(h.toasts.infos.count == 2, "the second Esc starts a new window and shows the hint again")
    }

    @Test func escapeWhileHoldingCancelsAndReleaseDoesNotStop() async {
        let h = HotkeyControllerHarness()
        await h.down()
        h.clock.advance(1)
        await h.send(.escape)
        h.clock.advance(0.2)
        await h.send(.escape)
        #expect(h.coordinator.calls == [.start, .cancel])
        h.clock.advance(0.2)
        await h.up()
        #expect(h.coordinator.calls == [.start, .cancel], "stop is skipped because nothing is capturing")
    }

    @Test func hotkeyIgnoredWhileTranscribing() async {
        let h = HotkeyControllerHarness()
        h.coordinator.phase = .transcribing
        await h.down()
        h.clock.advance(1)
        await h.up()
        #expect(h.coordinator.calls.isEmpty)

        h.coordinator.phase = .enhancing
        h.clock.advance(1)
        await h.down()
        #expect(h.coordinator.calls.isEmpty)
        #expect(!h.controller.isPushToTalkActive)
    }

    @Test func downWhilePausedStopsTheRecording() async {
        let h = HotkeyControllerHarness()
        h.coordinator.phase = .paused
        await h.down()
        #expect(h.coordinator.calls == [.stop])
    }

    @Test func escapeTwiceCancelsAStopStillInFlight() async {
        let coordinator = SlowStopCoordinator()
        let clock = FakeClock()
        let controller = HotkeyController(
            tap: HotkeyTap(onEvent: { _ in }),
            coordinator: coordinator,
            toasts: FakeToasts(),
            clock: { clock.now }
        )
        controller.handle(.down(at: clock.now))
        await controller.awaitPendingOperations()
        clock.advance(0.7)
        controller.handle(.up(at: clock.now))
        await waitUntil { coordinator.calls.contains(.stop) }
        #expect(coordinator.phase == .transcribing)

        controller.handle(.escape)
        clock.advance(0.3)
        controller.handle(.escape)
        await waitUntil { coordinator.calls.contains(.cancel) }
        coordinator.releaseStop()
        await controller.awaitPendingOperations()
        #expect(coordinator.calls == [.start, .stop, .cancel])
        #expect(coordinator.cancelledWhileStopping, "the second Esc must reach cancel() before the running stop() returns")
    }

    /// Polls a main-actor condition for up to 2 s (parallel test runs can delay queued tasks).
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func coordinatorCallsRunInOrder() async {
        let h = HotkeyControllerHarness()
        // No awaits between the events: the queue must still start before it stops.
        h.controller.handle(.down(at: h.clock.now))
        h.controller.handle(.up(at: h.clock.now + 0.7))
        await h.controller.awaitPendingOperations()
        #expect(h.coordinator.calls == [.start, .stop])
    }
}

// MARK: - Capture session

struct HotkeyControllerCaptureSessionTests {
    @Test func comboFinishesOnKeyDown() {
        var session = HotkeyCaptureSession()
        #expect(session.flagsChanged(keyCode: KeyCode.leftControl, flags: [.control]) == .pending(preview: Hotkey(kind: .modifierOnly, keyCode: KeyCode.leftControl, modifiers: NSEvent.ModifierFlags.control.rawValue)))
        let outcome = session.keyDown(keyCode: KeyCode.space, flags: [.control, .option])
        #expect(outcome == .captured(Hotkey(kind: .key, keyCode: KeyCode.space, flags: [.control, .option])))
    }

    @Test func modifierOnlyFinishesOnFullReleaseWithPeakFlags() {
        var session = HotkeyCaptureSession()
        _ = session.flagsChanged(keyCode: KeyCode.leftControl, flags: [.control])
        _ = session.flagsChanged(keyCode: KeyCode.leftOption, flags: [.control, .option])
        _ = session.flagsChanged(keyCode: KeyCode.leftOption, flags: [.control])
        let outcome = session.flagsChanged(keyCode: KeyCode.leftControl, flags: [])
        #expect(outcome == .captured(Hotkey(kind: .modifierOnly, keyCode: KeyCode.generic, flags: [.control, .option])))
    }

    @Test func singleModifierKeepsItsSide() {
        var session = HotkeyCaptureSession()
        #expect(session.flagsChanged(keyCode: KeyCode.rightOption, flags: [.option]) == .pending(preview: .rightOption))
        #expect(session.flagsChanged(keyCode: KeyCode.rightOption, flags: []) == .captured(.rightOption))
        #expect(session.flagsChanged(keyCode: KeyCode.fn, flags: [.function]) == .pending(preview: .fn))
        #expect(session.flagsChanged(keyCode: KeyCode.fn, flags: []) == .captured(.fn))
    }

    @Test func escapeCancelsAndModifiedEscapeIsACombo() {
        var session = HotkeyCaptureSession()
        #expect(session.keyDown(keyCode: KeyCode.escape, flags: []) == .cancelled)
        #expect(session.keyDown(keyCode: KeyCode.escape, flags: [.option, .command]) == .captured(Hotkey(kind: .key, keyCode: KeyCode.escape, flags: [.option, .command])))
    }

    @Test func releaseWithoutAChordStaysPending() {
        var session = HotkeyCaptureSession()
        #expect(session.flagsChanged(keyCode: KeyCode.capsLock, flags: [.capsLock]) == .pending(preview: nil))
        #expect(session.flagsChanged(keyCode: KeyCode.capsLock, flags: []) == .pending(preview: nil))
    }
}

@MainActor
struct HotkeyCaptureModelTests {
    @Test func captureCancelsWhenTheAppResignsActive() {
        let model = HotkeyCaptureModel()
        var results: [HotkeyCaptureModel.Result] = []
        model.begin { results.append($0) }
        #expect(model.isCapturing)

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)

        #expect(results == [.cancelled])
        #expect(!model.isCapturing)

        // Observers are gone after the capture ended.
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(results == [.cancelled])
    }
}
