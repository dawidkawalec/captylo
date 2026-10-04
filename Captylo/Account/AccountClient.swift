import Darwin
import Foundation

/// REST client of the Captylo account server (`https://api.captylo.com/v1`; `CAPTYLO_API_BASE`
/// points it at a local server). Pure request builders and parsers, tested with fixtures, plus one
/// `send` over `URLSession`. Every failure comes out as an `AccountError`.
struct AccountClient: Sendable {
    static let defaultBaseURL = URL(string: "https://api.captylo.com/v1")!
    static let environmentKey = "CAPTYLO_API_BASE"

    let baseURL: URL
    let session: URLSession

    init(baseURL: URL = AccountClient.resolveBaseURL(), session: URLSession = HTTP.accountSession) {
        self.baseURL = baseURL
        self.session = session
    }

    /// `CAPTYLO_API_BASE` when it is an http(s) URL with a host (trailing slash dropped),
    /// otherwise the production API.
    static func resolveBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        guard var text = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return defaultBaseURL
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty else {
            return defaultBaseURL
        }
        return url
    }

    // MARK: Calls

    /// `POST auth/code`: the server mails a 6-digit code (204 for every address).
    func requestCode(email: String) async throws {
        _ = try await send("auth/code", method: "POST", token: nil, json: CodeBody(email: email))
    }

    /// `POST auth/verify`: a session token and the account.
    func verify(email: String, code: String, device: String) async throws -> (token: String, me: AccountInfo) {
        let data = try await send("auth/verify", method: "POST", token: nil, json: VerifyBody(email: email, code: code, device: device))
        return try Self.parseVerify(data)
    }

    /// `GET me`.
    func me(token: String) async throws -> AccountInfo {
        try Self.parseMe(await send("me", method: "GET", token: token, json: nil))
    }

    /// `POST auth/logout`: revokes the session on the server.
    func logout(token: String) async throws {
        _ = try await send("auth/logout", method: "POST", token: token, json: nil)
    }

    /// `POST billing/checkout`: the hosted Checkout page for the signed-in account.
    func checkoutURL(token: String, plan: BillingPlan) async throws -> URL {
        try Self.parseURL(await send("billing/checkout", method: "POST", token: token, json: CheckoutBody(plan: plan)))
    }

    /// `POST billing/portal`: the subscription management page.
    func portalURL(token: String) async throws -> URL {
        try Self.parseURL(await send("billing/portal", method: "POST", token: token, json: nil))
    }

    private func send(_ path: String, method: String, token: String?, json: (any Encodable)?) async throws -> Data {
        let request = try Self.makeRequest(baseURL: baseURL, path: path, method: method, token: token, json: json)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let mapped = Self.mapTransport(error)
            Log.account.notice("Account call \(path, privacy: .public) failed: \(mapped.logName, privacy: .public)")
            throw mapped
        }
        guard let http = response as? HTTPURLResponse else {
            throw AccountError.serverUnavailable
        }
        if let error = Self.mapStatus(http.statusCode, body: data) {
            Log.account.notice("Account call \(path, privacy: .public) answered \(http.statusCode): \(error.logName, privacy: .public)")
            throw error
        }
        return data
    }

    // MARK: Request bodies

    private struct CodeBody: Encodable {
        let email: String
    }

    private struct VerifyBody: Encodable {
        let email: String
        let code: String
        let device: String
    }

    private struct CheckoutBody: Encodable {
        let plan: BillingPlan
    }

    // MARK: Pure builders and parsers

    static func makeRequest(baseURL: URL, path: String, method: String, token: String?, json: (any Encodable)?) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            request.httpBody = try JSONEncoder().encode(json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    static func parseMe(_ data: Data) throws -> AccountInfo {
        try decode(AccountInfo.self, from: data)
    }

    static func parseVerify(_ data: Data) throws -> (token: String, me: AccountInfo) {
        struct Answer: Decodable {
            let token: String
            let me: AccountInfo
        }
        let answer = try decode(Answer.self, from: data)
        guard !answer.token.isEmpty else { throw AccountError.serverUnavailable }
        return (answer.token, answer.me)
    }

    /// `{ "url": "https://..." }`; only http(s) links are ever opened.
    static func parseURL(_ data: Data) throws -> URL {
        struct Answer: Decodable {
            let url: String
        }
        let answer = try decode(Answer.self, from: data)
        guard let url = URL(string: answer.url),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host() != nil else {
            throw AccountError.serverUnavailable
        }
        return url
    }

    /// nil for a 2xx; otherwise the error the status and the body's `error` code mean.
    static func mapStatus(_ code: Int, body: Data) -> AccountError? {
        if (200..<300).contains(code) {
            return nil
        }
        struct Problem: Decodable {
            let error: String?
            let resetsAt: String?
        }
        let problem = try? JSONDecoder().decode(Problem.self, from: body)
        switch (code, problem?.error) {
        case (400, "invalid_code"): return .invalidCode
        case (400, _): return .invalidEmail
        case (401, _): return .unauthorized
        case (402, _): return .quotaExceeded(resetsAt: problem?.resetsAt.flatMap(parseDate))
        case (404, "no_customer"): return .noCustomer
        case (409, "already_pro"): return .alreadyPro
        case (409, "payment_pending"): return .paymentPending
        case (502, "mail_failed"): return .mailFailed
        default: return .serverUnavailable
        }
    }

    /// No network at all is `.offline`; a server that does not answer is `.serverUnavailable`.
    static func mapTransport(_ error: any Error) -> AccountError {
        if let error = error as? AccountError {
            return error
        }
        guard let urlError = error as? URLError else {
            return .serverUnavailable
        }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return .offline
        default:
            return .serverUnavailable
        }
    }

    // MARK: Cache

    /// `AccountInfo` as the JSON string kept in `AppSettings.accountCache`.
    static func encodeCache(_ info: AccountInfo) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return String(decoding: try encoder.encode(info), as: UTF8.self)
    }

    static func decodeCache(_ text: String) throws -> AccountInfo {
        try decode(AccountInfo.self, from: Data(text.utf8))
    }

    static func decodeCacheOrNil(_ text: String?) -> AccountInfo? {
        guard let text else { return nil }
        return try? decodeCache(text)
    }

    // MARK: Device

    /// What the server stores as the session's device: the Mac's model identifier
    /// (`Mac14,2`), never the computer name, which often carries the owner's name.
    static func deviceName() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return "Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "Mac" }
        let model = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? "Mac" : String(model.prefix(64))
    }

    // MARK: Helpers

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date")
            }
            return date
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Log.account.error("Account answer could not be decoded: \(String(describing: type), privacy: .public)")
            throw AccountError.serverUnavailable
        }
    }

    /// ISO 8601 with or without fractional seconds (`toISOString()` writes milliseconds).
    static func parseDate(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(text, strategy: .iso8601)
    }
}
