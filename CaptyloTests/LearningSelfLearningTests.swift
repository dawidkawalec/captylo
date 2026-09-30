import Foundation
import Testing
@testable import Captylo

/// Keeps the "Cofnij" actions so a test can press them.
@MainActor
final class LearningToasts: ToastPresenting {
    var infos: [String] = []
    var actions: [(message: String, action: @MainActor () -> Void)] = []

    func showInfo(_ message: String) { infos.append(message) }
    func showError(_ message: String) { infos.append(message) }
    func showAction(message: String, buttonTitle: String, action: @escaping @MainActor () -> Void) {
        actions.append((message, action))
    }
}

@MainActor
struct LearningSelfLearningTests {
    private static let suiteName = "com.captylo.app.tests.learning"
    private static let realWords: Set<String> = [
        "wrzucam", "to", "na", "w", "piątek", "super", "kot", "brzęk", "hej", "dzień", "dobry", "serwer",
    ]

    private let directory: URL
    private let settings: AppSettings
    private let dictionary: DictionaryStore
    private let store: LearningStore
    private let toasts = LearningToasts()
    private let learning: SelfLearning

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptyloTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // One suite per test: Swift Testing runs them in parallel.
        let suite = Self.suiteName + "." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        settings = AppSettings(defaults: defaults)
        dictionary = DictionaryStore(fileURL: directory.appending(path: "dictionary.json"), paragraphs: false)
        store = LearningStore(fileURL: directory.appending(path: "learning.json"))
        learning = SelfLearning(
            settings: settings,
            dictionary: dictionary,
            store: store,
            toasts: toasts,
            isRealWord: { Self.realWords.contains($0.lowercased()) }
        )
    }

    private func correct() {
        learning.learn(
            delivered: "Wrzucam to na supa bejs w piątek.",
            corrected: "Wrzucam to na Supabase w piątek.",
            appBundleID: "com.apple.Notes"
        )
    }

    @Test func learningIsOnByDefault() {
        #expect(settings.learningEnabled)
    }

    @Test func firstEditLearnsARule() throws {
        correct()
        let entry = try #require(store.data.learned.first)
        #expect(entry.pair == TermCorrection(misheard: "supa bejs", correct: "Supabase"))
        #expect(entry.ruleID != nil)
        #expect(dictionary.containsVocabulary("Supabase"))
        #expect(dictionary.processor.process("wrzucam na supa bejs", language: "pl") == "wrzucam na Supabase")
        #expect(toasts.actions.first?.message == "Zapamiętałem: supa bejs → Supabase")
        #expect(store.data.candidates.isEmpty)

        // The same fix again is a no-op, not a second lesson.
        correct()
        #expect(store.data.learned.count == 1)
        #expect(toasts.actions.count == 1)
    }

    @Test func spelledWordIsLearnedAtOnce() {
        learning.learn(spelled: [SpellingDetector.Spelled(heard: "Honho", spelled: "Honcho")])
        #expect(store.data.learned.count == 1)
        #expect(dictionary.data.replacements.first?.triggers == ["Honho"])
    }

    @Test func spelledWordHeardRightOnlyJoinsTheVocabulary() {
        learning.learn(spelled: [SpellingDetector.Spelled(heard: "Brzęk", spelled: "Brzęk")])
        #expect(dictionary.containsVocabulary("Brzęk"))
        #expect(store.data.learned.isEmpty)
        #expect(dictionary.data.replacements.isEmpty)
        #expect(toasts.infos == ["Dodano do słownika: Brzęk"])
    }

    @Test func realWordIsNeverATrigger() {
        learning.learn(spelled: [SpellingDetector.Spelled(heard: "kot", spelled: "Kod")])
        #expect(dictionary.data.replacements.isEmpty)
        #expect(learning.promptHints == [TermCorrection(misheard: "kot", correct: "Kod")])
    }

    @Test func undoRemovesTheRuleAndBlocksThePair() {
        correct()
        toasts.actions.first?.action()
        #expect(store.data.learned.isEmpty)
        #expect(dictionary.data.replacements.isEmpty)
        #expect(!dictionary.containsVocabulary("Supabase"))

        correct()
        #expect(store.data.learned.isEmpty)
        #expect(store.data.blocked.count == 1)
    }

    @Test func correctingBackTwiceForgetsTheLesson() throws {
        correct()
        correct()
        let reverted = { learning.learn(delivered: "Wrzucam to na Supabase w piątek.", corrected: "Wrzucam to na supa bejs w piątek.", appBundleID: nil) }

        reverted()
        let entry = try #require(store.data.learned.first)
        #expect(entry.ruleID == nil)
        #expect(entry.reverts == 1)
        #expect(dictionary.data.replacements.isEmpty)

        reverted()
        #expect(store.data.learned.isEmpty)
    }

    @Test func switchedOffLearnsNothing() {
        settings.learningEnabled = false
        correct()
        correct()
        learning.learn(spelled: [SpellingDetector.Spelled(heard: "Honho", spelled: "Honcho")])
        #expect(store.data == .empty)
        #expect(dictionary.data.vocabulary.isEmpty)
        #expect(learning.promptHints.isEmpty)
    }

    @Test func correctionRateNeedsEnoughWordsAndCountsUntouchedPastes() throws {
        let sentence = "Wrzucam to na supa bejs w piątek."
        correct()
        #expect(learning.correctionRate() == nil)
        for _ in 0..<7 {
            learning.learn(delivered: sentence, corrected: sentence, appBundleID: nil)
        }
        // 8 pastes x 7 words, 2 words changed once.
        let rate = try #require(learning.correctionRate())
        #expect(abs(rate - 200.0 / 56.0) < 0.001)
    }

    @Test func notificationsOffStillLearnsQuietly() {
        settings.learningNotifications = false
        learning.learn(spelled: [SpellingDetector.Spelled(heard: "Honho", spelled: "Honcho")])
        learning.learn(spelled: [SpellingDetector.Spelled(heard: "Brzęk", spelled: "Brzęk")])
        #expect(store.data.learned.count == 1)
        #expect(dictionary.containsVocabulary("Brzęk"))
        #expect(toasts.actions.isEmpty)
        #expect(toasts.infos.isEmpty)
    }

    @Test func watcherExcludesBuiltInAndUserApps() {
        settings.learningExcludedApps = ["com.tinyspeck.slackmacgap"]
        let watcher = EditWatcher(learning: learning, isEnabled: { true }, userExcluded: { settings.learningExcludedApps })
        #expect(watcher.isExcluded("com.1password.1password"))
        #expect(watcher.isExcluded("com.apple.Terminal"))
        #expect(watcher.isExcluded("com.tinyspeck.slackmacgap"))
        #expect(!watcher.isExcluded("com.apple.mail"))
        #expect(!watcher.isExcluded(nil))
    }

    @Test func styleEditsAreKeptAsSamples() {
        learning.learn(
            delivered: "Hej, wrzucam to na super serwer w piątek.",
            corrected: "Dzień dobry, wrzucam to na super serwer w piątek.",
            appBundleID: "com.apple.mail"
        )
        #expect(store.data.styleSamples.count == 1)
        #expect(store.data.styleSamples.first?.appBundleID == "com.apple.mail")
        #expect(store.data.samplesSinceDistill == 1)
    }

    @Test func memorySurvivesARelaunch() {
        correct()
        correct()
        let reloaded = LearningStore(fileURL: directory.appending(path: "learning.json"))
        #expect(reloaded.data.learned.count == 1)
    }

    @Test func resetAllCleansTheDictionary() {
        correct()
        correct()
        learning.resetAll()
        #expect(store.data == .empty)
        #expect(dictionary.data.replacements.isEmpty)
        #expect(dictionary.data.vocabulary.isEmpty)
    }
}
