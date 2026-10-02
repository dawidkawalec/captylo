import Foundation

/// A local, read-only MCP server over the meeting library (`--mcp`, started by the user's AI
/// assistant, e.g. Claude Desktop or Cursor, never by Captylo itself): newline-delimited
/// JSON-RPC 2.0 on stdin and stdout. Methods: `initialize`, `ping`, `tools/list`, `tools/call`;
/// notifications get no reply, anything else is "method not found". The tools (`MCPTools`)
/// only read; no AI call, no network.
///
/// The "Dostęp dla asystentów AI (MCP)" setting (off by default) is read at every call: while
/// it is off `tools/list` is empty and a tool call answers with where to turn it on.
///
/// Requests are answered one at a time, in order, each with exactly one line; nothing else is
/// ever written to stdout (`StandardIO.claim` moves everything else to stderr).
final class MCPServer: Sendable {
    /// The newest protocol revision the server speaks, answered when the client asks for one
    /// it does not know.
    static let protocolVersion = "2025-06-18"
    /// Revisions whose tool results look the same as ours: a client asking for one gets it back.
    static let supportedProtocolVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// The tool call answer while the setting is off.
    static var disabledMessage: String {
        String(localized: "Włącz dostęp w Captylo: Ustawienia > Spotkania > Dostęp dla asystentów AI (MCP).")
    }

    /// Whether the setting is on in the app's own defaults domain (the `--mcp` process is the
    /// app binary, so `.standard` is that domain); read again at every call.
    @Sendable static func settingIsOn() -> Bool {
        UserDefaults.standard.bool(forKey: AppSettings.Key.meetingsMCP.rawValue)
    }

    private let input: AsyncStream<String>
    private let output: @Sendable (String) -> Void
    private let tools: MCPTools
    private let isEnabled: @Sendable () -> Bool
    private let version: String

    /// `input`: the lines from the client; `output`: writes one reply line (without its line break).
    init(
        input: AsyncStream<String>,
        output: @escaping @Sendable (String) -> Void,
        tools: MCPTools,
        isEnabled: @escaping @Sendable () -> Bool = MCPServer.settingIsOn,
        version: String
    ) {
        self.input = input
        self.output = output
        self.tools = tools
        self.isEnabled = isEnabled
        self.version = version
    }

    /// Answers every line until the input ends (the client closed stdin).
    func run() async {
        for await line in input {
            if let reply = await handle(line) {
                output(reply)
            }
        }
    }

    /// The reply line for one input line, nil when there is nothing to answer (a notification,
    /// a reply from the client, an empty line).
    func handle(_ line: String) async -> String? {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let message: MCPMessage
        do throws(MCPMessage.ParseFailure) {
            guard let parsed = try MCPMessage.parse(line) else { return nil }
            message = parsed
        } catch {
            switch error {
            case .malformedJSON:
                return MCPMessage.reply(id: .null, errorCode: MCPMessage.ErrorCode.parseError, message: "Parse error")
            case .invalidRequest(let id):
                return MCPMessage.reply(id: id, errorCode: MCPMessage.ErrorCode.invalidRequest, message: "Invalid Request")
            }
        }
        guard let id = message.id else { return nil }
        switch message.method {
        case "initialize":
            return MCPMessage.reply(id: id, result: initializeResult(message.params))
        case "ping":
            return MCPMessage.reply(id: id, result: .object([:]))
        case "tools/list":
            let tools: [JSONValue] = isEnabled() ? self.tools.definitions : []
            return MCPMessage.reply(id: id, result: .object(["tools": .array(tools)]))
        case "tools/call":
            return await callTool(id: id, params: message.params)
        default:
            return MCPMessage.reply(id: id, errorCode: MCPMessage.ErrorCode.methodNotFound, message: "Method not found: \(message.method)")
        }
    }

    // MARK: Methods

    private func initializeResult(_ params: JSONValue?) -> JSONValue {
        let asked = params?["protocolVersion"]?.stringValue ?? ""
        let agreed = Self.supportedProtocolVersions.contains(asked) ? asked : Self.protocolVersion
        return .object([
            "protocolVersion": .string(agreed),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object([
                "name": .string("captylo"),
                "title": .string("Captylo"),
                "version": .string(version),
            ]),
            "instructions": .string("""
                Read-only access to the meetings recorded with Captylo on this Mac. Use search_meetings \
                to find what was said (Polish word forms match), list_meetings to browse by date, and \
                get_meeting for the notes and the full transcript. Cite moments as [mm:ss] with the meeting title.
                """),
        ])
    }

    private func callTool(id: JSONValue, params: JSONValue?) async -> String {
        guard let name = params?["name"]?.stringValue else {
            return MCPMessage.reply(id: id, errorCode: MCPMessage.ErrorCode.invalidParams, message: "Missing tool name")
        }
        guard MCPTools.names.contains(name) else {
            return MCPMessage.reply(id: id, errorCode: MCPMessage.ErrorCode.invalidParams, message: "Unknown tool: \(name)")
        }
        guard isEnabled() else {
            return MCPMessage.reply(id: id, result: Self.toolResult(MCPTools.Result(text: Self.disabledMessage, isError: true)))
        }
        do {
            let result = try await tools.call(name: name, arguments: params?["arguments"])
            return MCPMessage.reply(id: id, result: Self.toolResult(result))
        } catch let failure as MeetingLibraryReader.Failure {
            return MCPMessage.reply(id: id, errorCode: MCPMessage.ErrorCode.internalError, message: failure.errorDescription ?? "")
        } catch MCPTools.Failure.unknownTool(let name) {
            return MCPMessage.reply(id: id, errorCode: MCPMessage.ErrorCode.invalidParams, message: "Unknown tool: \(name)")
        } catch {
            // A store read failed mid-call: the error kind only, never meeting text.
            Log.data.error("MCP tool \(name, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public)")
            return MCPMessage.reply(
                id: id, errorCode: MCPMessage.ErrorCode.internalError,
                message: MeetingLibraryReader.Failure.storeUnavailable.errorDescription ?? ""
            )
        }
    }

    private static func toolResult(_ result: MCPTools.Result) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(result.text)])]),
            "isError": .bool(result.isError),
        ])
    }
}
