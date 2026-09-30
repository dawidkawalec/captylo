import Foundation
import Testing
@testable import Captylo

struct EnhancementReasoningPolicyTests {
    private let client = OpenRouterClient()

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func disabledPolicySendsEnabledFalse() throws {
        let request = client.chatRequest(model: "openai/gpt-4.1-mini", system: "s", transcript: "t", maxTokens: 10, key: "k")
        let reasoning = try #require(try body(request)["reasoning"] as? [String: Any])
        #expect(reasoning["enabled"] as? Bool == false)
        #expect(reasoning["effort"] == nil)
    }

    @Test func minimalPolicySendsEffortAndExcludeWithoutEnabled() throws {
        let request = client.chatRequest(
            model: "z-ai/glm-5.3-flash", system: "s", transcript: "t", maxTokens: 10, key: "k",
            reasoning: .minimal(effort: "low")
        )
        let reasoning = try #require(try body(request)["reasoning"] as? [String: Any])
        #expect(reasoning["enabled"] == nil)
        #expect(reasoning["effort"] as? String == "low")
        #expect(reasoning["exclude"] as? Bool == true)
    }

    @Test func parseModelsReadsMandatoryReasoning() throws {
        let json = """
        {"data":[
          {"id":"z-ai/glm-5.3-flash","name":"GLM","architecture":{"input_modalities":["text"],"output_modalities":["text"]},
           "supported_parameters":["reasoning"],"reasoning":{"mandatory":true,"supported_efforts":["max","high","low"]}},
          {"id":"openai/gpt-4.1-mini","name":"Mini","architecture":{"input_modalities":["text"],"output_modalities":["text"]}}
        ]}
        """
        let models = try client.parseModels(Data(json.utf8))
        let glm = try #require(models.first { $0.id == "z-ai/glm-5.3-flash" })
        #expect(glm.reasoningMandatory == true)
        #expect(glm.reasoningPolicy == .minimal(effort: "low"))
        let mini = try #require(models.first { $0.id == "openai/gpt-4.1-mini" })
        #expect(mini.reasoningPolicy == .disabled)
    }

    @Test func lowestEffortPrefersCheapest() {
        #expect(ReasoningPolicy.lowestEffort(from: ["max", "high", "low"]) == "low")
        #expect(ReasoningPolicy.lowestEffort(from: ["high", "minimal"]) == "minimal")
        #expect(ReasoningPolicy.lowestEffort(from: []) == "low")
    }

    @Test func lookupUsesCacheAndDefaultsToDisabled() throws {
        let cache = try JSONEncoder().encode([
            OpenRouterModel(id: "a/mandatory", name: "A", reasoningMandatory: true, reasoningEfforts: ["high", "medium"]),
            OpenRouterModel(id: "b/optional", name: "B", supportsReasoning: true, reasoningMandatory: false),
        ])
        #expect(ReasoningPolicy.lookup("a/mandatory", inCache: cache) == .minimal(effort: "medium"))
        #expect(ReasoningPolicy.lookup("b/optional", inCache: cache) == .disabled)
        #expect(ReasoningPolicy.lookup("c/unknown", inCache: cache) == .disabled)
        #expect(ReasoningPolicy.lookup("a/mandatory", inCache: nil) == .disabled)
    }

    @Test func oldCacheWithoutReasoningFieldsStillDecodes() throws {
        let old = #"[{"id":"x/y","name":"X","supportsReasoning":false}]"#
        let models = try JSONDecoder().decode([OpenRouterModel].self, from: Data(old.utf8))
        #expect(models.first?.reasoningMandatory == nil)
    }

    @Test func reasoningRejectionDetection() {
        let body = Data(#"{"error":{"message":"Reasoning is mandatory for this endpoint and cannot be disabled.","code":400}}"#.utf8)
        #expect(Enhancer.isReasoningRejection(status: 400, body: body))
        #expect(!Enhancer.isReasoningRejection(status: 401, body: body))
        #expect(!Enhancer.isReasoningRejection(status: 400, body: Data(#"{"error":{"message":"bad model"}}"#.utf8)))
        #expect(Enhancer.tokens(100, for: .minimal(effort: "low")) == 100 + Enhancer.mandatoryReasoningAllowance)
        #expect(Enhancer.tokens(100, for: .disabled) == 100)
    }
}
