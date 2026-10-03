import Foundation
import Testing
@testable import Captylo

/// The account JSON fixtures in `CaptyloTests/Fixtures/` (copied flat into the test bundle) and
/// small helpers the account tests share. Invented data only: `anna@example.com`, fake tokens.
enum AccountFixtures {
    private final class BundleToken {}

    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "json"), "missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    static func proInfo() throws -> AccountInfo {
        try AccountClient.parseMe(data("account-me-pro"))
    }

    static func freeInfo() throws -> AccountInfo {
        try AccountClient.parseMe(data("account-me-free"))
    }

    /// The JSON body of a stubbed request (`URLProtocol` sees a stream instead of `httpBody`).
    static func body(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func date(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso))
    }
}
