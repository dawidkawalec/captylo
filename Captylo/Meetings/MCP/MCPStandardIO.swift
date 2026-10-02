import Darwin
import Foundation

/// The `--mcp` process's own stdin and stdout for `MCPServer`. Claimed once, as early as
/// possible (`CaptyloMain`, before anything else is built): the real stdout is kept on a
/// private descriptor for the JSON-RPC lines only, and descriptor 1 is pointed at stderr, so a
/// stray `print` from any library can never corrupt the protocol (MCP clients log stderr).
struct MCPStandardIO: Sendable {
    /// Lines from stdin, finished when the client closes it.
    let input: AsyncStream<String>
    /// Writes one line and its line break straight to the protocol descriptor (unbuffered),
    /// one line at a time.
    let write: @Sendable (String) -> Void

    /// The process-wide claim; the first use moves stdout and starts reading stdin.
    static let shared = claim()

    private static func claim() -> MCPStandardIO {
        // A client that went away must end the process through stdin, not kill it on a write.
        signal(SIGPIPE, SIG_IGN)
        fflush(stdout)
        let protocolDescriptor = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        let handle = FileHandle(fileDescriptor: protocolDescriptor >= 0 ? protocolDescriptor : STDERR_FILENO, closeOnDealloc: false)
        let queue = DispatchQueue(label: "com.captylo.app.mcp-output")
        let write: @Sendable (String) -> Void = { line in
            queue.sync {
                try? handle.write(contentsOf: Data((line + "\n").utf8))
            }
        }
        let (input, continuation) = AsyncStream<String>.makeStream()
        Thread.detachNewThread {
            // Blocking reads on a thread of their own, line by line, until end of file.
            while let line = Swift.readLine(strippingNewline: true) {
                continuation.yield(line)
            }
            continuation.finish()
        }
        return MCPStandardIO(input: input, write: write)
    }
}
