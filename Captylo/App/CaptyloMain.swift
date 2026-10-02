import Darwin
import Foundation

/// The process entry point. `--mcp` (the read-only MCP server the user's AI assistant starts and
/// keeps alive for its whole session) is served before AppKit or SwiftUI start: no
/// `NSApplication`, so no LaunchServices check-in under the app's bundle. A checked-in process
/// would take over every later launch of Captylo (Finder, Dock, Spotlight, the login item would
/// send it a reopen event instead of starting the real app). Everything else is `CaptyloApp`.
@main
enum CaptyloMain {
    enum Mode: Equatable {
        case app
        case mcpServer
    }

    static func mode(for arguments: [String]) -> Mode {
        DebugCommand.parse(arguments) == .mcp ? .mcpServer : .app
    }

    @MainActor
    static func main() {
        switch mode(for: CommandLine.arguments) {
        case .app:
            CaptyloApp.main()
        case .mcpServer:
            serveMCP()
        }
    }

    /// The MCP server on the claimed stdin/stdout (`MCPStandardIO`, claimed first so nothing
    /// else ever reaches the protocol stdout) over the library at `AppPaths`, read-only. Exits
    /// when the client closes stdin; the main queue keeps running for anything that hops to it.
    @MainActor
    private static func serveMCP() -> Never {
        let io = MCPStandardIO.shared
        let reader = MeetingLibraryReader(storeURL: AppPaths.store, indexURL: AppPaths.searchIndex)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let server = MCPServer(input: io.input, output: io.write, tools: MCPTools(library: reader), version: version)
        Task.detached {
            Log.app.notice("MCP server started")
            await server.run()
            Log.app.notice("MCP server stopped: input closed")
            exit(0)
        }
        dispatchMain()
    }
}
