import AppKit

/// "Popraw": the user selects a misheard word in any app, presses ⌃⌥⌘P (or picks "Popraw w
/// Captylo" from the Services menu) and types the right version. Captylo pastes it over the
/// selection and learns the pair at once (`SelfLearning.learnManual`), saying what it decided.
@MainActor
final class ManualCorrection {
    /// Longer selections are not corrections of a word (and would not fit the panel).
    static let maxSelection = 600
    /// Time for the app to take the focus back before Cmd+V.
    static let refocusDelay: Duration = .milliseconds(120)

    private let learning: SelfLearning
    private let output: TextOutput
    private let toasts: any ToastPresenting
    private let outputSettings: () -> OutputSettings
    /// A take records, transcribes or pastes: its Cmd+V must not meet ours or land in the panel.
    /// Set by `AppState` once the dictation controller exists.
    var isDictating: () -> Bool = { false }

    private var panel: CorrectionPanel?
    /// Reading the selection, or pasting the fix: a second ⌃⌥⌘P waits for the first.
    private var isBusy = false

    init(
        learning: SelfLearning,
        output: TextOutput,
        toasts: any ToastPresenting,
        outputSettings: @escaping () -> OutputSettings
    ) {
        self.learning = learning
        self.output = output
        self.toasts = toasts
        self.outputSettings = outputSettings
    }

    var isShowing: Bool { panel != nil }

    /// ⌃⌥⌘P: reads the selection of the frontmost app.
    func start() {
        guard panel == nil, !isBusy, !isDictating() else { return }
        guard AXIsProcessTrusted() else {
            toasts.showError(String(localized: "„Popraw” potrzebuje uprawnienia Dostępność."))
            return
        }
        guard let app = Self.targetApp() else { return }
        isBusy = true
        Task {
            let selection = await SelectionReader.read(from: app, output: output)
            isBusy = false
            present(selection, in: app)
        }
    }

    /// Services menu "Popraw w Captylo": the app handed the selection over.
    func start(selection: String) {
        guard panel == nil, !isBusy, !isDictating() else { return }
        guard let app = Self.targetApp() ?? NSWorkspace.shared.menuBarOwningApplication.flatMap({
            $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0
        }) else {
            toasts.showInfo(String(localized: "Zaznacz słowo, które chcesz poprawić, i naciśnij \(GlobalShortcut.correction.display)."))
            return
        }
        present(selection, in: app)
    }

    /// A take starts (the dictation hotkey): the panel goes away, so the take never pastes into it.
    func cancel() {
        close()
    }

    // MARK: - Panel

    private func present(_ selection: String?, in app: NSRunningApplication) {
        guard let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            toasts.showInfo(String(localized: "Zaznacz słowo, które chcesz poprawić, i naciśnij \(GlobalShortcut.correction.display)."))
            return
        }
        guard selection.count <= Self.maxSelection else {
            toasts.showInfo(String(localized: "Zaznacz krótszy fragment: słowo albo zdanie."))
            return
        }
        let model = CorrectionModel(original: selection)
        model.previewFor = { [learning] text in learning.preview(original: selection, corrected: text) }
        let panel = CorrectionPanel(model: model)
        model.onCancel = { [weak self] in self?.close() }
        model.onSubmit = { [weak self, weak model] in
            guard let self, let model, model.preview != .unchanged else { return }
            self.close()
            self.isBusy = true
            Task {
                await self.apply(original: selection, corrected: model.text, in: app)
                self.isBusy = false
            }
        }
        self.panel = panel
        panel.present()
        Log.learning.info("Popraw opened (\(selection.count) chars)")
    }

    private func close() {
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
    }

    // MARK: - Apply

    private func apply(original: String, corrected: String, in app: NSRunningApplication) async {
        let fixed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fixed.isEmpty else { return }
        // The panel never activated Captylo, but a click may have moved the focus: hand it back.
        app.activate()
        try? await Task.sleep(for: Self.refocusDelay)
        guard !isDictating() else {
            output.copy(fixed)
            toasts.showError(String(localized: "Nie udało się podmienić tekstu. Poprawka jest w schowku."))
            return
        }
        var settings = outputSettings()
        // Keep a space the selection ended with (Word selects a word with its space); a selected
        // line ends with a newline, which must stay a newline, so it is pasted as part of the text.
        let trailing = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        settings.trailingSpace = trailing == " "
        settings.suffix = trailing.contains(where: \.isNewline) ? trailing : ""
        let result = await output.deliver(fixed, settings)
        if case .copiedOnly = result {
            toasts.showError(String(localized: "Nie udało się podmienić tekstu. Poprawka jest w schowku."))
        }

        switch learning.learnManual(original: original, corrected: fixed, appBundleID: app.bundleIdentifier) {
        case .learn, .unchanged:
            // "Zapamiętałem ... [Cofnij]" comes from the lesson itself.
            break
        case .rewrite:
            toasts.showInfo(String(localized: "Poprawione. Bez nauki: to zmiana treści."))
        case .known:
            toasts.showInfo(String(localized: "Poprawione. To już znam."))
        case .off:
            toasts.showInfo(String(localized: "Poprawione. Nauka jest wyłączona."))
        }
    }

    /// The frontmost app, unless it is Captylo itself.
    private static func targetApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app
    }
}

/// The Services menu entry "Popraw w Captylo" (`NSServices` in Info.plist, message
/// `fixSelection`): the selected text arrives on a pasteboard.
@MainActor
final class CorrectionServiceProvider: NSObject {
    private let correction: ManualCorrection

    init(correction: ManualCorrection) {
        self.correction = correction
    }

    @objc func fixSelection(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string) else {
            error.pointee = "No text" as NSString
            return
        }
        correction.start(selection: text)
    }
}
