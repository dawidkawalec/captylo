import Foundation

/// Outcome of "Testuj tryb": the AI text plus how long it took.
struct ModeTestResult: Sendable, Equatable {
    var text: String
    var ms: Int
    var model: String
    /// The call took longer than the mode's own deadline: on a dictation it would have been
    /// dropped and the raw transcript pasted.
    var exceedsModeDeadline: Bool
}

/// "Testuj tryb" on the Modele screen: one call of a mode (saved or still being edited) on a
/// sample text. Uses the enhancer with the long file deadline, so a cold connection does not
/// fail the test; `exceedsModeDeadline` tells whether the mode would have kept its limit.
@MainActor
struct ModeTester {
    let enhancer: any TextEnhancing
    let vocabulary: @MainActor () -> [String]

    /// A messy Polish dictation that every built-in mode has something to do with.
    static var defaultSample: String {
        String(localized: "no więc yyy jutro o dziesiątej mam spotkanie z Martą w sprawie oferty, trzeba przygotować wycenę, to znaczy dwie wyceny, i wysłać jej maila do piątku, a i jeszcze zadzwonić do księgowej")
    }

    /// The AI text, or the reason there is none (`EnhancementSkip` / `EnhancementFailure`,
    /// both `LocalizedError` with a Polish message).
    func run(_ mode: AIMode, sample: String) async -> Result<String, any Error> {
        await runDetailed(mode, sample: sample).map(\.text)
    }

    func runDetailed(_ mode: AIMode, sample: String) async -> Result<ModeTestResult, any Error> {
        var job = mode.job(vocabulary: vocabulary())
        job.deadline = nil
        let outcome = await enhancer.enhance(sample, job: job)
        switch outcome {
        case .enhanced(let text, let ms, let model):
            let limitMs = Int((mode.clampedDeadlineSeconds * 1000).rounded())
            return .success(ModeTestResult(text: text, ms: ms, model: model, exceedsModeDeadline: ms > limitMs))
        case .skipped(let skip):
            return .failure(skip)
        case .failed(let failure, _):
            return .failure(failure)
        }
    }
}
