import Foundation
import Testing
@testable import Captylo

@MainActor
struct LearningStyleTests {
    private let directory: URL
    private let settings: AppSettings
    private let store: LearningStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptyloTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "com.captylo.app.tests.style." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults)
        store = LearningStore(fileURL: directory.appending(path: "learning.json"))
    }

    private func makeLearning(answer: String?) -> (SelfLearning, Recorder) {
        let recorder = Recorder()
        let learning = SelfLearning(
            settings: settings,
            dictionary: DictionaryStore(fileURL: directory.appending(path: "dictionary.json"), paragraphs: false),
            store: store,
            toasts: LearningToasts(),
            isRealWord: { _ in true },
            distill: { system, input in
                recorder.inputs.append(input)
                return answer
            }
        )
        return (learning, recorder)
    }

    @MainActor
    final class Recorder {
        var inputs: [String] = []
    }

    private func addSamples(_ learning: SelfLearning, count: Int) {
        for index in 0..<count {
            learning.learn(
                delivered: "Hej, spotkanie jutro numer \(index).",
                corrected: "Dzień dobry, spotkanie jutro numer \(index).",
                appBundleID: "com.apple.mail"
            )
        }
    }

    @Test func distillationUpdatesTheProfileAndResetsTheCounter() async {
        let (learning, recorder) = makeLearning(answer: "```\n- Zaczynaj od „Dzień dobry”.\n```")
        addSamples(learning, count: 3)
        await learning.distillStyle()
        #expect(store.data.styleProfile == "- Zaczynaj od „Dzień dobry”.")
        #expect(store.data.samplesSinceDistill == 0)
        #expect(recorder.inputs.count == 1)
        #expect(recorder.inputs[0].contains("BEFORE: Hej, spotkanie jutro numer 2."))
        #expect(recorder.inputs[0].contains("CURRENT GUIDE:\n(empty)"))
    }

    @Test func failedCallKeepsTheOldProfile() async {
        let (learning, _) = makeLearning(answer: nil)
        learning.setStyleProfile("- Bez wykrzykników.")
        addSamples(learning, count: 2)
        await learning.distillStyle()
        #expect(store.data.styleProfile == "- Bez wykrzykników.")
        #expect(store.data.samplesSinceDistill == 2)
    }

    @Test func profileReachesThePromptContextOnlyWhileLearningIsOn() {
        let (learning, _) = makeLearning(answer: nil)
        learning.setStyleProfile("- Krótko.")
        #expect(learning.promptContext.style == "- Krótko.")
        settings.learningEnabled = false
        #expect(learning.promptContext == .none)
    }

    @Test func cleanCapsWholeLines() {
        let long = (0..<40).map { "- reguła numer \($0) o stylu pisania" }.joined(separator: "\n")
        let cleaned = StyleDistiller.clean(long)
        #expect(cleaned.count <= StyleDistiller.maxProfileChars)
        #expect(cleaned.hasSuffix("pisania"))
    }
}
