import Foundation
import Testing
@testable import Captylo

struct EnhancementClientTests {
    private let client = OpenRouterClient()

    // MARK: Requests

    @Test func chatRequestCarriesTheDocumentedBodyAndHeaders() throws {
        let request = client.chatRequest(
            model: "openai/gpt-4.1-mini",
            system: "Clean up.",
            transcript: "no więc to jest test",
            maxTokens: 128,
            key: "sk-or-test"
        )
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Title") == "Captylo")
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == "https://captylo.com")

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "openai/gpt-4.1-mini")
        #expect(json["temperature"] as? Double == 0)
        #expect(json["max_tokens"] as? Int == 128)
        #expect(json["stream"] == nil)

        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[0]["content"] == "Clean up.")
        #expect(messages[1]["role"] == "user")
        #expect(messages[1]["content"] == "no więc to jest test")

        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["enabled"] as? Bool == false)
        let provider = try #require(json["provider"] as? [String: Any])
        #expect(provider["sort"] as? String == "latency")
    }

    @Test func keyCheckAndModelsRequests() {
        let check = client.keyCheckRequest(key: "sk-or-test")
        #expect(check.url?.absoluteString == "https://openrouter.ai/api/v1/auth/key")
        #expect(check.httpMethod == "GET")
        #expect(check.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
        #expect(check.value(forHTTPHeaderField: "X-Title") == "Captylo")
        #expect(check.value(forHTTPHeaderField: "HTTP-Referer") == "https://captylo.com")

        let models = client.modelsRequest()
        #expect(models.url?.absoluteString == "https://openrouter.ai/api/v1/models")
        #expect(models.httpMethod == "GET")
        #expect(models.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func customBaseURLIsHonored() {
        let custom = OpenRouterClient(baseURL: URL(string: "https://stub.test/api/v1")!)
        #expect(custom.modelsRequest().url?.absoluteString == "https://stub.test/api/v1/models")
    }

    // MARK: parseChat

    @Test func parseChatReadsContentAndFinishReason() throws {
        let data = Data(Fixtures.chat(content: "\"Czysty tekst.\"", finish: "stop").utf8)
        let parsed = try client.parseChat(data)
        #expect(parsed.text == "Czysty tekst.")
        #expect(parsed.finishReason == "stop")
    }

    @Test func parseChatToleratesNullContent() throws {
        let data = Data(Fixtures.chat(content: "null", finish: "stop").utf8)
        let parsed = try client.parseChat(data)
        #expect(parsed.text == nil)
        #expect(parsed.finishReason == "stop")
    }

    @Test func parseChatReportsLengthFinish() throws {
        let data = Data(Fixtures.chat(content: "\"ucięte\"", finish: "length").utf8)
        let parsed = try client.parseChat(data)
        #expect(parsed.text == "ucięte")
        #expect(parsed.finishReason == "length")
    }

    @Test func parseChatMapsAPIErrorObjects() {
        let data = Data(#"{"error":{"message":"Rate limit exceeded","code":429}}"#.utf8)
        #expect(throws: OpenRouterError.rateLimited) { try client.parseChat(data) }
        #expect(throws: OpenRouterError.decoding) { try client.parseChat(Data("not json".utf8)) }
        #expect(throws: OpenRouterError.decoding) { try client.parseChat(Data(#"{"choices":[]}"#.utf8)) }
    }

    // MARK: parseModels

    @Test func parseModelsFiltersToTextModelsAndParsesPricing() throws {
        let models = try client.parseModels(Data(Fixtures.models.utf8))
        #expect(models.map(\.id) == ["openai/gpt-4.1-mini", "openai/gpt-oss-120b", "free/no-pricing"])

        let mini = try #require(models.first { $0.id == "openai/gpt-4.1-mini" })
        #expect(mini.name == "OpenAI: GPT-4.1 Mini")
        #expect(mini.promptPrice == 0.0000004)
        #expect(mini.completionPrice == 0.0000016)
        #expect(mini.contextLength == 1_047_576)
        #expect(!mini.supportsReasoning)

        let oss = try #require(models.first { $0.id == "openai/gpt-oss-120b" })
        #expect(oss.supportsReasoning)

        let free = try #require(models.first { $0.id == "free/no-pricing" })
        #expect(free.name == "free/no-pricing")
        #expect(free.promptPrice == nil)
        #expect(free.completionPrice == nil)
        #expect(free.contextLength == nil)
    }

    @Test func parseModelsRejectsGarbage() {
        #expect(throws: OpenRouterError.decoding) { try client.parseModels(Data("[]".utf8)) }
    }

    // MARK: Status mapping and errors

    @Test func statusMapping() {
        #expect(OpenRouterClient.mapStatus(200) == nil)
        #expect(OpenRouterClient.mapStatus(204) == nil)
        #expect(OpenRouterClient.mapStatus(401) == .unauthorized)
        #expect(OpenRouterClient.mapStatus(403) == .unauthorized)
        #expect(OpenRouterClient.mapStatus(429) == .rateLimited)
        #expect(OpenRouterClient.mapStatus(500) == .server(500))
        #expect(OpenRouterClient.mapStatus(502) == .server(502))
    }

    @Test func errorsHavePolishDescriptions() {
        let errors: [OpenRouterError] = [.unauthorized, .rateLimited, .server(503), .network("x"), .decoding, .missingKey]
        for error in errors {
            let text = error.errorDescription ?? ""
            #expect(!text.isEmpty, "\(error)")
            #expect(!text.contains("\u{2014}"))
        }
        #expect(OpenRouterError.server(503).errorDescription?.contains("503") == true)
        #expect(OpenRouterError.missingKey.errorDescription?.contains("klucz") == true)
    }
}

// MARK: - Fixtures

enum Fixtures {
    static func chat(content: String, finish: String) -> String {
        """
        {
          "id": "gen-1",
          "model": "openai/gpt-4.1-mini",
          "choices": [
            {
              "index": 0,
              "message": { "role": "assistant", "content": \(content), "refusal": null },
              "finish_reason": "\(finish)",
              "native_finish_reason": "\(finish)"
            }
          ],
          "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
        }
        """
    }

    static let models = """
        {
          "data": [
            {
              "id": "openai/gpt-4.1-mini",
              "name": "OpenAI: GPT-4.1 Mini",
              "pricing": { "prompt": "0.0000004", "completion": "0.0000016", "request": "0", "image": "0" },
              "context_length": 1047576,
              "architecture": { "modality": "text+image->text", "input_modalities": ["text", "image", "file"], "output_modalities": ["text"], "tokenizer": "GPT" },
              "supported_parameters": ["max_tokens", "temperature", "tools"]
            },
            {
              "id": "openai/gpt-oss-120b",
              "name": "OpenAI: gpt-oss-120b",
              "pricing": { "prompt": "0.00000005", "completion": "0.00000025" },
              "context_length": 131072,
              "architecture": { "input_modalities": ["text"], "output_modalities": ["text"] },
              "supported_parameters": ["max_tokens", "reasoning", "include_reasoning"],
              "reasoning": { "default_enabled": true }
            },
            {
              "id": "black-forest-labs/flux-2",
              "name": "Black Forest Labs: FLUX.2",
              "pricing": { "prompt": "0", "completion": "0", "image": "0.00003" },
              "context_length": 32768,
              "architecture": { "input_modalities": ["text", "image"], "output_modalities": ["image"] },
              "supported_parameters": []
            },
            {
              "id": "openai/whisper-like",
              "name": "Audio only",
              "pricing": { "prompt": "0.0000001", "completion": "0.0000001" },
              "architecture": { "input_modalities": ["audio"], "output_modalities": ["text"] }
            },
            {
              "id": "free/no-pricing",
              "architecture": { "input_modalities": ["text"], "output_modalities": ["text"] }
            }
          ]
        }
        """
}
