import Foundation
import os
@testable import Captylo

/// URLProtocol stub keyed by the `xi-api-key` header (own key) or the bearer token (the relay),
/// so parallel tests never share a handler.
final class TranscriptionStubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (status: Int, body: Data)

    private static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])

    static func register(key: String, _ handler: @escaping Handler) {
        handlers.withLock { $0[key] = handler }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranscriptionStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func json(_ status: Int, _ json: String) -> Handler {
        { _ in (status, Data(json.utf8)) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let bearer = request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) }
        let key = request.value(forHTTPHeaderField: "xi-api-key") ?? bearer ?? ""
        guard let handler = Self.handlers.withLock({ $0[key] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (status, body) = try handler(request)
            let url = request.url ?? URL(string: "https://stub.invalid")!
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Fake local engine: fixed text or a fixed error, counts calls.
final class TranscriptionFakeLocalTranscriber: LocalTranscribing, Sendable {
    private struct Counters {
        var transcribe = 0
        var preview = 0
    }

    private let text: String
    private let failure: DictationError?
    private let counters = OSAllocatedUnfairLock(initialState: Counters())

    init(text: String, failure: DictationError? = nil) {
        self.text = text
        self.failure = failure
    }

    var transcribeCalls: Int { counters.withLock { $0.transcribe } }
    var previewCalls: Int { counters.withLock { $0.preview } }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        counters.withLock { $0.transcribe += 1 }
        if let failure { throw failure }
        return text
    }

    func preview(_ tail: [Float], language: String?) async throws -> String {
        counters.withLock { $0.preview += 1 }
        if let failure { throw failure }
        return text
    }
}

enum TranscriptionFixtures {
    /// Writes a few bytes as `<id>.wav` in the temporary directory and returns the captured audio.
    static func capturedAudio(samples: [Float], duration: TimeInterval = 1.5) throws -> CapturedAudio {
        let id = UUID()
        let url = FileManager.default.temporaryDirectory.appending(path: "\(id.uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0]).write(to: url)
        return CapturedAudio(id: id, fileURL: url, samples: samples, duration: duration)
    }

    static func uniqueKey() -> String {
        "test-key-\(UUID().uuidString)"
    }

    /// An own cloud key as the STT client's credential (`.value(nil)` without a key).
    static func ownKey(_ key: String?) -> KeyStore.Lookup<CloudCredential> {
        .value(key.map { CloudCredential.ownKey($0) })
    }

    /// The Pro relay with a session token.
    static let relayBase = URL(string: "https://relay.example.test/v1")!

    static func relay(_ token: String) -> KeyStore.Lookup<CloudCredential> {
        .value(CloudCredential.relay(token: token, baseURL: relayBase))
    }
}
