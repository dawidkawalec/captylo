import Foundation

/// Requests seen by a stub handler (the handler runs off the test's task), for the account tests.
final class AccountRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
    }

    var all: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    /// Paths of the requests seen, in order (`/api/v1/me`).
    var paths: [String] {
        all.map { $0.url?.path() ?? "" }
    }
}
