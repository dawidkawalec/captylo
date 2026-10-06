import AppKit
import Observation
import SwiftUI

/// Observable content of the "Popraw" panel.
@MainActor
@Observable
final class CorrectionModel {
    /// The selected text, as it was.
    var original: String
    /// What the user types; starts as the selection.
    var text: String
    /// What Captylo would do with `text` (live, from `SelfLearning.preview`).
    var preview: SelfLearning.ManualPreview = .unchanged
    @ObservationIgnored var previewFor: (String) -> SelfLearning.ManualPreview = { _ in .unchanged }
    @ObservationIgnored var onSubmit: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}

    init(original: String) {
        self.original = original
        text = original.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func refreshPreview() {
        preview = previewFor(text)
    }
}

/// Borderless floating panel that takes typing without activating Captylo, so the app the text
/// was selected in stays active and keeps its selection for the paste. Esc or a click elsewhere
/// cancels.
@MainActor
final class CorrectionPanel: NSPanel {
    static let width: CGFloat = 460

    private let model: CorrectionModel
    private let hosting: NSHostingController<CorrectionView>

    init(model: CorrectionModel) {
        hosting = NSHostingController(rootView: CorrectionView(model: model))
        self.model = model
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 180),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false

        // Sized by `present()` (`sizeThatFits` at the fixed width).
        hosting.sizingOptions = []
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear
        contentView = hosting.view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        model.onCancel()
    }

    override func resignKey() {
        super.resignKey()
        // A click into another window: same as Esc.
        if isVisible {
            model.onCancel()
        }
    }

    /// Upper third of the screen under the mouse, like Spotlight.
    func present() {
        let fitted = hosting.sizeThatFits(in: NSSize(width: Self.width, height: 10_000))
        let size = NSSize(width: Self.width, height: ceil(fitted.height))
        setContentSize(size)
        let screen = RecorderPanelController.screenUnderMouse()
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        setFrameOrigin(NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.maxY - visible.height / 3 - size.height / 2).rounded()
        ))
        makeKeyAndOrderFront(nil)
    }
}

// MARK: - View

/// "Popraw w Captylo": the selection, a field for the right version and one line that says what
/// Captylo will do with it (learn a rule, a hint for AI, or only replace the text).
@MainActor
struct CorrectionView: View {
    @Bindable var model: CorrectionModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                GlassIconBadge(systemImage: "pencil.and.scribble")
                Text("Popraw w Captylo")
                    .font(GlassFont.sectionTitle)
                    .foregroundStyle(GlassColor.textPrimary)
                Spacer()
                Text(verbatim: GlobalShortcut.correction.display)
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textTertiary)
            }
            Text("Zaznaczone: „\(model.original.trimmingCharacters(in: .whitespacesAndNewlines))”")
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
            TextField("Poprawna wersja", text: $model.text, axis: .vertical)
                .textFieldStyle(.glass)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(model.onSubmit)
                .onChange(of: model.text) { model.refreshPreview() }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .accessibilityHidden(true)
                Text(verbatim: line)
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Anuluj", action: model.onCancel)
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                Button("Popraw", action: model.onSubmit)
                    .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
                    .disabled(model.preview == .unchanged)
            }
        }
        .padding(18)
        .frame(width: CorrectionPanel.width - 2 * Self.margin)
        .glassSurface(.panel, cornerRadius: GlassTokens.Radius.panel, tint: RecorderGlass<Capsule>.tint, shadow: false)
        .padding(Self.margin)
        .environment(\.appearsActive, true)
        .environment(\.colorScheme, .dark)
        .onAppear {
            model.refreshPreview()
            focused = true
        }
    }

    /// Transparent margin so the window shadow is not clipped.
    static let margin: CGFloat = VTSpacing.l

    private var line: String {
        switch model.preview {
        case .unchanged:
            return String(localized: "Wpisz poprawną wersję i naciśnij Enter.")
        case .rewrite:
            return String(localized: "Podmienię tekst, ale nie będę się tego uczyć: to zmiana treści, a nie źle rozpoznane słowo.")
        case .learn(let pairs, let rule):
            let list = Self.list(pairs)
            return rule
                ? String(localized: "Zapamiętam: \(list). Następnym razem poprawię to sam.")
                : String(localized: "Zapamiętam: \(list) jako podpowiedź dla AI. Oba słowa istnieją, więc nie zamieniam ich na sztywno.")
        case .known(let pairs):
            return String(localized: "To już znam: \(Self.list(pairs)). Tylko podmienię tekst.")
        case .off:
            return String(localized: "Podmienię tekst. Nauka jest wyłączona w Ustawieniach.")
        }
    }

    private var symbol: String {
        switch model.preview {
        case .learn: return "sparkles"
        case .rewrite, .off: return "arrow.left.arrow.right"
        case .known: return "checkmark"
        case .unchanged: return "keyboard"
        }
    }

    private var iconColor: Color {
        if case .learn = model.preview { return GlassColor.accent }
        return GlassColor.textTertiary
    }

    static func list(_ pairs: [TermCorrection]) -> String {
        pairs.map { "\($0.misheard) → \($0.correct)" }.joined(separator: ", ")
    }
}
