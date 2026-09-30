import SwiftUI

/// The transcript of one meeting (`MeetingTranscriptLines`): per line the `[mm:ss]` stamp, the
/// speaker chip ("Ja" in Tide, the other side in Glacier tints, stable per label) and the text;
/// consecutive segments of one speaker read as one line, the mic's echo is hidden, and a capture
/// gap shows as a thin "przerwa w nagraniu" separator at its time. While the meeting records,
/// the grey lines still being transcribed follow at the bottom. Lays out rows only: the details
/// view scrolls it.
@MainActor
struct MeetingTranscriptView: View {
    let meeting: MeetingRecord
    let segments: [MeetingSegmentRecord]
    /// The grey "w trakcie" line per track while this meeting records.
    var partials: [MeetingTrack: String] = [:]
    var isLive = false

    var body: some View {
        let items = MeetingTranscriptLines.items(segments, interruptions: meeting.interruptions)
        let stampWidth = Self.stampWidth(items: items, duration: meeting.duration)
        let pending = MeetingTrack.allCases.filter { !(partials[$0] ?? "").isEmpty }
        if items.isEmpty, pending.isEmpty {
            ToolCaption(isLive
                        ? "Słucham. Transkrypt pojawi się po pierwszej wypowiedzi."
                        : "To spotkanie nie ma transkryptu.")
        } else {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(items) { item in
                    switch item {
                    case .line(let line):
                        row(stamp: MeetingTime.stamp(line.start), stampWidth: stampWidth,
                            track: line.track, speaker: line.speaker) {
                            Text(verbatim: line.text)
                                .foregroundStyle(GlassColor.textPrimary)
                        }
                    case .gap(let at):
                        gapRow(at: at, stampWidth: stampWidth)
                    }
                }
                ForEach(pending, id: \.self) { track in
                    row(stamp: nil, stampWidth: stampWidth, track: track, speaker: nil) {
                        Text(verbatim: partials[track] ?? "")
                            .italic()
                            .foregroundStyle(GlassColor.textTertiary)
                    }
                }
            }
            .transaction { $0.disablesAnimations = isLive }
        }
    }

    private func row(stamp: String?, stampWidth: CGFloat, track: MeetingTrack, speaker: String?,
                     @ViewBuilder text: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: stamp ?? "")
                .font(GlassFont.ui(12, .medium).monospacedDigit())
                .foregroundStyle(GlassColor.textTertiary)
                .frame(width: stampWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                MeetingSpeakerChip(
                    label: meeting.label(track: track, speaker: speaker),
                    slot: MeetingTranscriptLines.tintSlot(track: track, speaker: speaker)
                )
                text()
                    .font(GlassFont.body)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func gapRow(at: Double, stampWidth: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(verbatim: MeetingTime.stamp(at))
                .font(GlassFont.ui(12, .medium).monospacedDigit())
                .foregroundStyle(GlassColor.textTertiary)
                .frame(width: stampWidth, alignment: .leading)
            HStack(spacing: 10) {
                Rectangle().fill(GlassColor.separator).frame(height: 1)
                Label("przerwa w nagraniu", systemImage: "waveform.slash")
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textTertiary)
                    .fixedSize()
                Rectangle().fill(GlassColor.separator).frame(height: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Room for "[12:34]", or "[1:02:03]" once the meeting passes an hour.
    private static func stampWidth(items: [MeetingTranscriptLines.Item], duration: Double) -> CGFloat {
        let latest = items.reduce(duration) { latest, item in
            switch item {
            case .line(let line): return max(latest, line.start)
            case .gap(let at): return max(latest, at)
            }
        }
        return latest >= 3600 ? 66 : 50
    }
}

/// Who speaks, as a small capsule: Tide for "Ja", a Glacier tint per speaker for the other side.
@MainActor
private struct MeetingSpeakerChip: View {
    let label: String
    /// `MeetingTranscriptLines.tintSlot`: nil for "Ja".
    let slot: Int?

    var body: some View {
        let tint = slot.map { GlassColor.speakerTints[$0 % GlassColor.speakerTints.count] } ?? GlassColor.speakerMe
        HStack(spacing: 6) {
            Circle()
                .fill(slot == nil ? Color.white.opacity(0.9) : tint)
                .frame(width: 6, height: 6)
            Text(verbatim: label)
                .font(GlassFont.badge)
                .foregroundStyle(Color.white.opacity(0.95))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 20)
        .background {
            Capsule().fill(tint.opacity(slot == nil ? 0.55 : 0.18))
        }
        .overlay {
            Capsule().strokeBorder(tint.opacity(slot == nil ? 0.8 : 0.45), lineWidth: 1)
        }
        .fixedSize()
    }
}
