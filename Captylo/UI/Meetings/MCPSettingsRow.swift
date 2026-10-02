import AppKit
import SwiftUI

/// "Dostęp dla asystentów AI (MCP)" in Ustawienia > Spotkania (Free, off by default): lets the
/// user's own AI assistant start Captylo as a local, read-only MCP server (`--mcp`). When on,
/// "Skopiuj konfigurację" copies the `mcpServers` entry that starts this very app binary, with a
/// caption where to paste it. The switch is the only gate: the server process reads it at every call.
@MainActor
struct MCPSettingsRow: View {
    @Bindable var settings: AppSettings

    @State private var copied = false

    /// The `mcpServers` entry for MCP clients (Claude Desktop, Cursor...), pretty JSON.
    nonisolated static func configuration(executablePath: String) -> String {
        let entry: [String: Any] = [
            "mcpServers": [
                "captylo": [
                    "command": executablePath,
                    "args": ["--mcp"],
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: entry, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    var body: some View {
        GlassToggleRow(
            "Dostęp dla asystentów AI (MCP)",
            subtitle: "Twój asystent AI (np. Claude Desktop, Cursor) może czytać i przeszukiwać spotkania na tym Macu. Captylo niczego nie zmienia ani nie wysyła, ale asystent przekazuje przeczytany tekst do swojej usługi.",
            systemImage: "puzzlepiece.extension",
            isOn: $settings.meetingsMCP
        )
        if settings.meetingsMCP {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    copy()
                } label: {
                    if copied {
                        Label("Skopiowano", systemImage: "checkmark")
                    } else {
                        Label("Skopiuj konfigurację", systemImage: "doc.on.doc")
                    }
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                .fixedSize()
                ToolStatusLine(text: String(localized: "Wklej ją w ustawieniach MCP asystenta (w Claude Desktop: Ustawienia > Developer > Edit Config) i uruchom go ponownie."))
            }
            .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            .padding(.bottom, 4)
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
    }

    private func copy() {
        let path = Bundle.main.executablePath ?? Bundle.main.bundlePath
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.configuration(executablePath: path), forType: .string)
        copied = true
    }
}
