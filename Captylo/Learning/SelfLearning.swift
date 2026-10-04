import AppKit
import Observation

/// Turns corrections into dictionary entries (self-learning, local only). Fed by the dictation
/// pipeline: words spelled out loud now, edits of pasted text from the Accessibility watcher
/// later. Obeys `AppSettings.learningEnabled`; every lesson shows "Zapamiętałem ... [Cofnij]".
@MainActor
@Observable
final class SelfLearning: CorrectionLearning {
    /// Sightings of the same pair before it is learned. One: the owner's workflow is "select the
    /// word, retype it, done"; the "Zapamiętałem ... [Cofnij]" toast is the safety net. Candidates
    /// stay in the data model for a stricter setting later.
    static let threshold = 1
    /// Style samples kept for the style profile (oldest dropped first).
    static let maxStyleSamples = 50
    static let maxSampleLength = 2_000
    /// Hints sent with the AI prompt, newest first.
    static let maxPromptHints = 40

    /// One AI call (system prompt, user message) -> answer, or nil when AI is off or failed.
    typealias Distill = @MainActor (_ system: String, _ input: String) async -> String?

    let store: LearningStore
    /// A style distillation is running (Słownik shows it).
    private(set) var isDistilling = false
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let dictionary: DictionaryStore
    @ObservationIgnored private let toasts: any ToastPresenting
    @ObservationIgnored private let isRealWord: @MainActor (String) -> Bool
    @ObservationIgnored private let distill: Distill?

    init(
        settings: AppSettings,
        dictionary: DictionaryStore,
        store: LearningStore,
        toasts: any ToastPresenting,
        isRealWord: @escaping @MainActor (String) -> Bool = WordChecker.isRealWord,
        distill: Distill? = nil
    ) {
        self.settings = settings
        self.dictionary = dictionary
        self.store = store
        self.toasts = toasts
        self.isRealWord = isRealWord
        self.distill = distill
    }

    var isEnabled: Bool { settings.learningEnabled }

    var promptContext: LearningPromptContext {
        guard isEnabled else { return .none }
        let style = store.data.styleProfile
        let front = NSWorkspace.shared.frontmostApplication
        let target = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front?.localizedName
        return LearningPromptContext(misheard: promptHints, style: style, targetApp: style.isEmpty ? nil : target)
    }

    /// Learned pairs without a replacement rule: the AI prompt gets them as "heard -> meant".
    var promptHints: [TermCorrection] {
        guard isEnabled else { return [] }
        return store.data.learned
            .filter { $0.ruleID == nil && !CorrectionLearner.isSameWord($0.pair.misheard, $0.pair.correct) }
            .sorted { $0.learnedAt > $1.learnedAt }
            .prefix(Self.maxPromptHints)
            .map(\.pair)
    }

    // MARK: - CorrectionLearning

    func learn(spelled: [SpellingDetector.Spelled]) {
        guard isEnabled else { return }
        for item in spelled {
            if CorrectionLearner.isSameWord(item.heard, item.spelled) {
                // Heard right (maybe inflected): only make sure the word is known.
                let word = CorrectionLearner.preferredForm(heard: item.heard, spelled: item.spelled)
                if dictionary.addLearnedVocabulary(word), settings.learningNotifications {
                    toasts.showInfo(String(localized: "Dodano do słownika: \(word)"))
                }
            } else {
                consider(TermCorrection(misheard: item.heard, correct: item.spelled), source: .voice)
            }
        }
    }

    func learn(delivered: String, corrected: String, appBundleID: String?) {
        guard isEnabled else { return }
        let analysis = CorrectionLearner.analyze(delivered: delivered, corrected: corrected, isRealWord: isRealWord)
        guard !analysis.isNoise else { return }
        recordEditStats(analysis)
        for term in analysis.terms {
            consider(term, source: .edit)
        }
        if analysis.isStyle {
            addStyleSample(delivered: delivered, corrected: corrected, appBundleID: appBundleID)
        }
    }

    // MARK: - Undo

    /// "Cofnij" and Słownik "Usuń": removes the rule and the vocabulary entry this lesson added.
    /// With `block` the pair is never learned again.
    func undo(_ id: UUID, block: Bool = true) {
        guard let entry = store.data.learned.first(where: { $0.id == id }) else { return }
        if let ruleID = entry.ruleID {
            dictionary.removeRule(ruleID)
        }
        if entry.addedToVocabulary, !isStillNeeded(entry.pair.correct, except: id) {
            dictionary.removeVocabulary(entry.pair.correct)
        }
        store.update { data in
            data.learned.removeAll { $0.id == id }
            if block, !data.blocked.contains(where: { Self.samePair($0, entry.pair) }) {
                data.blocked.append(entry.pair)
            }
        }
        Log.learning.info("Undid a learned term (blocked: \(block))")
    }

    /// Forgets every lesson and removes what they added to the dictionary.
    func resetAll() {
        for entry in store.data.learned {
            undo(entry.id, block: false)
        }
        store.reset()
    }

    // MARK: - Rules

    private func consider(_ pair: TermCorrection, source: CorrectionSource) {
        let data = store.data
        guard !data.blocked.contains(where: { Self.samePair($0, pair) }) else { return }
        guard !data.learned.contains(where: { Self.samePair($0.pair, pair) }) else { return }

        // The user changed a learned form back: first time drop the rule, second time forget it.
        if let learned = data.learned.first(where: { Self.samePair($0.pair, TermCorrection(misheard: pair.correct, correct: pair.misheard)) }) {
            revert(learned)
            return
        }

        let needed = source == .voice || dictionary.containsVocabulary(pair.correct) ? 1 : Self.threshold
        let key = Self.key(pair)
        let seen = (data.candidates.first { Self.key($0.pair) == key }?.count ?? 0) + 1
        guard seen >= needed else {
            store.update { data in
                if let index = data.candidates.firstIndex(where: { Self.key($0.pair) == key }) {
                    data.candidates[index].count = seen
                    data.candidates[index].lastSeen = Date()
                } else {
                    data.candidates.append(LearningCandidate(pair: pair, count: seen, lastSeen: Date()))
                }
            }
            return
        }
        apply(pair, source: source)
    }

    private func apply(_ pair: TermCorrection, source: CorrectionSource) {
        let addedToVocabulary = dictionary.addLearnedVocabulary(pair.correct)
        var ruleID: UUID?
        if canReplace(pair) {
            let rule = ReplacementRule(triggers: [pair.misheard], replacement: pair.correct)
            if dictionary.upsert(rule) == nil {
                ruleID = rule.id
            }
        }
        let entry = LearnedTerm(pair: pair, source: source, ruleID: ruleID, addedToVocabulary: addedToVocabulary)
        store.update { data in
            data.candidates.removeAll { Self.key($0.pair) == Self.key(pair) }
            data.learned.append(entry)
        }
        Log.learning.info("Learned a term (\(source.rawValue, privacy: .public), rule: \(ruleID != nil))")
        guard settings.learningNotifications else { return }
        let id = entry.id
        toasts.showAction(
            message: String(localized: "Zapamiętałem: \(pair.misheard) → \(pair.correct)"),
            buttonTitle: String(localized: "Cofnij"),
            action: { [weak self] in self?.undo(id) }
        )
    }

    private func revert(_ entry: LearnedTerm) {
        if entry.reverts == 0, let ruleID = entry.ruleID {
            dictionary.removeRule(ruleID)
            store.update { data in
                guard let index = data.learned.firstIndex(where: { $0.id == entry.id }) else { return }
                data.learned[index].ruleID = nil
                data.learned[index].reverts += 1
            }
            Log.learning.info("A learned rule was corrected back: kept only as an AI hint")
        } else {
            undo(entry.id, block: true)
        }
    }

    /// A deterministic rule only when the misheard side holds a non-word and is not just an
    /// inflected form of the correct word ("Figmę" / "Figma"); a case fix of a non-word
    /// ("supabase" -> "Supabase") is fine. Otherwise the pair stays an AI hint.
    func canReplace(_ pair: TermCorrection) -> Bool {
        let words = pair.misheard.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return false }
        let caseOnly = pair.misheard.lowercased() == pair.correct.lowercased()
        guard caseOnly || !CorrectionLearner.isSameWord(pair.misheard, pair.correct) else { return false }
        return !words.allSatisfy(isRealWord)
    }

    private func isStillNeeded(_ word: String, except id: UUID) -> Bool {
        store.data.learned.contains { $0.id != id && $0.pair.correct.lowercased() == word.lowercased() }
    }

    private func addStyleSample(delivered: String, corrected: String, appBundleID: String?) {
        let sample = StyleSample(
            delivered: String(delivered.prefix(Self.maxSampleLength)),
            corrected: String(corrected.prefix(Self.maxSampleLength)),
            appBundleID: appBundleID,
            date: Date()
        )
        store.update { data in
            data.styleSamples.append(sample)
            if data.styleSamples.count > Self.maxStyleSamples {
                data.styleSamples.removeFirst(data.styleSamples.count - Self.maxStyleSamples)
            }
            data.samplesSinceDistill += 1
        }
        if store.data.samplesSinceDistill >= StyleDistiller.batch {
            Task { await distillStyle() }
        }
    }

    // MARK: - Edit rate

    static let statsDays = 60
    /// Below this many watched words the rate is not shown (too noisy).
    static let minimumRateWords = 50

    /// Words changed per 100 pasted words in watched fields over the last `days` days; nil
    /// until there are `minimumRateWords` words. Falling over time = Captylo learned.
    func correctionRate(days: Int = 14, now: Date = Date()) -> Double? {
        let cutoff = Self.dayKey(Calendar.current.date(byAdding: .day, value: -(days - 1), to: now) ?? now)
        let recent = store.data.editStats.filter { $0.day >= cutoff }
        let words = recent.reduce(0) { $0 + $1.words }
        guard words >= Self.minimumRateWords else { return nil }
        return Double(recent.reduce(0) { $0 + $1.changed }) * 100 / Double(words)
    }

    private func recordEditStats(_ analysis: CorrectionAnalysis, now: Date = Date()) {
        guard analysis.deliveredWords > 0 else { return }
        let day = Self.dayKey(now)
        store.update { data in
            if let index = data.editStats.firstIndex(where: { $0.day == day }) {
                data.editStats[index].words += analysis.deliveredWords
                data.editStats[index].changed += analysis.changedWords
            } else {
                data.editStats.append(DailyEditStat(day: day, words: analysis.deliveredWords, changed: analysis.changedWords))
            }
            if data.editStats.count > Self.statsDays {
                data.editStats.removeFirst(data.editStats.count - Self.statsDays)
            }
        }
    }

    static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    // MARK: - Style

    /// The user edited the profile in Słownik; the next distillation starts from it.
    func setStyleProfile(_ text: String) {
        store.update { $0.styleProfile = String(text.prefix(StyleDistiller.maxProfileChars)) }
    }

    /// Updates the profile from the samples added since the last run (at least one), through the
    /// injected AI call. Keeps the old profile when AI is off or the call fails.
    func distillStyle() async {
        guard isEnabled, !isDistilling, let distill else { return }
        let fresh = Array(store.data.styleSamples.suffix(max(1, min(store.data.samplesSinceDistill, Self.maxStyleSamples))))
        guard !fresh.isEmpty else { return }
        isDistilling = true
        defer { isDistilling = false }
        let input = StyleDistiller.input(profile: store.data.styleProfile, samples: fresh, appName: Self.appName)
        guard let output = await distill(StyleDistiller.systemPrompt, input) else {
            Log.learning.notice("Style distillation skipped (AI off or failed)")
            return
        }
        let profile = StyleDistiller.clean(output)
        guard !profile.isEmpty else { return }
        store.update { data in
            data.styleProfile = profile
            data.samplesSinceDistill = 0
        }
        Log.learning.info("Style profile updated from \(fresh.count) samples")
    }

    private static func appName(_ bundleID: String?) -> String? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path(percentEncoded: false))
            .replacingOccurrences(of: ".app", with: "")
    }

    /// The misheard side ignores case, the correct side keeps it: "supabase -> Supabase" and its
    /// reversal "Supabase -> supabase" must be two different pairs.
    private static func key(_ pair: TermCorrection) -> String {
        pair.misheard.lowercased() + "\u{1F}" + pair.correct
    }

    private static func samePair(_ a: TermCorrection, _ b: TermCorrection) -> Bool {
        key(a) == key(b)
    }
}
