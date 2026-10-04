import Foundation

/// One JSON-RPC 2.0 message from the MCP client (one line of stdin), and the reply lines the
/// server writes. A message without an `id` member is a notification and never gets a reply.
struct MCPMessage: Sendable, Equatable {
    /// JSON-RPC error codes the server answers with.
    enum ErrorCode {
        static let parseError = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
        static let internalError = -32603
    }

    /// Why a line is not a message the server can act on.
    enum ParseFailure: Error, Equatable {
        /// Not JSON at all: answered with `parseError` and a null id.
        case malformedJSON
        /// JSON, but not a request or notification (no method, a batch array): answered with
        /// `invalidRequest` and the id when there was one.
        case invalidRequest(id: JSONValue)
    }

    /// The request id (a number or a string, echoed as it came); nil for a notification.
    var id: JSONValue?
    var method: String
    var params: JSONValue?

    var isNotification: Bool { id == nil }

    /// The message on one line; nil for a reply from the client (`result` or `error` without a
    /// method: the server never sends requests, so it ignores those).
    static func parse(_ line: String) throws(ParseFailure) -> MCPMessage? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
            throw .malformedJSON
        }
        guard case .object(let members) = value else {
            throw .invalidRequest(id: .null)
        }
        guard let method = members["method"] else {
            if members["result"] != nil || members["error"] != nil {
                return nil
            }
            throw .invalidRequest(id: members["id"] ?? .null)
        }
        guard case .string(let name) = method else {
            throw .invalidRequest(id: members["id"] ?? .null)
        }
        return MCPMessage(id: members["id"], method: name, params: members["params"])
    }

    /// `{"jsonrpc":"2.0","id":...,"result":...}` on one line.
    static func reply(id: JSONValue, result: JSONValue) -> String {
        line(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    /// `{"jsonrpc":"2.0","id":...,"error":{"code":...,"message":...}}` on one line.
    static func reply(id: JSONValue, errorCode: Int, message: String) -> String {
        line(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .int(errorCode), "message": .string(message)]),
        ]))
    }

    /// Compact JSON: line breaks inside strings are escaped, so one message is always one line.
    private static func line(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return #"{"error":{"code":-32603,"message":"Internal error"},"id":null,"jsonrpc":"2.0"}"#
        }
        return text
    }
}
