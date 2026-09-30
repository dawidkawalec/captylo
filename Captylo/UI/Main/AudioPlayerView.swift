import AVFoundation
import SwiftUI

/// Inline player of a history recording as a glass capsule: violet play / pause disc, a white
/// scrubber, the clock and a 1x / 1.5x / 2x rate cycle. `AVAudioPlayer` stays on the main actor;
/// progress is polled while playing.
@MainActor
struct AudioPlayerView: View {
    let url: URL

    @State private var player = AudioPlayerModel()

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 30, height: 30)
                    .background {
                        Circle()
                            .fill(LinearGradient(colors: [GlassColor.accent, GlassColor.accentDeep], startPoint: .top, endPoint: .bottom))
                            .shadow(color: GlassColor.accent.opacity(player.isLoaded ? 0.55 : 0), radius: 8, y: 2)
                    }
                    .overlay { Circle().strokeBorder(GlassColor.rim(top: 0.45, bottom: 0.06), lineWidth: 1) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(player.isLoaded ? 1 : 0.45)
            .disabled(!player.isLoaded)
            .accessibilityLabel(Text(player.isPlaying ? "Pauza" : "Odtwórz"))

            GlassScrubber(
                progress: Binding(
                    get: { player.progress },
                    set: { player.seek(toProgress: $0) }
                )
            )
            .disabled(!player.isLoaded)

            Text("\(Self.clock(player.currentTime)) / \(Self.clock(player.duration))")
                .font(GlassFont.caption.monospacedDigit())
                .foregroundStyle(GlassColor.textSecondary)
                .fixedSize()

            Button(player.rateTitle) {
                player.cycleRate()
            }
            .buttonStyle(.plain)
            .font(GlassFont.ui(11, .semibold).monospacedDigit())
            .foregroundStyle(GlassColor.textPrimary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .glassSurface(.track, in: Capsule(), shadow: false)
            .contentShape(Capsule())
            .disabled(!player.isLoaded)
            .accessibilityLabel(Text("Prędkość odtwarzania"))
        }
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .frame(height: 40)
        .frame(maxWidth: 520)
        .glassSurface(.control, in: Capsule(), shadow: false)
        .task(id: url) {
            player.load(url)
        }
        .onDisappear {
            player.stop()
        }
        .overlay(alignment: .bottomLeading) {
            if let error = player.errorText {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(GlassColor.destructive)
                    .offset(x: 14, y: 18)
            }
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Thin white progress track with a round knob; click or drag seeks. VoiceOver sees a standard
/// slider (`accessibilityRepresentation`), so adjusting it works like the system control.
@MainActor
private struct GlassScrubber: View {
    @Binding var progress: Double

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let knob: CGFloat = isHovered || isDragging ? 12 : 10
            let x = CGFloat(progress) * width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: max(4, x), height: 4)
                    .shadow(color: .white.opacity(0.35), radius: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: min(max(x - knob / 2, 0), width - knob))
                    .opacity(isEnabled ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        progress = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: 24)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered || isDragging)
        .accessibilityRepresentation {
            Slider(value: $progress, in: 0...1)
        }
    }
}

/// Observable wrapper over `AVAudioPlayer` (main actor only).
@MainActor
@Observable
final class AudioPlayerModel {
    static let rates: [Float] = [1, 1.5, 2]

    private(set) var isLoaded = false
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var rateIndex = 0
    private(set) var errorText: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    var progress: Double {
        duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
    }

    var rateTitle: String {
        let rate = Self.rates[rateIndex]
        return rate == rate.rounded() ? "\(Int(rate))x" : "\(rate)x"
    }

    func load(_ url: URL) {
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            player.rate = Self.rates[rateIndex]
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            currentTime = 0
            isLoaded = true
            errorText = nil
        } catch {
            player = nil
            isLoaded = false
            errorText = String(localized: "Nie udało się otworzyć nagrania.")
            Log.ui.error("Audio player load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            pollTask?.cancel()
        } else {
            if player.currentTime >= player.duration - 0.05 {
                player.currentTime = 0
            }
            player.play()
            isPlaying = true
            startPolling()
        }
    }

    func seek(toProgress progress: Double) {
        guard let player else { return }
        player.currentTime = progress * player.duration
        currentTime = player.currentTime
    }

    func cycleRate() {
        rateIndex = (rateIndex + 1) % Self.rates.count
        player?.rate = Self.rates[rateIndex]
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        player?.stop()
        player = nil
        isPlaying = false
        isLoaded = false
        currentTime = 0
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    self.currentTime = player.currentTime >= player.duration - 0.05 ? player.duration : player.currentTime
                    return
                }
            }
        }
    }
}
