import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Captylo

@MainActor
struct MeetingTitleEditorTests {
    // MARK: MeetingTitleEdit

    @Test func closingHandsOverTheTypedTextOnce() {
        var edit = MeetingTitleEdit(title: "Spotkanie 1")
        edit.open(with: "Spotkanie 1")
        edit.draft = "Budżet Q4"
        #expect(edit.close() == "Budżet Q4")
        #expect(!edit.isOpen)
        // Return closed it; the field going away right after must not save again.
        #expect(edit.close() == nil)
    }

    @Test func escapeKeepsTheOldTitleAndLaterClosesSaveNothing() {
        var edit = MeetingTitleEdit(title: "Spotkanie 1")
        edit.open(with: "Spotkanie 1")
        edit.draft = "Budżet Q4"
        edit.cancel(keeping: "Spotkanie 1")
        #expect(!edit.isOpen)
        #expect(edit.draft == "Spotkanie 1")
        // The field disappears after Escape: still a cancel.
        #expect(edit.close() == nil)
    }

    @Test func aClosedFieldSavesNothing() {
        var edit = MeetingTitleEdit(title: "Spotkanie 1")
        #expect(edit.close() == nil)
        edit.cancel(keeping: "Spotkanie 1")
        #expect(!edit.isOpen)
    }

    @Test func openingStartsFromTheCurrentTitle() {
        var edit = MeetingTitleEdit(title: "Stary")
        edit.draft = "resztki"
        edit.open(with: "Nowy")
        #expect(edit.isOpen)
        #expect(edit.draft == "Nowy")
    }

    // MARK: The editor in a window

    @MainActor @Observable
    final class Host {
        var showsEditor = true
    }

    struct HostView: View {
        let host: Host
        let startsEditing: Bool
        let onSave: (String) -> Void

        var body: some View {
            if host.showsEditor {
                MeetingTitleEditor(title: "Spotkanie 1", startsEditing: startsEditing, onSave: onSave)
            } else {
                Color.clear
            }
        }
    }

    private func window(showing view: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func settle() async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    /// Another meeting picked in the list (a button that takes no focus): the open field is
    /// removed while it still has the focus and must save what it holds.
    @Test func aFieldRemovedWhileOpenSavesWhatItHolds() async throws {
        let host = Host()
        var saved: [String] = []
        let window = window(showing: HostView(host: host, startsEditing: true) { saved.append($0) })
        defer { window.close() }
        try await settle()
        #expect(saved.isEmpty)

        host.showsEditor = false
        window.contentView?.layoutSubtreeIfNeeded()
        try await settle()
        #expect(saved == ["Spotkanie 1"])
    }

    @Test func aTitleNeverOpenedSavesNothingWhenRemoved() async throws {
        let host = Host()
        var saved: [String] = []
        let window = window(showing: HostView(host: host, startsEditing: false) { saved.append($0) })
        defer { window.close() }
        try await settle()

        host.showsEditor = false
        window.contentView?.layoutSubtreeIfNeeded()
        try await settle()
        #expect(saved.isEmpty)
    }
}
