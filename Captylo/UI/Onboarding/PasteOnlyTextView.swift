import AppKit
import SwiftUI

/// A text field that cannot be typed into: only pasted text (Cmd+V from the menu, or the app's
/// own synthetic paste after a dictation) lands in it. Used by the "Wypróbuj" step so the only way
/// to fill it is to dictate. Shows a placeholder while empty and mirrors its content into `text`.
@MainActor
struct PasteOnlyTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Make the field first responder shortly after it appears so the paste has a target.
    var focusesOnAppear = true

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PasteOnlyNSTextView()
        textView.delegate = context.coordinator
        textView.placeholder = placeholder
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // Transparent: the field sits on a Dusk Glass inset card that draws the surface.
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView

        if focusesOnAppear {
            Task { @MainActor [weak textView] in
                try? await Task.sleep(for: .milliseconds(200))
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? PasteOnlyNSTextView else { return }
        textView.placeholder = placeholder
        if textView.string != text {
            textView.string = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PasteOnlyTextView

        init(parent: PasteOnlyTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let value = textView.string
            if parent.text != value {
                parent.text = value
            }
        }
    }
}

/// `NSTextView` that swallows typing and editing but lets `paste(_:)` through (port note 4).
final class PasteOnlyNSTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    private var isApplyingPaste = false

    init() {
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        super.init(frame: .zero, textContainer: container)

        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        isRichText = false
        allowsUndo = false
        usesFontPanel = false
        usesFindBar = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        font = NSFont.systemFont(ofSize: 15)
        // White on glass (docs/design/dusk-glass.md): primary 95 %, placeholder 50 %.
        textColor = NSColor.white.withAlphaComponent(0.95)
        insertionPointColor = NSColor.white
        textContainerInset = NSSize(width: 14, height: 14)
        drawsBackground = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    // MARK: Paste is the only way in

    override func paste(_ sender: Any?) {
        isApplyingPaste = true
        defer { isApplyingPaste = false }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        isApplyingPaste = true
        defer { isApplyingPaste = false }
        super.pasteAsPlainText(sender)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else {
            // Typing, Return, Delete, arrows: swallowed on purpose.
            return
        }
        // The menu bar normally handles Cmd+V before keyDown; this covers a window without an Edit menu.
        if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "v" {
            paste(self)
            return
        }
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard isApplyingPaste else { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func insertNewline(_ sender: Any?) {}
    override func insertTab(_ sender: Any?) {}
    override func deleteBackward(_ sender: Any?) {}
    override func deleteForward(_ sender: Any?) {}
    override func deleteWordBackward(_ sender: Any?) {}
    override func deleteWordForward(_ sender: Any?) {}
    override func deleteToBeginningOfLine(_ sender: Any?) {}
    override func deleteToEndOfLine(_ sender: Any?) {}
    override func cut(_ sender: Any?) {}
    override func delete(_ sender: Any?) {}

    // MARK: Placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ]
        let padding = textContainer?.lineFragmentPadding ?? 0
        // The insertion caret blinks at the text origin: start the placeholder just after it,
        // with a clear gap, so it never reads as a glitch touching the first glyph ("|Tutaj").
        let caretGap: CGFloat = 7
        let origin = NSPoint(x: textContainerInset.width + padding + caretGap, y: textContainerInset.height)
        let width = max(bounds.width - 2 * (textContainerInset.width + padding), 0)
        let rect = NSRect(x: origin.x, y: origin.y, width: width, height: bounds.height - origin.y)
        (placeholder as NSString).draw(in: rect, withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
