import AppKit
import SwiftUI

/// One entry of a widget row menu.
struct RecorderMenuItem: Identifiable {
    let id: String
    let title: String
    /// SF Symbol drawn before the title (the AI modes).
    var systemImage: String?
    var isChecked = false
    /// Draws a separator above the item.
    var startsGroup = false
    let action: @MainActor () -> Void
}

/// Trailing value of a widget row that opens a menu ("MacBook Pro (Wbudowany) ⌄"). Looks like
/// `GlassRowValue`, but pops a plain `NSMenu` from a button: the widget panel is never key and
/// the app is usually inactive, and a SwiftUI `Menu` there can swallow the first click, while a
/// button always gets it (`RecorderHostingView.acceptsFirstMouse`). `isMenuOpen` keeps the
/// widget expanded while the menu is up (the pointer is over the menu, outside the panel).
@MainActor
struct RecorderMenuValue: View {
    let value: String
    let label: Text
    @Binding var isMenuOpen: Bool
    let items: () -> [RecorderMenuItem]

    var body: some View {
        Button(action: present) {
            GlassRowValue(value, chevron: .down)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(Text(verbatim: value))
        .accessibilityAddTraits(.isButton)
    }

    private func present() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.appearance = NSAppearance(named: .darkAqua)
        for item in items() {
            if item.startsGroup, !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            let entry = RecorderClosureMenuItem(title: item.title, handler: item.action)
            entry.state = item.isChecked ? .on : .off
            if let symbol = item.systemImage {
                entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                    ?? NSImage(systemSymbolName: AIMode.defaultSymbol, accessibilityDescription: nil)
            }
            menu.addItem(entry)
        }

        // Anchor at the click, in the panel's content view.
        let event = NSApp.currentEvent
        guard let view = event?.window?.contentView, let event else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        isMenuOpen = true
        // After the button's action returns: `popUp` runs a nested tracking loop.
        Task { @MainActor in
            menu.popUp(positioning: nil, at: NSPoint(x: point.x - 12, y: point.y - 8), in: view)
            isMenuOpen = false
        }
    }
}

/// `NSMenuItem` that runs a closure.
@MainActor
final class RecorderClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        handler()
    }
}
