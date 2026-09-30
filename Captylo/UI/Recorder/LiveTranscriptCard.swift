import SwiftUI

/// "Transkrypcja na żywo" card of the expanded widget (mockup 03): an inset `GlassCard` with the
/// section header, a hairline and the last three lines of the partial text, bottom-anchored
/// under a top fade with a caret after the last word while recording. Text updates never
/// animate (gotcha 59).
@MainActor
struct LiveTranscriptCard: View {
    let text: String
    let phase: DictationPhase
    let isPreviewEnabled: Bool

    var body: some View {
        GlassCard(style: .inset, padding: 12, spacing: 8) {
            GlassSectionHeader("Transkrypcja na żywo", systemImage: "doc.text")
            GlassRowSeparator()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: RecorderMetrics.liveTextHeight, alignment: .bottomLeading)
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.14),
                            .init(color: .black, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .transaction { $0.disablesAnimations = true }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        if !text.isEmpty {
            Text(transcript)
                .font(GlassFont.ui(14))
                .foregroundStyle(GlassColor.textPrimary)
                .lineSpacing(3)
                .glassTextShadow()
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        } else if !isPreviewEnabled {
            placeholder(Text("Podgląd na żywo jest wyłączony w ustawieniach."))
        } else if phase.isCapturing {
            placeholder(Text("Mów, a tekst pojawi się tutaj."))
        } else {
            Color.clear.frame(height: 1)
        }
    }

    /// The partial text plus a thin caret after the last word while recording, like the mockup.
    private var transcript: AttributedString {
        var result = AttributedString(text)
        if phase == .recording {
            var caret = AttributedString(" |")
            caret.foregroundColor = GlassColor.textSecondary
            result += caret
        }
        return result
    }

    private func placeholder(_ text: Text) -> some View {
        text
            .font(GlassFont.ui(13))
            .foregroundStyle(GlassColor.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
