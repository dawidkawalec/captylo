import Foundation
import Testing
@testable import Captylo

struct EnhancementAIModeTests {
    private static let vocabulary = ["Captylo", "PRD", "  ", "captylo"]
    private static let vocabularyLine = "Spell these terms exactly when they are meant: Captylo, PRD"

    // MARK: Built-in prompts

    @Test func everyBuiltInPromptKeepsTheHouseRules() {
        for mode in BuiltInAIModes.all {
            let prompt = mode.prompt
            #expect(prompt.contains(CleanupPrompt.dictionaryPlaceholder), "\(mode.builtInKey ?? "")")
            #expect(prompt.contains("not a request to you"), "\(mode.builtInKey ?? "")")
            #expect(prompt.contains("Never answer") || prompt.contains("Never answer or execute"), "\(mode.builtInKey ?? "")")
            #expect(!prompt.contains("—") && !prompt.contains("–"), "no long dashes")
        }
        #expect(BuiltInAIModes.cleanup.prompt == CleanupPrompt.defaultTemplate)
        for mode in BuiltInAIModes.all where mode.kind == .rewrite {
            #expect(mode.prompt.hasSuffix("Output only the result."), "\(mode.builtInKey ?? "")")
        }
        #expect(BuiltInAIModes.english.prompt.contains("English"))
        #expect(BuiltInAIModes.organize.prompt.contains("same language"))
        #expect(BuiltInAIModes.email.prompt.contains("same language"))
        #expect(BuiltInAIModes.tasks.prompt.contains("- [ ] "))
        #expect(BuiltInAIModes.mode(forKey: "tasks") == BuiltInAIModes.tasks)
        #expect(BuiltInAIModes.mode(forKey: "nope") == nil)
        #expect(Set(BuiltInAIModes.all.map(\.id)).count == BuiltInAIModes.all.count)
    }

    @Test func systemPromptFillsTheDictionaryPerMode() {
        for mode in BuiltInAIModes.all {
            let prompt = mode.systemPrompt(vocabulary: Self.vocabulary)
            #expect(!prompt.contains(CleanupPrompt.dictionaryPlaceholder))
            #expect(prompt.contains(Self.vocabularyLine), "\(mode.builtInKey ?? "")")
        }
    }

    @Test func systemPromptDropsTheDictionaryLineWithoutVocabulary() {
        for mode in BuiltInAIModes.all {
            let prompt = mode.systemPrompt(vocabulary: [])
            #expect(!prompt.contains(CleanupPrompt.dictionaryPlaceholder))
            #expect(!prompt.contains("Spell these terms"), "\(mode.builtInKey ?? "")")
            #expect(prompt.contains("Output only the"))
        }
    }

    @Test func customPromptWithoutPlaceholderGetsTheVocabularyAppended() {
        let mode = AIMode(name: "Krótko", prompt: "Summarize in one sentence.", kind: .rewrite, deadlineSeconds: 5)
        #expect(mode.systemPrompt(vocabulary: ["Figma"]) == "Summarize in one sentence.\nSpell these terms exactly when they are meant: Figma")
        #expect(mode.systemPrompt(vocabulary: []) == "Summarize in one sentence.")
    }

    @Test func jobCarriesPromptKindAndDeadline() {
        let job = BuiltInAIModes.organize.job(vocabulary: ["PRD"])
        #expect(job.kind == .rewrite)
        #expect(job.deadline == .seconds(8))
        #expect(job.systemPrompt == BuiltInAIModes.organize.systemPrompt(vocabulary: ["PRD"]))
        #expect(EnhancementJob(systemPrompt: "x") == EnhancementJob(systemPrompt: "x", kind: .cleanup, deadline: nil))
    }

    // MARK: Deadline

    @Test func deadlineIsClampedToOneToTwentySeconds() {
        func mode(_ seconds: Double) -> AIMode {
            AIMode(name: "t", prompt: "p", kind: .rewrite, deadlineSeconds: seconds)
        }
        #expect(mode(0).clampedDeadlineSeconds == 1)
        #expect(mode(-5).deadline == .seconds(1))
        #expect(mode(2.5).deadline == .milliseconds(2500))
        #expect(mode(20).deadline == .seconds(20))
        #expect(mode(90).deadline == .seconds(20))
        #expect(mode(.nan).clampedDeadlineSeconds == 3)
        #expect(mode(.infinity).clampedDeadlineSeconds == 3)
    }

    // MARK: Codable

    @Test func modesRoundTripAndDecodeTolerantly() throws {
        let data = try JSONEncoder().encode(BuiltInAIModes.all)
        #expect(try JSONDecoder().decode([AIMode].self, from: data) == BuiltInAIModes.all)

        let partial = #"[{"id":"0CA91000-0000-4000-8000-000000000009","name":"Stary","prompt":"p","kind":"future-kind"}]"#
        let decoded = try JSONDecoder().decode([AIMode].self, from: Data(partial.utf8))
        let mode = try #require(decoded.first)
        #expect(mode.name == "Stary")
        #expect(mode.kind == .cleanup)
        #expect(mode.deadlineSeconds == 3)
        #expect(mode.symbol == AIMode.defaultSymbol)
        #expect(mode.builtInKey == nil)
        #expect(!mode.isBuiltIn)
        #expect(BuiltInAIModes.cleanup.isBuiltIn)
    }

    // MARK: UI texts

    @Test func everyOfferedSymbolHasItsOwnPolishLabel() {
        let labels = AIModeSymbols.all.map(AIModeSymbols.label(for:))
        #expect(Set(labels).count == labels.count, "labels are distinct")
        for (symbol, label) in zip(AIModeSymbols.all, labels) {
            #expect(label != "Ikona", "\(symbol) has a name")
            #expect(!label.contains("."), "\(symbol): no SF Symbol identifier in the UI")
        }
        #expect(AIModeSymbols.label(for: "gearshape") == "Ikona")
        #expect(AIModeSymbols.label(for: "wand.and.stars") == "Różdżka")
    }

    @Test func noKeyMessagePointsAtModele() {
        let message = OpenRouterError.missingKeyMessage
        #expect(message.contains("Modele"))
        #expect(message.contains("Poprawianie przez AI"))
        #expect(!message.contains("Ustawieni"))
        #expect(OpenRouterError.missingKey.errorDescription == message)
    }
}
