import Foundation

/// Long-lived sessions and small HTTP helpers shared by the cloud modules (gotcha 64).
/// Never create a session per request: the warm TLS / H2 connection is what keeps the
/// cleanup call under the deadline.
enum HTTP {
    /// One session for every dictation LLM call: no cache, no waiting for connectivity.
    /// The real deadline is enforced in Swift (`Enhancer`, the AI mode's 1...20 s), so the
    /// timeouts only sit above the longest mode deadline: a non-streaming rewrite sends nothing
    /// until the whole answer is ready, and a 4 s idle timeout would cut an 8 s mode short.
    static let llmSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 21
        configuration.timeoutIntervalForResource = 25
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    /// LLM session for file transcripts: a non-streaming completion of a long transcript sends
    /// nothing until the whole answer is ready, so the timeouts sit just above the 15 s file deadline.
    static let fileLLMSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 16
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    /// Resource cap for audio uploads. The real per-take deadline (`max(20, 10 + 0.5 * seconds)`)
    /// is enforced in `ElevenLabsSTT`; this only has to stay above it for the longest file
    /// (a 4 h recording needs about 7210 s).
    static let uploadResourceTimeout: TimeInterval = 4 * 3600

    /// Session for audio uploads (cloud STT): longer timeouts, same no-cache policy.
    static let uploadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = uploadResourceTimeout
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    /// Fresh ephemeral session for a one-off retry (a stuck upload gets a new connection).
    static func makeEphemeral() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = uploadResourceTimeout
        return URLSession(configuration: configuration)
    }

    /// Log-friendly preview of a response body: single line, at most 200 characters.
    static func shortBody(_ data: Data) -> String {
        let limit = 200
        let text = String(decoding: data.prefix(limit * 4), as: UTF8.self)
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        if text.count <= limit {
            return text
        }
        return String(text.prefix(limit - 3)) + "..."
    }
}

/// `multipart/form-data` body builder (CRLF line endings, one closing boundary).
struct Multipart: Sendable {
    let boundary: String
    private var parts = Data()

    init() {
        boundary = "Boundary-\(UUID().uuidString)"
    }

    /// Value for the `Content-Type` request header.
    var contentTypeHeader: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// The finished body: every part followed by the closing boundary.
    var body: Data {
        var data = parts
        data.append(string: "--\(boundary)--\r\n")
        return data
    }

    mutating func addField(name: String, value: String) {
        parts.append(string: "--\(boundary)\r\n")
        parts.append(string: "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        parts.append(string: value)
        parts.append(string: "\r\n")
    }

    mutating func addFile(name: String, fileName: String, contentType: String, data: Data) {
        parts.append(string: "--\(boundary)\r\n")
        parts.append(string: "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
        parts.append(string: "Content-Type: \(contentType)\r\n\r\n")
        parts.append(data)
        parts.append(string: "\r\n")
    }
}

private extension Data {
    mutating func append(string: String) {
        append(Data(string.utf8))
    }
}

/// Fire-and-forget connection warm-up, debounced so hotkey mashing does not spam the host.
actor Prewarmer {
    private var lastFired: ContinuousClock.Instant?

    init() {}

    /// Sends `request` at most once per `minInterval`; the response and any error are ignored.
    func fire(_ request: URLRequest, using session: URLSession, minInterval: Duration = .seconds(20)) {
        let now = ContinuousClock.now
        if let lastFired, now - lastFired < minInterval {
            return
        }
        lastFired = now
        Task.detached(priority: .utility) {
            _ = try? await session.data(for: request)
        }
    }
}
