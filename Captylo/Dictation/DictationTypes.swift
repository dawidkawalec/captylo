import CoreAudio
import Foundation

// Shared types and the seam protocols every module talks through.
// Ownership rule (docs/architecture.md): a module talks to another only through
// the protocols in this file and the concrete value types listed in the brief.

// MARK: - Phase

/// Phase of the dictation state machine: idle -> recording -> transcribing -> enhancing -> idle.
enum DictationPhase: Sendable, Equatable {
    case idle
    case recording
    case paused
    case transcribing
    case enhancing

    /// True while a stop is being processed; the hotkey is ignored in these phases.
    var isProcessing: Bool { self == .transcribing || self == .enhancing }

    /// True while audio capture is running (paused capture still holds the device).
    var isCapturing: Bool { self == .recording || self == .paused }
}

// MARK: - Captured audio

/// Result of a finished capture: the finalized WAV on disk plus the same audio in memory.
struct CapturedAudio: Sendable {
    /// Equals `Dictation.id` and the WAV file name (`<id>.wav`).
    let id: UUID
    /// Finalized 16 kHz mono Int16 WAV.
    let fileURL: URL
    /// Same audio as 16 kHz mono Float32 samples in [-1, 1].
    let samples: [Float]
    let duration: TimeInterval

    init(id: UUID, fileURL: URL, samples: [Float], duration: TimeInterval) {
        self.id = id
        self.fileURL = fileURL
        self.samples = samples
        self.duration = duration
    }
}

// MARK: - Errors

enum DictationError: LocalizedError, Sendable, Equatable {
    case micDenied
    case noMicrophone(lidClosed: Bool)
    case accessibilityMissing
    case modelNotReady
    case tooShort
    case emptyResult
    case capture(OSStatus)
    case stt(STTError)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .micDenied:
            return String(localized: "Brak dostępu do mikrofonu. Włącz go w Ustawieniach systemowych.")
        case .noMicrophone(let lidClosed):
            return lidClosed
                ? String(localized: "Nie znaleziono mikrofonu. Pokrywa jest zamknięta, podłącz zewnętrzny mikrofon.")
                : String(localized: "Nie znaleziono mikrofonu.")
        case .accessibilityMissing:
            return String(localized: "Brak uprawnienia Dostępność. Tekst skopiowano do schowka.")
        case .modelNotReady:
            return String(localized: "Model Parakeet nie jest gotowy. Pobierz go w zakładce Modele.")
        case .tooShort:
            return String(localized: "Nagranie było za krótkie.")
        case .emptyResult:
            return String(localized: "Nic nie usłyszałem.")
        case .capture(let status):
            return String(localized: "Błąd nagrywania (kod \(status)).")
        case .stt(let error):
            return error.errorDescription
        case .cancelled:
            return String(localized: "Anulowano.")
        }
    }
}

// MARK: - Records

enum DictationStatus: String, Codable, Sendable {
    case completed
    case failed
}

enum DictationSource: String, Codable, Sendable {
    case dictation
    case file
    case imported
}

/// Value mirror of `Dictation` used to cross into the `@ModelActor` (models never cross actors).
struct DictationRecord: Sendable, Equatable, Identifiable {
    var id: UUID
    var createdAt: Date
    /// Text after `TextProcessor` ("Oryginał"). Never an error message.
    var text: String
    /// AI output, success only.
    var enhancedText: String?
    var status: DictationStatus
    var errorMessage: String?
    var source: DictationSource
    var audioDuration: Double
    /// `<id>.wav` under `AppPaths.recordings`, never an absolute path.
    var audioFileName: String?
    var language: String?
    var modelName: String?
    var transcriptionMs: Int?
    var enhancementModel: String?
    var enhancementMs: Int?
    /// Name of the AI mode that produced `enhancedText` or was tried; nil when AI was off.
    var enhancementMode: String?
    /// Short Polish reason why AI produced no text ("Brak klucza OpenRouter", "Przekroczono
    /// limit 3 s"...); nil on success and when AI was off.
    var enhancementNote: String?
    /// Word count of the delivered text (`enhancedText ?? text`), computed once at save.
    var wordCount: Int

    var finalText: String { enhancedText ?? text }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        text: String = "",
        enhancedText: String? = nil,
        status: DictationStatus = .completed,
        errorMessage: String? = nil,
        source: DictationSource = .dictation,
        audioDuration: Double = 0,
        audioFileName: String? = nil,
        language: String? = nil,
        modelName: String? = nil,
        transcriptionMs: Int? = nil,
        enhancementModel: String? = nil,
        enhancementMs: Int? = nil,
        enhancementMode: String? = nil,
        enhancementNote: String? = nil,
        wordCount: Int = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.enhancedText = enhancedText
        self.status = status
        self.errorMessage = errorMessage
        self.source = source
        self.audioDuration = audioDuration
        self.audioFileName = audioFileName
        self.language = language
        self.modelName = modelName
        self.transcriptionMs = transcriptionMs
        self.enhancementModel = enhancementModel
        self.enhancementMs = enhancementMs
        self.enhancementMode = enhancementMode
        self.enhancementNote = enhancementNote
        self.wordCount = wordCount
    }

    /// Records one AI outcome: the text, model and timing on success, the note otherwise.
    /// `mode` is the name of the mode that ran. Never touches `text` or `wordCount`.
    mutating func applyEnhancement(_ outcome: EnhancementOutcome, mode: String) {
        enhancementMode = mode
        switch outcome {
        case .enhanced(let enhanced, let ms, let model):
            enhancedText = enhanced
            enhancementModel = model
            enhancementMs = ms
            enhancementNote = nil
        case .skipped, .failed:
            enhancedText = nil
            enhancementModel = nil
            enhancementMs = outcome.ms
            enhancementNote = outcome.note
        }
    }
}

// MARK: - Coordinator

/// Called by `HotkeyController`, the recorder widget and the menu bar.
/// Implemented by `DictationController`.
@MainActor
protocol RecorderCoordinator: AnyObject {
    var phase: DictationPhase { get }
    var isWidgetVisible: Bool { get }
    func start() async
    /// Stop capture, transcribe, optional AI cleanup, paste, save.
    func stop() async
    /// Abort capture or in-flight processing, delete the WAV, hide the widget. Saves nothing.
    func cancel() async
    /// P1: freeze the timer and drop samples while the engine keeps running.
    func togglePause()
}

// MARK: - Service seams (implemented by the modules, faked in tests)

/// AVAudioEngine capture (module Audio). Methods hop to the capture's own serial queue;
/// the implementation is a lock-guarded `@unchecked Sendable` class.
protocol AudioCapturing: AnyObject, Sendable {
    /// Create and configure the engine for the device without starting it (prewarm).
    func prepare(device: AudioDeviceID) async throws
    /// Start capturing: samples into `buffer` (16 kHz mono Float32), WAV to `fileURL`.
    func start(device: AudioDeviceID, fileURL: URL, into buffer: SampleBuffer) async throws
    /// P1: drop samples while paused, keep the engine running.
    func setPaused(_ paused: Bool)
    /// Full stop sequence; the WAV is finalized when this returns. Returns the recorded duration.
    func stop() async throws -> TimeInterval
    /// Stop and delete the file.
    func abort() async
    /// `abort()` that blocks until done, for app termination where nothing can be awaited.
    func abortSynchronously()
    /// Fired off the main thread when the device disappears; the controller calls `stop()`.
    var onDeviceDied: (@Sendable () -> Void)? { get set }
}

/// Level meter read by the waveform (module Audio). Pulled per frame inside `TimelineView`.
protocol LevelSource: AnyObject, Sendable {
    /// Normalized 0...1 level with a time-based EMA; `now` is `ProcessInfo.processInfo.systemUptime`.
    func read(now: TimeInterval) -> Float
}

/// Local vs cloud routing with Parakeet fallback (module Transcription).
protocol TranscriptionRouting: Sendable {
    func transcribe(
        _ audio: CapturedAudio,
        engine: STTEngine,
        language: String?,
        vocabulary: [String]
    ) async throws -> TranscriptionResult
}

/// OpenRouter AI call with a hard deadline (module Enhancement). Never throws: raw text wins on failure.
protocol TextEnhancing: Sendable {
    /// One call: the job carries the system prompt, the mode kind (guard, token cap, skip rule)
    /// and the deadline.
    func enhance(_ raw: String, job: EnhancementJob) async -> EnhancementOutcome
    /// Warm the connection at hotkey-down (debounced by the implementation).
    func prewarm() async
}

extension TextEnhancing {
    /// Strict cleanup with the implementation's own deadline.
    func enhance(_ raw: String, systemPrompt: String) async -> EnhancementOutcome {
        await enhance(raw, job: EnhancementJob(systemPrompt: systemPrompt))
    }

    /// One call in the given mode: its prompt with the vocabulary and what self-learning knows
    /// (misheard pairs, style), its kind and its deadline.
    func enhance(_ raw: String, mode: AIMode, vocabulary: [String], learned: LearningPromptContext = .none) async -> EnhancementOutcome {
        await enhance(raw, job: mode.job(vocabulary: vocabulary, learned: learned))
    }
}

/// Self-learning (module Learning): turns corrections into dictionary entries and AI hints.
/// Implementations check `AppSettings.learningEnabled` themselves.
@MainActor
protocol CorrectionLearning: AnyObject {
    /// "Ucz się z moich poprawek" is on.
    var isEnabled: Bool { get }
    /// Words spelled out loud in one take ("Honho, pisane H-O-N-C-H-O").
    func learn(spelled: [SpellingDetector.Spelled])
    /// The user edited text Captylo pasted (Accessibility watcher).
    func learn(delivered: String, corrected: String, appBundleID: String?)
    /// Misheard pairs, style profile and target app for the AI prompt (empty when learning is off).
    var promptContext: LearningPromptContext { get }
}

/// Watches the field a dictation was pasted into for the user's corrections (module Learning).
@MainActor
protocol PasteWatching: AnyObject {
    /// At the start of a take: lets the target app build its accessibility tree in time.
    func prepare()
    /// Right before Cmd+V: remembers the focused field and its text (bounded wait, see `EditWatcher`).
    func willPaste() async
    /// After a successful paste of `text`.
    func didPaste(_ text: String)
    /// Ends the current watch now (a new dictation starts).
    func flush()
}

/// Pasteboard + synthetic Cmd+V (module Output).
@MainActor
protocol TextDelivering: AnyObject {
    func deliver(_ text: String, _ settings: OutputSettings) async -> OutputResult
    /// Plain non-transient copy (history, menu bar).
    func copy(_ text: String)
}

/// Toast panel above the widget (module UI/Recorder).
@MainActor
protocol ToastPresenting: AnyObject {
    /// 3 s informational toast.
    func showInfo(_ message: String)
    /// 7 s error toast with the error sound.
    func showError(_ message: String)
    /// 7 s toast with one action button.
    func showAction(message: String, buttonTitle: String, action: @escaping @MainActor () -> Void)
    /// Toast with one action button that stays up for `lifetime` seconds, e.g. as long as the
    /// countdown its button can stop.
    func showAction(message: String, buttonTitle: String, lifetime: TimeInterval, action: @escaping @MainActor () -> Void)
}

extension ToastPresenting {
    func showError(_ error: any Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        showError(message)
    }

    func showAction(message: String, buttonTitle: String, lifetime: TimeInterval, action: @escaping @MainActor () -> Void) {
        showAction(message: message, buttonTitle: buttonTitle, action: action)
    }
}

/// Recorder widget panel (module UI/Recorder).
@MainActor
protocol RecorderWidgetPresenting: AnyObject {
    var isVisible: Bool { get }
    func show()
    func hide()
}

/// Start / stop / error cues (module Audio). Honors the `sounds` setting internally.
@MainActor
protocol SoundPlaying: AnyObject {
    func play(_ cue: SoundCue)
}

/// Default-output mute while recording (module Audio). Only undoes its own mute.
@MainActor
protocol SystemMuting: AnyObject {
    func muteIfEnabled(after delay: Duration)
    func restore()
}

/// 1 s tail preview over the live buffer (module Transcription). Always Parakeet.
protocol LivePreviewing: Sendable {
    /// Emits partial text while the stream is alive; cancel the consuming task to stop.
    func updates(buffer: SampleBuffer, language: String?) -> AsyncStream<String>
}
