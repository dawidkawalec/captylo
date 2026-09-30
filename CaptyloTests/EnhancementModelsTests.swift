import Foundation
import Testing
@testable import Captylo

@MainActor
struct EnhancementModelsTests {
    private func makeSettings() throws -> AppSettings {
        let suiteName = "com.captylo.app.tests.models.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return AppSettings(defaults: defaults)
    }

    private func makeModels(
        settings: AppSettings,
        _ handler: @escaping StubURLProtocol.Handler
    ) -> (OpenRouterModels, URL) {
        let baseURL = StubURLProtocol.register(handler)
        let models = OpenRouterModels(
            settings: settings,
            client: OpenRouterClient(baseURL: baseURL),
            session: StubURLProtocol.makeSession()
        )
        return (models, baseURL)
    }

    private static let cachedList = [
        OpenRouterModel(id: "cached/model", name: "Cached", promptPrice: 0.000001, completionPrice: 0.000002),
        OpenRouterModel(id: "openai/gpt-4.1-mini", name: "Cached Mini"),
    ]

    @Test func freshCacheIsServedWithoutNetwork() async throws {
        let settings = try makeSettings()
        settings.openRouterModelsCache = try JSONEncoder().encode(Self.cachedList)
        settings.openRouterModelsCachedAt = Date().addingTimeInterval(-60)
        let counter = Counter()
        let (models, baseURL) = makeModels(settings: settings) { _ in
            counter.increment()
            return .json(Fixtures.models)
        }
        defer { StubURLProtocol.unregister(baseURL) }

        await models.refresh()
        #expect(counter.value == 0)
        #expect(models.models == Self.cachedList)
        #expect(models.errorMessage == nil)
        #expect(!models.isLoading)

        await models.refresh(force: true)
        #expect(counter.value == 1)
        #expect(models.models.map(\.id) == ["openai/gpt-4.1-mini", "openai/gpt-oss-120b", "free/no-pricing"])
        let cachedAt = try #require(settings.openRouterModelsCachedAt)
        #expect(abs(cachedAt.timeIntervalSinceNow) < 5)
        let stored = try JSONDecoder().decode([OpenRouterModel].self, from: try #require(settings.openRouterModelsCache))
        #expect(stored == models.models)
    }

    @Test func staleCacheTriggersAFetch() async throws {
        let settings = try makeSettings()
        settings.openRouterModelsCache = try JSONEncoder().encode(Self.cachedList)
        settings.openRouterModelsCachedAt = Date().addingTimeInterval(-OpenRouterModel.cacheMaxAge - 60)
        let counter = Counter()
        let (models, baseURL) = makeModels(settings: settings) { _ in
            counter.increment()
            return .json(Fixtures.models)
        }
        defer { StubURLProtocol.unregister(baseURL) }

        await models.refresh()
        #expect(counter.value == 1)
        #expect(models.models.count == 3)
    }

    @Test func failedFetchKeepsStaleCacheAndReportsError() async throws {
        let settings = try makeSettings()
        settings.openRouterModelsCache = try JSONEncoder().encode(Self.cachedList)
        settings.openRouterModelsCachedAt = Date().addingTimeInterval(-OpenRouterModel.cacheMaxAge - 60)
        let (models, baseURL) = makeModels(settings: settings) { _ in .json("oops", status: 503) }
        defer { StubURLProtocol.unregister(baseURL) }

        await models.refresh()
        #expect(models.models == Self.cachedList)
        #expect(models.errorMessage == OpenRouterError.server(503).errorDescription)
        // The stale cache stays stale: nothing was written.
        #expect(settings.openRouterModelsCachedAt.map { Date().timeIntervalSince($0) > OpenRouterModel.cacheMaxAge } == true)
    }

    @Test func quickPicksAndSearchOrder() async throws {
        let settings = try makeSettings()
        let list = [
            OpenRouterModel(id: "z/last", name: "Zeta"),
            OpenRouterModel(id: "anthropic/claude-haiku-4.5", name: "Anthropic: Claude Haiku 4.5"),
            OpenRouterModel(id: "a/first", name: "alpha"),
            OpenRouterModel(id: "openai/gpt-4.1-mini", name: "OpenAI: GPT-4.1 Mini"),
        ]
        settings.openRouterModelsCache = try JSONEncoder().encode(list)
        settings.openRouterModelsCachedAt = Date()
        let (models, baseURL) = makeModels(settings: settings) { _ in .json(Fixtures.models) }
        defer { StubURLProtocol.unregister(baseURL) }
        await models.refresh()

        #expect(models.quickPicks.map(\.id) == ["openai/gpt-4.1-mini", "anthropic/claude-haiku-4.5"])
        #expect(models.search("").map(\.id) == ["openai/gpt-4.1-mini", "anthropic/claude-haiku-4.5", "a/first", "z/last"])
        #expect(models.search("  ").map(\.id) == models.search("").map(\.id))
        #expect(models.search("HAIKU").map(\.id) == ["anthropic/claude-haiku-4.5"])
        #expect(models.search("a/").map(\.id) == ["a/first"])
        #expect(models.search("nothing").isEmpty)
        #expect(models.isKnown(id: "z/last"))
        #expect(!models.isKnown(id: "missing/model"))
    }

    @Test func displayPriceUsesPolishFormatting() {
        #expect(OpenRouterModels.displayPrice(prompt: 0.0000004, completion: 0.0000016) == "0,40 $ / 1,60 $ za 1M")
        #expect(OpenRouterModels.displayPrice(prompt: 0.000003, completion: 0.000015) == "3,00 $ / 15,00 $ za 1M")
        #expect(OpenRouterModels.displayPrice(prompt: nil, completion: nil) == "-")
        #expect(OpenRouterModels.displayPrice(prompt: 0.0000001, completion: nil) == "0,10 $ / - za 1M")
    }
}
