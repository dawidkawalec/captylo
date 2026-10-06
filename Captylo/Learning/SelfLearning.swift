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
        guard !analysis.isNoise else {
            observe(LearningObservation(appBundleID: appBundleID, source: .edit, before: delivered, after: corrected, outcome: .skipped, reason: .rewrite))
            return
        }
        recordEditStats(analysis)
        for term in analysis.terms {
            let result = consider(term, source: .edit)
            observe(result.observation(of: term, appBundleID: appBundleID, source: .edit))
        }
        for change in analysis.skipped {
            observe(LearningObservation(appBundleID: appBundleID, source: .edit, before: change.old, after: change.new, outcome: .skipped, reason: change.reason))
        }
        if analysis.isStyle {
            addStyleSample(delivered: delivered, corrected: corrected, appBundleID: appBundleID)
        }
    }

    /// The edit watcher could not read the field Captylo pasted into: listed once per app every
    /// `unreadableRepeat`, so "Ostatnio zauważone" says which apps hide their text.
    func noteUnreadable(appBundleID: String?) {
        guard isEnabled else { return }
        let now = Date()
        let recent = store.data.observations.contains {
            $0.reason == .unreadable && $0.appBundleID == appBundleID && now.timeIntervalSince($0.date) < Self.unreadableRepeat
        }
        guard !recent else { return }
        observe(LearningObservation(date: now, appBundleID: appBundleID, source: .edit, before: "", after: "", outcome: .skipped, reason: .unreadable))
    }

    // MARK: - "Popraw"

    /// What "Popraw" would do with this change, for the live line under the text field.
    enum ManualPreview: Equatable {
        case unchanged
        /// Replaced, not learned: other words or a reworded sentence.
        case rewrite
        /// Replaced, and these pairs are learned (`rule`: at least one becomes a replacement rule).
        case learn([TermCorrection], rule: Bool)
        /// Replaced; every pair is already learned.
        case known([TermCorrection])
        /// Replaced; learning is off in Ustawienia.
        case off
    }

    func preview(original: String, corrected: String) -> ManualPreview {
        let verdict = CorrectionLearner.manual(original: original, corrected: corrected, isRealWord: isRealWord)
        switch verdict {
        case .unchanged: return .unchanged
        // Learning off: only replaced, and nothing lands in "Ostatnio zauważone" either.
        case _ where !isEnabled: return .off
        case .rewrite: return .rewrite
        case .terms(let pairs):
            let fresh = pairs.filter { pair in !store.data.learned.contains { Self.samePair($0.pair, pair) } }
            return fresh.isEmpty ? .known(pairs) : .learn(fresh, rule: fresh.contains(where: canReplace))
        }
    }

    /// "Popraw" was confirmed: learns the pairs at once (the user said outright the text was
    /// wrong, so a pair undone before is unblocked and a reversed lesson is replaced). The
    /// "Zapamiętałem ... [Cofnij]" toast comes from `apply`; the caller says the rest.
    @discardableResult
    func learnManual(original: String, corrected: String, appBundleID: String?) -> ManualPreview {
        let result = preview(original: original, corrected: corrected)
        switch result {
        case .unchanged, .off:
            break
        case .rewrite:
            observe(LearningObservation(appBundleID: appBundleID, source: .manual, before: original, after: corrected, outcome: .skipped, reason: .rewrite))
        case .known(let pairs):
            for pair in pairs {
                observe(LearningObservation(appBundleID: appBundleID, source: .manual, before: pair.misheard, after: pair.correct, outcome: .skipped, reason: .alreadyKnown))
            }
        case .learn(let pairs, _):
            for pair in pairs {
                unblock(pair)
                if let reversed = store.data.learned.first(where: { Self.samePair($0.pair, TermCorrection(misheard: pair.correct, correct: pair.misheard)) }) {
                    undo(reversed.id, block: false)
                }
                let result = consider(pair, source: .manual)
                observe(result.observation(of: pair, appBundleID: appBundleID, source: .manual))
            }
        }
        return result
    }

    /// Słownik "Odblokuj": the pair can be learned again.
    func unblock(_ pair: TermCorrection) {
        guard store.data.blocked.contains(where: { Self.samePair($0, pair) }) else { return }
        store.update { data in
            data.blocked.removeAll { Self.samePair($0, pair) }
        }
    }

    func isBlocked(_ pair: TermCorrection) -> Bool {
        store.data.blocked.contains { Self.samePair($0, pair) }
    }

    /// Słownik "Wyczyść listę" under "Ostatnio zauważone".
    func clearObservations() {
        store.update { $0.observations = [] }
    }

    // MARK: - Observations

    /// Entries kept for "Ostatnio zauważone".
    static let maxObservations = 40
    /// An app that hides its text is listed again after this long.
    static let unreadableRepeat: TimeInterval = 6 * 3600

    private func observe(_ observation: LearningObservation?) {
        guard let observation else { return }
        store.update { data in
            data.observations.append(observation)
            if data.observations.count > Self.maxObservations {
                data.observations.removeFirst(data.observations.count - Self.maxObservations)
            }
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

    /// What `consider` did with one pair.
    private enum Consideration {
        case learned(LearnedTerm)
        case alreadyKnown
        case blocked
        /// The user changed a learned form back (rule dropped or lesson forgotten).
        case reverted
        /// Seen, not learned yet (below `threshold`).
        case candidate

        func observation(of pair: TermCorrection, appBundleID: String?, source: CorrectionSource) -> LearningObservation? {
            let outcome: LearningObservation.Outcome
            var reason: LearningSkipReason?
            switch self {
            case .learned(let entry): outcome = entry.ruleID != nil ? .rule : .hint
            case .alreadyKnown: outcome = .skipped; reason = .alreadyKnown
            case .blocked: outcome = .skipped; reason = .blocked
            case .reverted, .candidate: return nil
            }
            return LearningObservation(appBundleID: appBundleID, source: source, before: pair.misheard, after: pair.correct, outcome: outcome, reason: reason)
        }
    }

    @discardableResult
    private func consider(_ pair: TermCorrection, source: CorrectionSource) -> Consideration {
        let data = store.data
        guard !data.blocked.contains(where: { Self.samePair($0, pair) }) else { return .blocked }
        guard !data.learned.contains(where: { Self.samePair($0.pair, pair) }) else { return .alreadyKnown }

        // The user changed a learned form back: first time drop the rule, second time forget it.
        if let learned = data.learned.first(where: { Self.samePair($0.pair, TermCorrection(misheard: pair.correct, correct: pair.misheard)) }) {
            revert(learned)
            return .reverted
        }

        let needed = source != .edit || dictionary.containsVocabulary(pair.correct) ? 1 : Self.threshold
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
            return .candidate
        }
        return .learned(apply(pair, source: source))
    }

    @discardableResult
    private func apply(_ pair: TermCorrection, source: CorrectionSource) -> LearnedTerm {
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
        // "Popraw" always confirms: the user just asked for it.
        guard settings.learningNotifications || source == .manual else { return entry }
        let id = entry.id
        toasts.showAction(
            message: String(localized: "Zapamiętałem: \(pair.misheard) → \(pair.correct)"),
            buttonTitle: String(localized: "Cofnij"),
            action: { [weak self] in self?.undo(id) }
        )
        return entry
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
