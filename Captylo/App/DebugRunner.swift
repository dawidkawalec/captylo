import AppKit
import Foundation

/// Headless debug commands (docs/architecture.md "Debug CLI flags"): JSON on stdout, exit code back.
/// `--show-widget` is the exception: it shows the widget and never returns.
@MainActor
final class DebugRunner: DebugCommandRunner {
    private let appState: AppState
    /// Keeps the demo widget alive for `--show-widget`.
    private var demo: (model: RecorderModel, controller: RecorderPanelController, driver: RecorderDemoDriver)?
    /// Keeps the `--design-preview` windows alive.
    private var designPreview: DesignPreviewRunner?

    init(appState: AppState) {
        self.appState = appState
    }

    func run(_ command: DebugCommand) async -> Int32 {
        switch command {
        case .transcribe(let url, let ai, let language, let engine):
            return await transcribe(url: url, ai: ai, language: language, engine: engine)
        case .showWidget(let state):
            return await showWidget(state)
        case .check:
            return await check()
        case .resetOnboarding:
            appState.settings.onboardingStep = AppSettings.defaultOnboardingStep
            appState.settings.onboardingDone = false
            Self.emit(["ok": true, "onboardingStep": AppSettings.defaultOnboardingStep, "onboardingDone": false])
            return 0
        case .openSection:
            // A GUI launch handled by `AppDelegate`; never routed here.
            return 0
        case .designPreview(let target):
            let runner = DesignPreviewRunner(appState: appState)
            designPreview = runner
            return await runner.run(target)
        case .importLegacy(let dryRun):
            return await importLegacy(dryRun: dryRun)
        case .axProbe(let showText):
            return await axProbe(showText: showText)
        case .watchPaste(let text):
            return await watchPaste(text)
        }
    }

    // MARK: --watch-paste

    /// The real paste and watch path of a dictation, without the microphone. Ends like a
    /// dictation's watch (focus leaves the field, or 90 s idle) and prints the learning memory.
    private func watchPaste(_ text: String) async -> Int32 {
        guard AXIsProcessTrusted() else {
            Self.emit(["error": "Accessibility not granted for this binary"])
            return 1
        }
        let watcher = EditWatcher(learning: appState.learning, isEnabled: { true })
        // Like a dictation: prepare at the start of the take, paste a couple of seconds later.
        watcher.prepare()
        try? await Task.sleep(for: .seconds(2))
        await watcher.willPaste()
        let delivery = await appState.textOutput.deliver(text, OutputSettings(restoreClipboard: true, trailingSpace: false))
        guard delivery == .pasted else {
            Self.emit(["error": "Paste failed"])
            return 1
        }
        watcher.didPaste(text)
        Self.emitLine(["pasted": true, "watching": watcher.isWatching])
        while watcher.isWatching {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let data = appState.learning.store.data
        Self.emit([
            "learned": data.learned.map { ["misheard": $0.pair.misheard, "correct": $0.pair.correct, "rule": $0.ruleID != nil] },
            "candidates": data.candidates.map { ["misheard": $0.pair.misheard, "correct": $0.pair.correct, "count": $0.count] },
            "styleSamples": data.styleSamples.count,
        ])
        return 0
    }

    // MARK: --ax-probe

    /// Polls the focused element once a second and prints a compact JSON line when its app, role,
    /// length or selection changes. Electron apps get `AXManualAccessibility` once per process.
    /// Runs until killed (Ctrl+C).
    private func axProbe(showText: Bool) async -> Int32 {
        guard AXIsProcessTrusted() else {
            Self.emit(["error": "Accessibility not granted for this binary"])
            return 1
        }
        var manualTried = Set<pid_t>()
        var lastKey: String?
        Self.emitLine(["probe": "started", "showText": showText])
        while true {
            // Wake Electron apps before asking for the focused element, or they report none.
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
               manualTried.insert(front.processIdentifier).inserted {
                let accepted = AXText.enableManualAccessibility(pid: front.processIdentifier)
                Self.emitLine(["manualAccessibility": accepted, "bundleID": Self.orNull(front.bundleIdentifier)])
            }
            let snapshot = AXText.focusedSnapshot()
            let key = Self.probeKey(snapshot)
            if key != lastKey {
                Self.emitLine(Self.probePayload(snapshot, showText: showText))
                lastKey = key
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// What counts as "changed": the text itself is compared by length only.
    private static func probeKey(_ snapshot: AXText.Snapshot?) -> String {
        guard let snapshot else { return "none" }
        let selection = snapshot.selection.map { "\($0.location):\($0.length)" } ?? "-"
        return [
            snapshot.bundleID ?? "-", snapshot.role ?? "-", snapshot.subrole ?? "-",
            snapshot.length.map(String.init) ?? "-", snapshot.value == nil ? "novalue" : "value", selection,
        ].joined(separator: "|")
    }

    private static func probePayload(_ snapshot: AXText.Snapshot?, showText: Bool) -> [String: Any] {
        guard let snapshot else { return ["time": timestamp(), "focused": NSNull()] }
        var payload: [String: Any] = [
            "time": timestamp(),
            "bundleID": orNull(snapshot.bundleID),
            "app": orNull(snapshot.appName),
            "role": orNull(snapshot.role),
            "subrole": orNull(snapshot.subrole),
            "secure": snapshot.isSecure,
            "length": orNull(snapshot.length),
            "readable": snapshot.value != nil,
            "selection": orNull(snapshot.selection.map { [$0.location, $0.length] }),
        ]
        if showText, let value = snapshot.value {
            payload["tail"] = String(value.suffix(80))
        }
        return payload
    }

    private static func timestamp() -> String {
        Date().formatted(.dateTime.hour().minute().second())
    }

    /// One compact JSON object per line, for long-running output (`--ax-probe`).
    private static func emitLine(_ payload: [String: Any]) {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: options),
           let text = String(data: data, encoding: .utf8) {
            print(text)
            fflush(stdout)
        }
    }

    // MARK: --import-legacy

    /// Imports into `AppPaths` (`CAPTYLO_DATA_DIR` for checks on a copy). A real run refuses while
    /// the old app runs, and while another Captylo uses the same data folder (a running Captylo is
    /// fine next to a `CAPTYLO_DATA_DIR` run). A dry run reads copies only and writes nothing.
    private func importLegacy(dryRun: Bool) async -> Int32 {
        if !dryRun {
            if appState.storeIsFallback {
                Self.emit(["error": LegacyImportError.storeUnavailable.errorDescription ?? ""])
                return 1
            }
            if let blocking = LegacyImportGuard.blockingError(checkOtherCaptylo: AppPaths.dataDirectoryOverride == nil) {
                Self.emit(["error": blocking.errorDescription ?? ""])
                return 1
            }
        }
        let dictionary = appState.dictionary
        let importer = LegacyImporter(
            sources: LegacySource.discover(),
            database: appState.database,
            recordingsDirectory: AppPaths.recordings,
            mergeDictionary: { words, rules in
                await MainActor.run { dictionary.mergeImported(vocabulary: words, rules: rules) }
            }
        )
        let days = appState.settings.audioRetentionDays
        let cutoff: Date? = days > 0 ? Date().addingTimeInterval(-Double(days) * 86_400) : nil
        do {
            let report = try await importer.run(dryRun: dryRun, audioCutoff: cutoff)
            if !dryRun {
                do {
                    try LegacyImportMarker(importedAt: Date(), report: report).save()
                } catch {
                    Log.data.error("Could not save the legacy import marker: \(error.localizedDescription, privacy: .public)")
                }
            }
            let data = try JSONEncoder().encode(report)
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Self.emit(["error": "report encoding failed"])
                return 1
            }
            Self.emit(payload)
            return 0
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Self.emit(["error": message])
            return 1
        }
    }

    // MARK: --transcribe

    private func transcribe(url: URL, ai: Bool, language: String?, engine engineOverride: STTEngine?) async -> Int32 {
        let settings = appState.settings
        let languageCode: String? = language.map { TranscriptionLanguages.engineCode(for: $0) } ?? settings.transcriptionLanguage
        let engine = engineOverride ?? settings.sttEngine
        let started = ContinuousClock.now
        do {
            let (samples, duration) = try await AudioDecoder.decode16kMono(url)
            // The router needs a finalized 16 kHz WAV for the cloud path; write one next to the temp files.
            let id = UUID()
            let wavURL = FileManager.default.temporaryDirectory.appending(path: "\(id.uuidString).wav")
            try AudioDecoder.writeWAV16k(samples, to: wavURL)
            defer { try? FileManager.default.removeItem(at: wavURL) }

            if engine == .parakeet {
                try await appState.parakeetEngine.load()
            }
            let audio = CapturedAudio(id: id, fileURL: wavURL, samples: samples, duration: duration)
            let result = try await appState.transcriptionRouter.transcribe(
                audio,
                engine: engine,
                language: languageCode,
                vocabulary: appState.dictionary.data.vocabulary
            )
            // Same spelling fix as a dictation, but nothing is learned from a debug run.
            let spelling = SpellingDetector.apply(result.text)
            let text = appState.dictionary.processor.process(spelling.text, language: languageCode)

            var enhancedText: String?
            var enhancementMs: Int?
            var enhancementModel: String?
            var enhancementMode: String?
            var enhancementNote: String?
            if ai {
                let mode = settings.activeMode
                enhancementMode = mode.name
                let outcome = await appState.enhancer.enhance(
                    text,
                    mode: mode,
                    vocabulary: appState.dictionary.data.vocabulary,
                    learned: appState.learning.promptContext
                )
                enhancementNote = outcome.note
                switch outcome {
                case .enhanced(let enhanced, let ms, let model):
                    enhancedText = enhanced
                    enhancementMs = ms
                    enhancementModel = model
                case .failed(let failure, let ms):
                    enhancementMs = ms
                    Log.enhancement.notice("AI skipped in --transcribe: \(failure.errorDescription ?? "", privacy: .public)")
                case .skipped:
                    break
                }
            }

            let total = ContinuousClock.now - started
            var payload: [String: Any] = [
                "text": text,
                "rawText": result.text,
                "spelled": spelling.spelled.map { ["heard": $0.heard, "spelled": $0.spelled] },
                "enhancedText": Self.orNull(enhancedText),
                "modelName": result.modelName,
                "transcriptionMs": result.ms,
                "enhancementMs": Self.orNull(enhancementMs),
                "durationSeconds": (duration * 100).rounded() / 100,
                "usedFallback": result.usedFallback,
                "totalMs": Int(total / .milliseconds(1)),
            ]
            if let enhancementModel {
                payload["enhancementModel"] = enhancementModel
            }
            if let enhancementMode {
                payload["enhancementMode"] = enhancementMode
                payload["enhancementNote"] = Self.orNull(enhancementNote)
            }
            Self.emit(payload)
            return 0
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Self.emit(["error": message])
            return 1
        }
    }

    // MARK: --show-widget

    private func showWidget(_ state: WidgetDebugState) async -> Int32 {
        let made = RecorderDemo.make(state: state)
        demo = made
        made.controller.show()
        made.driver.start()
        Self.emit(["ok": true, "widget": state.rawValue])
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    // MARK: --check

    private func check() async -> Int32 {
        let settings = appState.settings
        let historyCount = await appState.database.count()
        let modelStatus: String
        switch appState.modelStore.status {
        case .missing: modelStatus = "missing"
        case .downloading(let progress): modelStatus = "downloading \(Int(progress * 100))%"
        case .optimizing: modelStatus = "optimizing"
        case .ready: modelStatus = "ready"
        case .failed(let message): modelStatus = "failed: \(message)"
        }
        let micStatus: String
        switch MicrophonePermission.status {
        case .authorized: micStatus = "authorized"
        case .denied: micStatus = "denied"
        case .restricted: micStatus = "restricted"
        case .notDetermined: micStatus = "notDetermined"
        @unknown default: micStatus = "unknown"
        }
        let loginStatus: String
        switch appState.launchAtLogin.status {
        case .enabled: loginStatus = "enabled"
        case .notRegistered: loginStatus = "notRegistered"
        case .requiresApproval: loginStatus = "requiresApproval"
        case .notFound: loginStatus = "notFound"
        @unknown default: loginStatus = "unknown"
        }
        let payload: [String: Any] = [
            "bundle": Bundle.main.bundleIdentifier ?? "",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "permissions": [
                "microphone": micStatus,
                "accessibility": appState.accessibility.isTrusted,
            ],
            "model": [
                "status": modelStatus,
                "installed": ParakeetEngine.isDownloaded,
                "directory": AppPaths.parakeetModelDir.path(percentEncoded: false),
            ],
            "microphone": [
                "selected": Self.orNull(appState.audioDevices.resolveInput()?.name),
                "selection": Self.describe(settings.micSelection),
                "inputs": appState.audioDevices.inputs.map(\.name),
                "lidClosed": appState.audioDevices.isLidClosed,
            ],
            "hotkey": settings.hotkey.displayName,
            "paths": [
                "data": AppPaths.dataDirectory.path(percentEncoded: false),
                "store": AppPaths.store.path(percentEncoded: false),
                "dictionary": AppPaths.dictionaryJSON.path(percentEncoded: false),
                "recordings": AppPaths.recordings.path(percentEncoded: false),
            ],
            "settings": [
                "language": settings.language,
                "sttEngine": settings.sttEngine.rawValue,
                "livePreview": settings.livePreview,
                "aiEnabled": settings.aiEnabled,
                "aiModel": settings.aiModel,
                "aiActiveMode": settings.activeMode.name,
                "aiModes": settings.aiModes.count,
                "sounds": settings.sounds,
                "muteWhileRecording": settings.muteWhileRecording,
                "restoreClipboard": settings.restoreClipboard,
                "trailingSpace": settings.trailingSpace,
                "paragraphs": settings.paragraphs,
                "saveHistory": settings.saveHistory,
                "menuBarOnly": settings.menuBarOnly,
                "audioRetentionDays": settings.audioRetentionDays,
                "onboardingDone": settings.onboardingDone,
                "onboardingStep": settings.onboardingStep,
                "launchAtLogin": loginStatus,
            ],
            "keys": [
                "openRouter": appState.keyStore.get(KeyStore.Account.openRouter) != nil,
                "elevenLabs": appState.keyStore.get(KeyStore.Account.elevenLabs) != nil,
            ],
            "dictionary": [
                "vocabulary": appState.dictionary.data.vocabulary.count,
                "replacements": appState.dictionary.data.replacements.count,
                "fillers": appState.dictionary.data.fillerWords.count,
            ],
            "storeFallback": appState.storeIsFallback,
            "historyCount": historyCount,
            "dataDirectoryOverride": AppPaths.dataDirectoryOverride != nil,
            "oldAppRunning": appState.oldAppDetector.isOldAppRunning,
        ]
        Self.emit(payload)
        return 0
    }

    // MARK: Output

    private static func describe(_ selection: AudioInputSelection) -> String {
        switch selection {
        case .systemDefault: return "systemDefault"
        case .device(let uid, _): return uid
        }
    }

    /// `JSONSerialization` rejects Swift optionals: nil becomes JSON null.
    private static func orNull(_ value: (some Any)?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    /// One JSON object per command, keys sorted, flushed before the process exits.
    private static func emit(_ payload: [String: Any]) {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: options),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        } else {
            print("{\"error\":\"JSON serialization failed\"}")
        }
        fflush(stdout)
    }
}
