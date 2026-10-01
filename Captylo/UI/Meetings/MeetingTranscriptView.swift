import SwiftUI

/// The transcript of one meeting (`MeetingTranscriptLines`): per line the `[mm:ss]` stamp, the
/// speaker chip ("Ja" in Tide, the other side in Glacier tints, stable per label) and the text;
/// consecutive segments of one speaker read as one line, the mic's echo is hidden, and a capture
/// gap shows as a thin "przerwa w nagraniu" separator at its time. While the meeting records,
/// the grey lines still being transcribed follow at the bottom. Lays out rows only: the details
/// view scrolls it.
///
/// With `onPlay` the stamps are buttons that play the line's track from that moment (no audio:
/// plain text). With `onRename` a click on a "Mówca N" chip opens a field for the speaker's name.
@MainActor
struct MeetingTranscriptView: View {
    let meeting: MeetingRecord
    let segments: [MeetingSegmentRecord]
    /// The grey "w trakcie" line per track while this meeting records.
    var partials: [MeetingTrack: String] = [:]
    var isLive = false
    /// Play `track` from this meeting time (the line's start).
    var onPlay: ((MeetingTrack, Double) -> Void)?
    /// Store this name for the speaker label ("2"); an empty name brings "Mówca 2" back.
    var onRename: ((String, String) -> Void)?

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
                        row(start: line.start, stampWidth: stampWidth, track: line.track, speaker: line.speaker) {
                            Text(verbatim: line.text)
                                .foregroundStyle(GlassColor.textPrimary)
                        }
                    case .gap(let at):
                        gapRow(at: at, stampWidth: stampWidth)
                    }
                }
                ForEach(pending, id: \.self) { track in
                    row(start: nil, stampWidth: stampWidth, track: track, speaker: nil) {
                        Text(verbatim: partials[track] ?? "")
                            .italic()
                            .foregroundStyle(GlassColor.textTertiary)
                    }
                }
            }
            .transaction { $0.disablesAnimations = isLive }
        }
    }

    /// `start` nil: a grey line still being transcribed (no stamp).
    private func row(start: Double?, stampWidth: CGFloat, track: MeetingTrack, speaker: String?,
                     @ViewBuilder text: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let start, let onPlay {
                MeetingStampButton(stamp: MeetingTime.stamp(start)) {
                    onPlay(track, start)
                }
                .frame(width: stampWidth, alignment: .leading)
            } else {
                Text(verbatim: start.map(MeetingTime.stamp) ?? "")
                    .font(GlassFont.ui(12, .medium).monospacedDigit())
                    .foregroundStyle(GlassColor.textTertiary)
                    .frame(width: stampWidth, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 6) {
                MeetingSpeakerChip(
                    label: meeting.label(track: track, speaker: speaker),
                    slot: MeetingTranscriptLines.tintSlot(track: track, speaker: speaker),
                    name: speaker.flatMap { meeting.speakerNames[$0] } ?? "",
                    rename: renameAction(speaker: speaker)
                )
                text()
                    .font(GlassFont.body)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    /// Only diarized speakers ("Mówca N") have a label to name; "Ja" and "Rozmówcy" do not.
    private func renameAction(speaker: String?) -> ((String) -> Void)? {
        guard let speaker, let onRename else { return nil }
        return { onRename(speaker, $0) }
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

/// `[12:34]` as a button: tertiary like the plain stamp, brighter with a play glyph on hover.
@MainActor
private struct MeetingStampButton: View {
    let stamp: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(verbatim: stamp)
                    .font(GlassFont.ui(12, .medium).monospacedDigit())
                Image(systemName: "play.fill")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(isHovered ? 1 : 0)
            }
            .foregroundStyle(isHovered ? GlassColor.highlight : GlassColor.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(GlassMotion.press, value: isHovered)
        .help(Text("Odtwórz od tej chwili"))
        .accessibilityLabel(Text("Odtwórz od \(stamp)"))
    }
}

/// Who speaks, as a small capsule: Tide for "Ja", a Glacier tint per speaker for the other side.
/// With `rename` ("Mówca N") a click opens a popover with the "Imię" field.
@MainActor
private struct MeetingSpeakerChip: View {
    let label: String
    /// `MeetingTranscriptLines.tintSlot`: nil for "Ja".
    let slot: Int?
    /// The name typed for this speaker so far ("" while it reads "Mówca N").
    var name: String = ""
    var rename: ((String) -> Void)?

    @State private var isEditing = false
    @State private var isHovered = false

    var body: some View {
        if let rename {
            Button {
                isEditing = true
            } label: {
                chip
                    .overlay {
                        Capsule().fill(Color.white.opacity(isHovered ? 0.08 : 0))
                    }
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(Text("Zmień nazwę mówcy"))
            .popover(isPresented: $isEditing, arrowEdge: .bottom) {
                MeetingSpeakerNameForm(initial: name) { typed in
                    isEditing = false
                    rename(typed)
                } onCancel: {
                    isEditing = false
                }
            }
        } else {
            chip
        }
    }

    private var chip: some View {
        let tint = slot.map { GlassColor.speakerTints[$0 % GlassColor.speakerTints.count] } ?? GlassColor.speakerMe
        return HStack(spacing: 6) {
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

/// The rename popover: "Imię" on the glass track, "Zapisz" (Return) and "Anuluj" (Escape).
/// An empty name brings "Mówca N" back.
@MainActor
private struct MeetingSpeakerNameForm: View {
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @FocusState private var isFocused: Bool

    init(initial: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kto to mówi?")
                .font(GlassFont.sectionTitle)
                .foregroundStyle(GlassColor.textPrimary)
            TextField("Imię", text: $name)
                .textFieldStyle(.glass)
                .focused($isFocused)
                .onSubmit(save)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Anuluj", action: onCancel)
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                    .keyboardShortcut(.cancelAction)
                Button("Zapisz", action: save)
                    .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
            }
        }
        .padding(16)
        .frame(width: 260)
        .onAppear { isFocused = true }
    }

    private func save() {
        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
