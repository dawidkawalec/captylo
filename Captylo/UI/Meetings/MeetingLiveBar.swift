import SwiftUI

/// The top of a meeting's details while it records: the pulsing Record dot, "Nagrywam spotkanie"
/// with the meeting clock, a small level meter per track ("Ja", "Rozmówcy") and "Zakończ". While
/// the recorder finishes the meeting (last lines, speakers, AI notes) a spinner replaces them.
/// Under the bar the warnings about the recording: no access to system audio, only the mic, a
/// silent other side, a mic that did not start, and the quiet headphones hint. Raised cards, not
/// glass: the bar sits on the details panel.
@MainActor
struct MeetingLiveBar: View {
    let recorder: MeetingRecorder
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if recorder.isRecording {
                recordingBar
                notices
            } else {
                finishingBar
            }
        }
    }

    // MARK: Bar

    private var recordingBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                MeetingRecordDot()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nagrywam spotkanie")
                        .font(GlassFont.ui(12, .medium))
                        .foregroundStyle(GlassColor.textSecondary)
                        .lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(verbatim: MeetingTime.clock(recorder.elapsed(at: context.date)))
                            .font(GlassFont.number(17))
                            .foregroundStyle(GlassColor.textPrimary)
                            .fixedSize()
                    }
                }
                .fixedSize()
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                MeetingLevelMeter(title: Text("Ja"), track: .me, recorder: recorder)
                MeetingLevelMeter(title: Text("Rozmówcy"), track: .them, recorder: recorder)
            }
            Button(action: onStop) {
                Label("Zakończ", systemImage: "stop.fill")
            }
            .buttonStyle(.glass(.destructive, size: .small, shape: .capsule))
            .fixedSize()
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.raised, cornerRadius: GlassTokens.Radius.card, tint: GlassColor.destructive.opacity(0.6), shadow: false)
    }

    private var finishingBar: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(GlassColor.textPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Kończę spotkanie")
                    .font(GlassFont.bodyMedium)
                    .foregroundStyle(GlassColor.textPrimary)
                Text("Transkrypt jest zapisany. Reszta może chwilę potrwać.")
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.raised, cornerRadius: GlassTokens.Radius.card, shadow: false)
        .accessibilityElement(children: .combine)
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        switch recorder.systemAudioIssue {
        case .noAccess?:
            MainBanner(
                symbol: "speaker.slash",
                tone: .warning,
                text: String(localized: "Nie słyszę rozmówców. Captylo potrzebuje dostępu do dźwięku systemu."),
                surface: .raised
            ) {
                Button("Otwórz Ustawienia systemowe") {
                    SystemAudioPermission.openSettings()
                }
            }
        case .unavailable(let message)?:
            MainBanner(
                symbol: "speaker.slash",
                tone: .warning,
                text: String(localized: "Nagrywam tylko Twój mikrofon: \(message)"),
                surface: .raised
            ) {
                EmptyView()
            }
        case .silent?:
            MainBanner(
                symbol: "waveform.slash",
                tone: .warning,
                text: String(localized: "Od ponad minuty nie słyszę rozmówców. Jeśli ktoś mówi, nagranie może ich pomijać."),
                surface: .raised
            ) {
                EmptyView()
            }
        case nil:
            EmptyView()
        }
        if let error = recorder.lastError {
            MainBanner(
                symbol: "mic.slash",
                tone: .danger,
                text: String(localized: "Nagrywam tylko rozmówców. \(error)"),
                surface: .raised
            ) {
                EmptyView()
            }
        }
        if recorder.usesBuiltInSpeakers {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "headphones")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GlassColor.textSecondary)
                Text("Bez słuchawek rozmówcy nagrają się też przez mikrofon. Słuchawki dają czystszy transkrypt.")
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The Record red dot of the live bar with a soft glow; it breathes like the widget's, and holds
/// still with Reduce Motion.
@MainActor
private struct MeetingRecordDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(GlassColor.destructive)
            .frame(width: 9, height: 9)
            .shadow(color: GlassColor.destructive.opacity(0.8), radius: 6)
            .scaleEffect(pulsing && !reduceMotion ? 1.25 : 1)
            .opacity(pulsing && !reduceMotion ? 0.75 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: VTMotion.recordDotPulsePeriod / 2).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
            .onDisappear { pulsing = false }
            .accessibilityHidden(true)
    }
}

/// "Ja" / "Rozmówcy" and a thin white track filled to the track's level, read about 12 times a
/// second inside a `TimelineView` instead of observing a fast property.
@MainActor
private struct MeetingLevelMeter: View {
    static let width: CGFloat = 64

    let title: Text
    let track: MeetingTrack
    let recorder: MeetingRecorder

    var body: some View {
        HStack(spacing: 8) {
            title
                .font(GlassFont.ui(11, .medium))
                .foregroundStyle(GlassColor.textSecondary)
                .lineLimit(1)
                .fixedSize()
            TimelineView(.animation(minimumInterval: 0.08)) { _ in
                let level = CGFloat(min(max(recorder.level(track), 0), 1))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                    Capsule()
                        .fill(track == .me ? GlassColor.textPrimary : GlassColor.highlight)
                        .frame(width: max(3, level * Self.width))
                }
                .frame(width: Self.width, height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
