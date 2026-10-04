import Foundation

/// How strictly the AI may change the dictation. Drives the sanity guard, the token cap and the
/// short-text skip rule in `Enhancer`.
enum AIModeKind: String, Codable, CaseIterable, Sendable {
    /// Fidelity rules: same language, same meaning, only cleaned up. The output must stay close
    /// to the transcript in length, and 3 words or fewer skip the model.
    case cleanup
    /// Transforms the text (translate, restructure, e-mail, checklist). Only an empty or cut-off
    /// answer is rejected, and any non-empty text is sent.
    case rewrite
}
