import SwiftUI

/// The meetings of Spotkania, newest first, on one glass panel with hairlines between the rows
/// (like the Historia day panels): title, date and app, length, and a badge while a meeting
/// records, is being processed or was cut short ("Przerwane"). A click or the arrow keys select;
/// the selection is the Tide fill of the Historia rows.
///
/// While searching, a row matched in its transcript or notes shows up to two hit lines
/// (`MeetingSearchHitsView`) under the meta line; a click on one selects the meeting and hands
/// the line to `onOpenHit`.
@MainActor
struct MeetingListView: View {
    /// Rows the list shows when it sits above the details (narrow window).
    static let collapsedRows = 4
    fileprivate static let listPadding: CGFloat = 6

    /// Height of the collapsed list: `collapsedRows` rows, or fewer when there are fewer meetings.
    static func collapsedHeight(rows: Int) -> CGFloat {
        collapsedHeight(rowHeights: Array(repeating: MeetingListRow.height, count: rows))
    }

    /// Height of the collapsed list for rows of these heights (`rowHeight(hitLines:)`): the first
    /// `collapsedRows`, at least one plain row.
    static func collapsedHeight(rowHeights: [CGFloat]) -> CGFloat {
        let shown = rowHeights.isEmpty ? [MeetingListRow.height] : Array(rowHeights.prefix(collapsedRows))
        return shown.reduce(0, +) + CGFloat(shown.count - 1) + 2 * listPadding
    }

    /// A row with this many hit lines under it.
    static func rowHeight(hitLines: Int) -> CGFloat {
        guard hitLines > 0 else { return MeetingListRow.height }
        return MeetingListRow.height + MeetingSearchHitsView.height(lines: hitLines) + MeetingListRow.hitsBottomPadding
    }

    let meetings: [MeetingRecord]
    @Binding var selection: UUID?
    /// What `MeetingRecorder` is doing, for the live badge of its meeting.
    let recorderPhase: MeetingRecorder.Phase
    /// Search hit lines per meeting (empty when not searching).
    var hitLines: [UUID: [MeetingSearchHitLine]] = [:]
    /// A hit line was clicked (the meeting is already selected).
    var onOpenHit: ((UUID, MeetingSearchHitLine) -> Void)?

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassPanel(padding: 0, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(meetings.enumerated()), id: \.element.id) { index, meeting in
                            if index > 0 {
                                GlassRowSeparator()
                                    .padding(.horizontal, 14)
                            }
                            MeetingListRow(
                                meeting: meeting,
                                badge: MeetingListRow.Badge(meeting: meeting, phase: recorderPhase),
                                isSelected: selection == meeting.id,
                                hitLines: hitLines[meeting.id] ?? [],
                                onSelect: {
                                    isFocused = true
                                    selection = meeting.id
                                },
                                onOpenHit: { line in
                                    isFocused = true
                                    selection = meeting.id
                                    onOpenHit?(meeting.id, line)
                                }
                            )
                            .id(meeting.id)
                        }
                    }
                    .padding(Self.listPadding)
                }
                .scrollBounceBehavior(.basedOnSize)
                .clipShape(RoundedRectangle(cornerRadius: GlassTokens.Radius.panel, style: .continuous))
                .focusable()
                .focused($isFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    move(by: press.key == .upArrow ? -1 : 1, proxy: proxy)
                    return .handled
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Spotkania"))
    }

    private func move(by offset: Int, proxy: ScrollViewProxy) {
        guard !meetings.isEmpty else { return }
        let ids = meetings.map(\.id)
        let current = selection.flatMap { ids.firstIndex(of: $0) }
        let next = current.map { min(max($0 + offset, 0), ids.count - 1) } ?? 0
        selection = ids[next]
        if reduceMotion {
            proxy.scrollTo(ids[next])
        } else {
            withAnimation(GlassMotion.selection) { proxy.scrollTo(ids[next]) }
        }
    }
}

/// One meeting on the list panel: a plain line with soft fills for hover and selection, never a
/// glass surface of its own.
@MainActor
private struct MeetingListRow: View {
    /// Fixed, so the collapsed list shows whole rows and a badge never changes a row's height.
    static let height: CGFloat = 64

    enum Badge: Equatable {
        case recording
        case processing
        case interrupted

        /// The recorder's own state wins for its meeting: its row still says "recording" in the
        /// store while it records and while it is being finished.
        init?(meeting: MeetingRecord, phase: MeetingRecorder.Phase) {
            switch phase {
            case .recording(let id, _) where id == meeting.id:
                self = .recording
                return
            case .finishing(let id) where id == meeting.id:
                self = .processing
                return
            default:
                break
            }
            switch meeting.status {
            case .processing: self = .processing
            case .interrupted: self = .interrupted
            case .recording, .completed, .failed: return nil
            }
        }
    }

    /// Space under the hit lines of a search row.
    static let hitsBottomPadding: CGFloat = 8

    let meeting: MeetingRecord
    let badge: Badge?
    let isSelected: Bool
    var hitLines: [MeetingSearchHitLine] = []
    let onSelect: () -> Void
    var onOpenHit: (MeetingSearchHitLine) -> Void = { _ in }

    @State private var isHovered = false

    /// The row's fills sit behind the title part and the hit lines alike; the hit lines are
    /// buttons of their own next to the row's button, never inside it.
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GlassTokens.Radius.card - 4, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            header
            if !hitLines.isEmpty {
                MeetingSearchHitsView(lines: hitLines, onOpen: onOpenHit)
                    .padding(.horizontal, 6)
                    .padding(.bottom, Self.hitsBottomPadding)
            }
        }
        .background {
            if isSelected {
                shape.fill(GlassColor.accent.opacity(0.26))
                    .overlay { shape.strokeBorder(GlassColor.accent.opacity(0.7), lineWidth: 1) }
            } else if isHovered {
                shape.fill(Color.white.opacity(0.06))
            }
        }
        .onHover { isHovered = $0 }
        .animation(GlassMotion.press, value: isHovered)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: meeting.title)
                        .font(GlassFont.ui(14, .semibold))
                        .foregroundStyle(GlassColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    if showsDuration {
                        Text(verbatim: MeetingTime.clock(meeting.duration))
                            .font(GlassFont.ui(13, .medium).monospacedDigit())
                            .foregroundStyle(GlassColor.textSecondary)
                    }
                }
                HStack(spacing: 8) {
                    Text(verbatim: Self.metaText(meeting))
                        .font(GlassFont.caption)
                        .foregroundStyle(GlassColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    if let badge {
                        badgeView(badge)
                    }
                }
                .frame(height: 22)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The length is known once the meeting stopped; a live or cut-short one shows its badge.
    private var showsDuration: Bool {
        badge != .recording && meeting.duration > 0
    }

    @ViewBuilder
    private func badgeView(_ badge: Badge) -> some View {
        switch badge {
        case .recording:
            GlassBadge("Nagrywam", systemImage: "record.circle", tone: .danger)
        case .processing:
            GlassBadge("Przetwarzam", systemImage: "hourglass", tone: .neutral)
        case .interrupted:
            GlassBadge("Przerwane", systemImage: "exclamationmark.triangle", tone: .warning)
        }
    }

    /// "30 wrz, 14:00 · Zoom".
    static func metaText(_ meeting: MeetingRecord) -> String {
        let date = MeetingDateText.short(meeting.createdAt)
        guard let app = meeting.appName, !app.isEmpty else { return date }
        return "\(date) · \(app)"
    }
}
