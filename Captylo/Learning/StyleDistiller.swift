import Foundation

/// What self-learning adds to an AI prompt: misheard pairs, the style profile and the app the
/// text is going to.
struct LearningPromptContext: Sendable, Equatable {
    var misheard: [TermCorrection] = []
    /// Distilled style rules ("" = none yet or learning off).
    var style: String = ""
    /// Name of the app the dictation will be pasted into (only sent together with a style).
    var targetApp: String?

    static let none = LearningPromptContext()
}

/// Self-learning stage 4: turns style samples (pasted text vs. the user's edit) into a short
/// style profile through the user's own AI, off the hot path. Pure prompt building here; the
/// call itself is injected into `SelfLearning`.
enum StyleDistiller {
    /// New style samples that trigger a distillation.
    static let batch = 8
    static let maxProfileChars = 700
    static let maxSampleChars = 600

    static let systemPrompt = """
        You maintain a short writing-style guide for one person who dictates text. The user message has the current guide \
        and pairs of texts: BEFORE is what the dictation app pasted, AFTER is how the person corrected it, with the app name.
        Update the guide:
        - Keep rules that still hold, add rules the pairs show clearly, drop rules they contradict.
        - Only style: greetings and sign-offs, punctuation, formality, word choice, formatting. Never facts, topics or content from the texts.
        - When the pairs differ by app, start that rule with the app name ("Mail: ...", "Slack: ...").
        - At most 8 short lines starting with "- ", under 600 characters, written in Polish.
        Output only the guide.
        """

    /// The user message: the current guide, then the new pairs.
    static func input(profile: String, samples: [StyleSample], appName: (String?) -> String?) -> String {
        var lines = ["CURRENT GUIDE:", profile.isEmpty ? "(empty)" : profile, ""]
        for (index, sample) in samples.enumerated() {
            lines.append("PAIR \(index + 1)" + (appName(sample.appBundleID).map { " (\($0))" } ?? "") + ":")
            lines.append("BEFORE: " + String(sample.delivered.prefix(maxSampleChars)))
            lines.append("AFTER: " + String(sample.corrected.prefix(maxSampleChars)))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Trimmed, without code fences, capped at whole lines under `maxProfileChars`.
    static func clean(_ output: String) -> String {
        var kept: [String] = []
        var length = 0
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("```") else { continue }
            let added = kept.isEmpty ? line.count : line.count + 1
            guard length + added <= maxProfileChars else { break }
            kept.append(line)
            length += added
        }
        return kept.joined(separator: "\n")
    }
}
