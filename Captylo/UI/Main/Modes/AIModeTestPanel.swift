import SwiftUI

/// "Testuj tryb" in the mode editor: a sample dictation (prefilled with a messy Polish sentence),
/// one call of the mode as it is being edited (`ModeTester`) and the model output with its time.
/// Without an OpenRouter key it says where to add one.
@MainActor
struct AIModeTestPanel: View {
    let mode: AIMode
    let tester: ModeTester

    enum Phase: Equatable {
        case idle
        case running
        case finished(ModeTestResult)
        case failed(String)
    }

    @State private var sample = AIModeTestPanel.defaultSample
    @State private var phase: Phase = .idle
    @State private var task: Task<Void, Never>?

    static var defaultSample: String {
        String(localized: "no to yyy jutro spotkanie o dziesiątej, trzeba przygotować ofertę dla klienta i zadzwonić do Marka, a i jeszcze faktura")
    }

    private var sampleIsEmpty: Bool {
        sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GlassPanel {
            GlassSectionHeader("Testuj tryb", systemImage: "play.circle") {
                if sample != Self.defaultSample {
                    Button {
                        sample = Self.defaultSample
                    } label: {
                        Label("Przykład", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                    .help(Text("Przywróć przykładowy dyktat"))
                }
            }
            ToolCaption("Sprawdź tryb na przykładowym dyktacie, także przed zapisaniem zmian. Test używa wybranego modelu i Twojego klucza API do AI.")

            TextField("Wpisz lub wklej przykładowy dyktat", text: $sample, axis: .vertical)
                .textFieldStyle(.plain)
                .font(GlassFont.body)
                .foregroundStyle(GlassColor.textPrimary)
                .lineLimit(2...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .glassSurface(.track, cornerRadius: GlassTokens.Radius.control, shadow: false)
                .accessibilityLabel(Text("Przykładowy dyktat"))

            HStack(spacing: 12) {
                Button {
                    run()
                } label: {
                    Label("Testuj", systemImage: "play.fill")
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                .disabled(phase == .running || sampleIsEmpty)
                if phase == .running {
                    ProgressView().controlSize(.small)
                    Text("Czekam na odpowiedź modelu...")
                        .font(GlassFont.caption)
                        .foregroundStyle(GlassColor.textSecondary)
                }
                Spacer(minLength: 0)
            }

            result
        }
        .onDisappear {
            task?.cancel()
        }    }

    @ViewBuilder
    private var result: some View {
        switch phase {
        case .idle, .running:
            EmptyView()
        case .failed(let message):
            GlassCard {
                ToolStatusLine(text: message, tone: .error)
            }
            .transition(.opacity)
        case .finished(let outcome):
            GlassCard(spacing: 12) {
                HStack(spacing: 8) {
                    Text("Wynik")
                        .font(GlassFont.caption.weight(.semibold))
                        .foregroundStyle(GlassColor.textSecondary)
                    Spacer(minLength: 8)
                    GlassBadge(
                        title: Text("\(outcome.ms) ms"),
                        systemImage: "timer",
                        tone: outcome.exceedsModeDeadline ? .warning : .success
                    )
                    GlassBadge(title: Text(verbatim: outcome.model))
                }
                Text(verbatim: outcome.text)
                    .font(GlassFont.body)
                    .foregroundStyle(GlassColor.textPrimary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if outcome.exceedsModeDeadline {
                    ToolStatusLine(
                        text: String(localized: "To trwało dłużej niż limit trybu (\(AIMode.secondsLabel(mode.clampedDeadlineSeconds))). Przy dyktowaniu wkleiłby się surowy tekst."),
                        tone: .error
                    )
                }
            }
            .transition(.opacity)
        }
    }

    private func run() {
        task?.cancel()
        let mode = mode
        let sample = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        let tester = tester
        withAnimation(GlassMotion.spring) {
            phase = .running
        }
        task = Task {
            let outcome = await tester.runDetailed(mode, sample: sample)
            guard !Task.isCancelled else { return }
            withAnimation(GlassMotion.spring) {
                switch outcome {
                case .success(let result):
                    phase = .finished(result)
                case .failure(let error):
                    phase = .failed(Self.message(for: error))
                }
            }
        }
    }

    static func message(for error: any Error) -> String {
        if let skip = error as? EnhancementSkip, skip == .noKey {
            // Shared with OpenRouterError, so the editor and Historia never say different things.
            return OpenRouterError.missingKeyMessage
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
