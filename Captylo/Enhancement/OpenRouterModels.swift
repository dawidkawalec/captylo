import Foundation
import Observation

/// Model list for the Modele tab: served from the 24 h cache in `AppSettings`, refreshed from
/// `GET /models` when stale or forced. Quick picks (docs/architecture.md) come first.
@MainActor
@Observable
final class OpenRouterModels {
    private(set) var models: [OpenRouterModel] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let client: OpenRouterClient
    @ObservationIgnored private let session: URLSession

    init(settings: AppSettings, client: OpenRouterClient, session: URLSession = HTTP.llmSession) {
        self.settings = settings
        self.client = client
        self.session = session
    }

    // MARK: Loading

    /// Uses the cache while it is younger than `OpenRouterModel.cacheMaxAge` unless forced.
    /// A failed fetch keeps the stale cache (if any) and sets `errorMessage`.
    func refresh(force: Bool = false) async {
        let cached = cachedModels()
        if !force, let cached, cached.isFresh {
            models = cached.models
            errorMessage = nil
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (data, response) = try await session.data(for: client.modelsRequest())
            if let http = response as? HTTPURLResponse, let error = OpenRouterClient.mapStatus(http.statusCode) {
                Log.enhancement.error("Models fetch failed: \(http.statusCode) \(HTTP.shortBody(data), privacy: .public)")
                throw error
            }
            let list = try client.parseModels(data)
            models = list
            errorMessage = nil
            settings.openRouterModelsCache = try? JSONEncoder().encode(list)
            settings.openRouterModelsCachedAt = Date()
            Log.enhancement.info("Loaded \(list.count) OpenRouter models")
        } catch let error as OpenRouterError {
            fail(error, stale: cached)
        } catch {
            fail(OpenRouterError.network(error.localizedDescription), stale: cached)
        }
    }

    private func fail(_ error: OpenRouterError, stale: CachedList?) {
        errorMessage = error.errorDescription
        if models.isEmpty, let stale {
            models = stale.models
        }
        Log.enhancement.error("Models refresh failed: \(error.errorDescription ?? "", privacy: .public)")
    }

    // MARK: Queries

    /// Quick picks that exist in the list, in the order of `OpenRouterModel.quickPickIDs`.
    var quickPicks: [OpenRouterModel] {
        OpenRouterModel.quickPickIDs.compactMap { id in models.first { $0.id == id } }
    }

    /// Empty query: quick picks first, then the rest by name. Otherwise id / name contains, case-insensitive.
    func search(_ query: String) -> [OpenRouterModel] {
        let picks = quickPicks
        let pickIDs = Set(picks.map(\.id))
        let rest = models
            .filter { !pickIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let ordered = picks + rest
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return ordered }
        return ordered.filter {
            $0.id.localizedCaseInsensitiveContains(needle) || $0.name.localizedCaseInsensitiveContains(needle)
        }
    }

    func isKnown(id: String) -> Bool {
        models.contains { $0.id == id }
    }

    /// "0,40 $ / 1,60 $ za 1M" (USD per million tokens, formatted in `AppLocale.current`) or "-" when unknown.
    func displayPrice(for model: OpenRouterModel) -> String {
        Self.displayPrice(prompt: model.promptPrice, completion: model.completionPrice)
    }

    nonisolated static func displayPrice(prompt: Double?, completion: Double?) -> String {
        guard prompt != nil || completion != nil else { return "-" }
        let formatter = NumberFormatter()
        formatter.locale = AppLocale.current
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        func part(_ value: Double?) -> String {
            guard let value, let text = formatter.string(from: NSNumber(value: value * 1_000_000)) else { return "-" }
            return "\(text) $"
        }
        return String(localized: "\(part(prompt)) / \(part(completion)) za 1M")
    }

    // MARK: Cache

    private struct CachedList {
        let models: [OpenRouterModel]
        let isFresh: Bool
    }

    private func cachedModels() -> CachedList? {
        guard let data = settings.openRouterModelsCache,
              let list = try? JSONDecoder().decode([OpenRouterModel].self, from: data),
              !list.isEmpty
        else { return nil }
        let age = settings.openRouterModelsCachedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        // Caches written before the reasoning metadata existed lack `reasoningMandatory`; until the
        // next refresh the Enhancer's one-shot retry on a reasoning 400 covers those models.
        return CachedList(models: list, isFresh: age >= 0 && age < OpenRouterModel.cacheMaxAge)
    }
}
