import Foundation
import os
@testable import Captylo

/// In-process HTTP stub for the Networking and Enhancement tests. Handlers are keyed by host so
/// parallel tests never see each other's traffic: every test registers its own unique host.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int = 200
        var body: Data = Data()
        var delay: Duration = .zero
        var error: URLError?

        static func json(_ text: String, status: Int = 200, delay: Duration = .zero) -> Reply {
            Reply(status: status, body: Data(text.utf8), delay: delay)
        }

        static func failure(_ code: URLError.Code) -> Reply {
            Reply(error: URLError(code))
        }
    }

    typealias Handler = @Sendable (URLRequest) -> Reply

    private static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    /// Registers a handler and returns the base URL to point a client at.
    static func register(_ handler: @escaping Handler) -> URL {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        handlers.withLock { $0[host] = handler }
        return URL(string: "https://\(host)/api/v1")!
    }

    static func unregister(_ baseURL: URL) {
        guard let host = baseURL.host() else { return }
        handlers.withLock { $0[host] = nil }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    private static func handler(for request: URLRequest) -> Handler? {
        guard let host = request.url?.host() else { return nil }
        return handlers.withLock { $0[host] }
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        handler(for: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let reply = handler(request)
        let seconds = Double(reply.delay.components.seconds) + Double(reply.delay.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            deliver(reply)
        }
    }

    override func stopLoading() {
        cancelled.withLock { $0 = true }
    }

    private func deliver(_ reply: Reply) {
        guard !cancelled.withLock({ $0 }), let client, let url = request.url else { return }
        if let error = reply.error {
            client.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: reply.status,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "application/json"]
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: reply.body)
        client.urlProtocolDidFinishLoading(self)
    }
}
