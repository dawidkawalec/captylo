import Darwin
import Foundation

/// The process entry point. `--mcp` (the read-only MCP server the user's AI assistant starts and
/// keeps alive for its whole session) is served before AppKit or SwiftUI start: no
/// `NSApplication`, so no LaunchServices check-in under the app's bundle. A checked-in process
/// would take over every later launch of Captylo (Finder, Dock, Spotlight, the login item would
/// send it a reopen event instead of starting the real app). `--help` and `--version` print and
/// exit before AppKit too: before they existed, a script or an AI agent probing the binary with
/// `--help` started a second full app. A plain launch while another Captylo runs hands off to it
/// (`SingleInstance`). Everything else is `CaptyloApp`.
@main
enum CaptyloMain {
    enum Mode: Equatable {
        case app
        case mcpServer
        case help
        case version
    }

    static func mode(for arguments: [String]) -> Mode {
        if DebugCommand.parse(arguments) == .mcp { return .mcpServer }
        let flags = arguments.dropFirst()
        if flags.contains("--help") || flags.contains("-h") { return .help }
        if flags.contains("--version") { return .version }
        return .app
    }

    /// Only a plain launch (or `--open-section`) hands off to a running copy: debug commands and the
    /// unit-test host run next to the Captylo the developer may be dictating with.
    static func handsOffToRunningCopy(arguments: [String], isTestHost: Bool) -> Bool {
        guard !isTestHost else { return false }
        switch DebugCommand.parse(arguments) {
        case nil, .openSection: return true
        default: return false
        }
    }

    static let usage = """
        Captylo: dictation, meeting notes and voice notes for Mac.

        Usage:
          Captylo              open the app (or bring the running one forward)
          Captylo --mcp        read-only MCP server for your AI assistant (stdin/stdout)
          Captylo --version    print the version
          Captylo --help       print this help

        More: https://github.com/dawidkawalec/captylo
        """

    @MainActor
    static func main() {
        switch mode(for: CommandLine.arguments) {
        case .app:
            if handsOffToRunningCopy(arguments: CommandLine.arguments, isTestHost: AppStateOverrides.isTestHost),
               SingleInstance.handOffIfRunning() {
                exit(0)
            }
            CaptyloApp.main()
        case .mcpServer:
            serveMCP()
        case .help:
            print(usage)
            exit(0)
        case .version:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            print("Captylo \(version)")
            exit(0)
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
