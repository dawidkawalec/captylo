import AppKit
import Foundation
import Testing
@testable import Captylo

/// Output module tests on private named pasteboards, so they never touch the user's clipboard.
/// `KeySynth.pasteCommand()` itself is not unit-tested: it needs Accessibility trust and posts
/// real Cmd+V events into whatever app has focus. `TextOutput` takes the paste as an injected
/// closure, so the delivery flow is tested end to end with a fake outcome instead.
@MainActor
struct OutputTests {
    private static let typeA = NSPasteboard.PasteboardType("com.captylo.app.tests.typeA")
    private static let typeB = NSPasteboard.PasteboardType("com.captylo.app.tests.typeB")

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.captylo.app.tests.\(UUID().uuidString)"))
    }

    /// One string item plus a second item carrying two custom types.
    private func fillWithTwoItems(_ pasteboard: NSPasteboard) -> (dataA: Data, dataB: Data) {
        let dataA = Data("alpha".utf8)
        let dataB = Data([0x00, 0xFF, 0x10, 0x20])
        pasteboard.clearContents()
        let first = NSPasteboardItem()
        first.setString("pierwszy element", forType: .string)
        let second = NSPasteboardItem()
        second.setData(dataA, forType: Self.typeA)
        second.setData(dataB, forType: Self.typeB)
        #expect(pasteboard.writeObjects([first, second]))
        return (dataA, dataB)
    }

    // MARK: - PasteboardSnapshot

    @Test func snapshotRoundTripRestoresEveryItemAndType() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let (dataA, dataB) = fillWithTwoItems(pasteboard)

        let snapshot = PasteboardSnapshot(capturing: pasteboard)
        #expect(snapshot.items.count == 2)
        #expect(!snapshot.isEmpty)

        pasteboard.clearContents()
        pasteboard.setString("coś innego", forType: .string)
        #expect(pasteboard.pasteboardItems?.count == 1)

        snapshot.restore(to: pasteboard)

        let items = pasteboard.pasteboardItems ?? []
        #expect(items.count == 2)
        #expect(items.first?.string(forType: .string) == "pierwszy element")
        #expect(items.last?.data(forType: Self.typeA) == dataA)
        #expect(items.last?.data(forType: Self.typeB) == dataB)
        #expect(Set(items.last?.types ?? []) == [Self.typeA, Self.typeB])

        // Capturing again yields the same snapshot.
        #expect(PasteboardSnapshot(capturing: pasteboard) == snapshot)
    }

    @Test func emptySnapshotRestoreClearsThePasteboard() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        let snapshot = PasteboardSnapshot(capturing: pasteboard)
        #expect(snapshot.isEmpty)

        pasteboard.setString("tymczasowy", forType: .string)
        snapshot.restore(to: pasteboard)
        #expect((pasteboard.pasteboardItems ?? []).isEmpty)
    }

    // MARK: - Pure helpers

    @Test func prepareTrimsAndAppendsTheTrailingSpace() {
        #expect(TextOutput.prepare("  Cześć świecie \n", trailingSpace: true) == "Cześć świecie ")
        #expect(TextOutput.prepare("  Cześć świecie \n", trailingSpace: false) == "Cześć świecie")
        #expect(TextOutput.prepare("\n\n", trailingSpace: true) == " ")
        #expect(TextOutput.prepare("", trailingSpace: false) == "")
        // Inner newlines (paragraphs) survive.
        #expect(TextOutput.prepare("a\n\nb", trailingSpace: false) == "a\n\nb")
    }

    @Test func shouldRestoreOnlyWhenTheChangeCountIsUnchanged() {
        #expect(TextOutput.shouldRestore(current: 7, remembered: 7))
        #expect(!TextOutput.shouldRestore(current: 8, remembered: 7))
        #expect(!TextOutput.shouldRestore(current: 6, remembered: 7))
    }

    @Test func restoreDelayNeverDropsBelowTheMinimum() {
        #expect(TextOutput.effectiveRestoreDelay(.zero) == TextOutput.minimumRestoreDelay)
        #expect(TextOutput.effectiveRestoreDelay(.milliseconds(100)) == .milliseconds(250))
        #expect(TextOutput.effectiveRestoreDelay(.seconds(2)) == .seconds(2))
    }

    // MARK: - deliver(): success path

    @Test func deliverPastesWithTransientMarkersAndRestoresTheClipboard() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let (dataA, dataB) = fillWithTwoItems(pasteboard)

        var pasteCalls = 0
        let output = TextOutput(pasteboard: pasteboard) {
            pasteCalls += 1
            return true
        }
        let settings = OutputSettings(restoreClipboard: true, restoreDelay: .milliseconds(300), trailingSpace: true)

        let result = await output.deliver("  Dzień dobry ", settings)
        #expect(result == .pasted)
        #expect(pasteCalls == 1)

        // Right after the paste: our text with the etiquette markers.
        #expect(pasteboard.string(forType: .string) == "Dzień dobry ")
        #expect(pasteboard.string(forType: TextOutput.sourceType) == Bundle.main.bundleIdentifier)
        #expect(pasteboard.data(forType: TextOutput.transientType) != nil)
        #expect(pasteboard.data(forType: TextOutput.autoGeneratedType) != nil)

        try await Task.sleep(for: .milliseconds(700))

        // After the delay: the original two items are back.
        let items = pasteboard.pasteboardItems ?? []
        #expect(items.count == 2)
        #expect(items.first?.string(forType: .string) == "pierwszy element")
        #expect(items.last?.data(forType: Self.typeA) == dataA)
        #expect(items.last?.data(forType: Self.typeB) == dataB)
        #expect(pasteboard.data(forType: TextOutput.transientType) == nil)
    }

    @Test func flushPendingRestoreRestoresImmediatelyAndOnlyOnce() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        _ = fillWithTwoItems(pasteboard)

        let output = TextOutput(pasteboard: pasteboard) { true }
        let settings = OutputSettings(restoreClipboard: true, restoreDelay: .seconds(2), trailingSpace: false)
        #expect(await output.deliver("tekst", settings) == .pasted)
        #expect(pasteboard.string(forType: .string) == "tekst")

        output.flushPendingRestore()
        #expect(pasteboard.pasteboardItems?.count == 2)
        #expect(pasteboard.string(forType: .string) == "pierwszy element")

        // The cancelled timer must not restore again over a later user copy.
        pasteboard.clearContents()
        pasteboard.setString("później", forType: .string)
        output.flushPendingRestore()
        #expect(pasteboard.string(forType: .string) == "później")
    }

    @Test func flushPendingRestoreSkipsWhenTheUserCopiedSomethingElse() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        _ = fillWithTwoItems(pasteboard)

        let output = TextOutput(pasteboard: pasteboard) { true }
        let settings = OutputSettings(restoreClipboard: true, restoreDelay: .seconds(2), trailingSpace: false)
        #expect(await output.deliver("tekst", settings) == .pasted)
        pasteboard.clearContents()
        pasteboard.setString("nowa kopia", forType: .string)

        output.flushPendingRestore()
        #expect(pasteboard.string(forType: .string) == "nowa kopia")
    }

    @Test func deliverSkipsTheRestoreWhenTheUserCopiedSomethingElse() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        _ = fillWithTwoItems(pasteboard)

        let output = TextOutput(pasteboard: pasteboard) { true }
        let settings = OutputSettings(restoreClipboard: true, restoreDelay: .milliseconds(300), trailingSpace: false)

        let result = await output.deliver("tekst", settings)
        #expect(result == .pasted)

        // The user copies something new before the restore fires: changeCount moves.
        pasteboard.clearContents()
        pasteboard.setString("nowa kopia użytkownika", forType: .string)

        try await Task.sleep(for: .milliseconds(700))

        #expect(pasteboard.string(forType: .string) == "nowa kopia użytkownika")
        #expect(pasteboard.pasteboardItems?.count == 1)
    }

    @Test func deliverWithoutRestoreWritesANormalCopy() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        _ = fillWithTwoItems(pasteboard)

        let output = TextOutput(pasteboard: pasteboard) { true }
        let settings = OutputSettings(restoreClipboard: false, restoreDelay: .milliseconds(300), trailingSpace: false)

        let result = await output.deliver("zostaje w schowku", settings)
        #expect(result == .pasted)
        #expect(pasteboard.string(forType: .string) == "zostaje w schowku")
        #expect(pasteboard.string(forType: TextOutput.sourceType) == Bundle.main.bundleIdentifier)
        #expect(pasteboard.data(forType: TextOutput.transientType) == nil)
        #expect(pasteboard.data(forType: TextOutput.autoGeneratedType) == nil)

        try await Task.sleep(for: .milliseconds(700))
        #expect(pasteboard.string(forType: .string) == "zostaje w schowku")
    }

    // MARK: - deliver(): failure path

    @Test func deliverFailureLeavesTheTextAsANormalCopyAndNeverRestores() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        _ = fillWithTwoItems(pasteboard)

        let output = TextOutput(pasteboard: pasteboard) { false }
        let settings = OutputSettings(restoreClipboard: true, restoreDelay: .milliseconds(300), trailingSpace: true)

        let result = await output.deliver("bez uprawnień", settings)
        #expect(result == .copiedOnly(reason: "Brak uprawnienia Dostępność"))

        #expect(pasteboard.string(forType: .string) == "bez uprawnień ")
        #expect(pasteboard.string(forType: TextOutput.sourceType) == Bundle.main.bundleIdentifier)
        // Rewritten without the transient markers so clipboard managers keep it.
        #expect(pasteboard.data(forType: TextOutput.transientType) == nil)
        #expect(pasteboard.data(forType: TextOutput.autoGeneratedType) == nil)

        try await Task.sleep(for: .milliseconds(700))
        #expect(pasteboard.string(forType: .string) == "bez uprawnień ")
        #expect(pasteboard.pasteboardItems?.count == 1)
    }

    // MARK: - copy()

    @Test func copyWritesAPlainNonTransientString() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let output = TextOutput(pasteboard: pasteboard) { true }
        output.copy("z historii")

        #expect(pasteboard.string(forType: .string) == "z historii")
        #expect(pasteboard.string(forType: TextOutput.sourceType) == Bundle.main.bundleIdentifier)
        #expect(pasteboard.data(forType: TextOutput.transientType) == nil)
        #expect(pasteboard.data(forType: TextOutput.autoGeneratedType) == nil)
    }

    @Test func secondDeliveryKeepsTheUsersOriginalClipboardForTheRestore() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        _ = fillWithTwoItems(pasteboard)

        let output = TextOutput(pasteboard: pasteboard) { true }
        let settings = OutputSettings(restoreClipboard: true, restoreDelay: .milliseconds(300), trailingSpace: false)

        _ = await output.deliver("pierwsze", settings)
        // Second dictation before the first restore fires.
        _ = await output.deliver("drugie", settings)
        #expect(pasteboard.string(forType: .string) == "drugie")

        try await Task.sleep(for: .milliseconds(700))

        // The restore brings back the user's items, not our first transcript.
        let items = pasteboard.pasteboardItems ?? []
        #expect(items.count == 2)
        #expect(items.first?.string(forType: .string) == "pierwszy element")
    }
}
