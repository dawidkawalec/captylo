import SwiftUI

/// "Pulpit" (Brand Direction 01, the owner's pick "Liczba i kalendarz"): the time saved as one big
/// number straight on the window background with three small figures under it, the five-week
/// "Aktywność" grid next to it, and the trend chart below. Reloads through `Database.dashboard`
/// whenever `statsVersion` or the range changes.
@MainActor
struct DashboardView: View {
    @Environment(AppState.self) private var appState
    @State private var snapshot: DashboardSnapshot = .empty
    @State private var loadFailed = false

    /// Reload key: a saved dictation or a new range both refetch.
    private struct ReloadKey: Hashable {
        let version: Int
        let range: Int
    }

    var body: some View {
        @Bindable var settings = appState.settings

        MainGlassPage(spacing: 18) {
            HStack(alignment: .center, spacing: 22) {
                SavedTimeHero(snapshot: snapshot, correctionRate: appState.learning.correctionRate())
                    .frame(maxWidth: .infinity, alignment: .leading)
                ActivityPanel(days: snapshot.activity, calendar: Self.calendar)
                    .frame(maxWidth: .infinity)
            }

            GlassPanel(spacing: 14) {
                GlassSectionHeader(title: Text(String(localized: "Trend")), systemImage: "chart.bar.xaxis") {
                    GlassBadge(title: Text(verbatim: Stats.summaryText(buckets: snapshot.days, metric: settings.dashboardMetric, mode: settings.dashboardMode)))
                }
                TrendControls(range: $settings.dashboardRange, mode: $settings.dashboardMode, metric: $settings.dashboardMetric)
                TrendChart(buckets: snapshot.days, mode: settings.dashboardMode, metric: settings.dashboardMetric, range: settings.dashboardRange)
                    .frame(height: 170)
            }

            if loadFailed {
                InlineStatus(text: String(localized: "Nie udało się wczytać statystyk."), tone: .error)
            }
        }
        .task(id: ReloadKey(version: appState.statsVersion, range: settings.dashboardRange)) {
            await reload(days: settings.dashboardRange)
        }
    }

    private func reload(days: Int) async {
        let database = appState.database
        do {
            let fresh = try await database.dashboard(days: days, now: Date(), calendar: Self.calendar)
            snapshot = fresh
            loadFailed = false
        } catch {
            Log.data.error("Dashboard load failed: \(error.localizedDescription, privacy: .public)")
            loadFailed = true
        }
    }

    /// Local calendar with Monday as the first weekday (brief section 6).
    static var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    // MARK: Formatting

    static func integer(_ value: Int) -> String {
        value.formatted(.number.locale(Stats.locale))
    }

    /// "1 godz. 5 min" for long totals, "4 min" below an hour, "12 s" below a minute.
    /// Hand-formatted: `DateComponentsFormatter.abbreviated` ignores the Polish locale.
    static func recordedTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        guard total >= 1 else { return "0 s" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return minutes > 0
                ? String(localized: "\(hours) godz. \(minutes) min")
                : String(localized: "\(hours) godz.")
        }
        if minutes > 0 {
            return "\(minutes) min"
        }
        return "\(total) s"
    }
}

// MARK: - Hero

/// "Zaoszczędzony czas" as one big Manrope number with its unit, the words/sessions line and
/// three small figures (streak, words today, words per minute), white type straight on the
/// window background with a soft shadow. Before the first minute saved: the call to action.
@MainActor
private struct SavedTimeHero: View {
    let snapshot: DashboardSnapshot
    /// Self-learning: words changed per 100 pasted in watched fields (14 days); nil hides it.
    let correctionRate: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Zaoszczędzony czas")
                .font(GlassFont.bodyMedium)
                .foregroundStyle(GlassColor.textSecondary)

            if let parts = Stats.timeSavedParts(seconds: snapshot.timeSavedSeconds) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: parts.value)
                        .font(GlassFont.hero(96))
                        .tracking(-4)
                        .contentTransition(.numericText())
                    Text(verbatim: parts.unit)
                        .font(GlassFont.face(.manropeBold, 34))
                        .foregroundStyle(GlassColor.textSecondary)
                }
                .foregroundStyle(GlassColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.top, 2)
            } else {
                Text(Stats.timeSavedText(seconds: snapshot.timeSavedSeconds))
                    .font(GlassFont.face(.manropeSemiBold, 22))
                    .foregroundStyle(GlassColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            Text(Stats.heroSubtitle(words: snapshot.words, sessions: snapshot.sessions))
                .font(GlassFont.body)
                .foregroundStyle(GlassColor.textSecondary)
                .padding(.top, 8)

            HStack(alignment: .top, spacing: 26) {
                InlineFigure(value: DashboardView.integer(snapshot.streakDays), caption: String(localized: "Dni z rzędu"))
                InlineFigure(value: DashboardView.integer(snapshot.today?.words ?? 0), caption: String(localized: "Słowa dziś"))
                InlineFigure(value: snapshot.wpm.map { DashboardView.integer(Int($0.rounded())) } ?? "-", caption: String(localized: "Słowa/min"))
                if let correctionRate {
                    InlineFigure(
                        value: correctionRate.formatted(.number.precision(.fractionLength(1)).locale(Stats.locale)),
                        caption: String(localized: "Poprawki/100 słów")
                    )
                    .help(Text("Ile słów na 100 wklejonych poprawiasz ręcznie (ostatnie 14 dni). Im mniej, tym lepiej Captylo zna Twoje słowa."))
                }
            }
            .padding(.top, 20)
        }
        .glassTextShadow(0.2)
        .accessibilityElement(children: .combine)
    }
}

/// A figure under the big number: Manrope value over an Inter caption.
@MainActor
private struct InlineFigure: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: value)
                .font(GlassFont.number(22))
                .foregroundStyle(GlassColor.textPrimary)
                .contentTransition(.numericText())
            Text(caption)
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
        }
    }
}

// MARK: - Activity

/// "Aktywność": the last five calendar weeks as a Monday-first grid of day tiles, coloured by
/// that day's words (faint white for a few, Fog for a normal day, Glacier for the busiest), the
/// day number in the corner and a ring around today. Hovering a day lifts it and shows its words,
/// sessions and recorded time under the grid.
@MainActor
private struct ActivityPanel: View {
    let days: [DayBucket]
    let calendar: Calendar

    /// The day under the pointer; its figures replace the hint line under the grid.
    @State private var hovered: DayBucket.ID?

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        let peak = max(days.map(\.words).max() ?? 0, 1)
        let active = days.filter { $0.sessions > 0 }.count

        GlassPanel(padding: 18, spacing: 10) {
            GlassSectionHeader(title: Text(String(localized: "Aktywność")), systemImage: "calendar") {
                GlassBadge(title: Text(String(localized: "\(active) z \(days.count) dni")))
            }

            LazyVGrid(columns: Self.columns, spacing: 6) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(verbatim: symbol)
                        .font(GlassFont.face(.interMedium, 11))
                        .foregroundStyle(GlassColor.textTertiary)
                        .frame(maxWidth: .infinity)
                }
                ForEach(days) { day in
                    ActivityCell(
                        day: day,
                        intensity: Double(day.words) / Double(peak),
                        isToday: day.id == days.last?.id,
                        isHovered: day.id == hovered,
                        calendar: calendar
                    )
                    .onHover { inside in
                        if inside {
                            hovered = day.id
                        } else if hovered == day.id {
                            hovered = nil
                        }
                    }
                }
            }

            ActivityDayDetail(day: days.first { $0.id == hovered })
        }
    }

    /// "Pn Wt Śr ..." starting at the calendar's first weekday. Polish uses the customary
    /// two-letter forms (Foundation's short symbols would give "Ni" for Sunday); other languages
    /// take the first two letters of the system's short names. Sunday first, like `weekday`.
    private var weekdaySymbols: [String] {
        let symbols: [String]
        if Stats.locale.language.languageCode?.identifier == "pl" {
            symbols = ["Nd", "Pn", "Wt", "Śr", "Cz", "Pt", "So"]
        } else {
            var localized = calendar
            localized.locale = Stats.locale
            symbols = localized.shortStandaloneWeekdaySymbols.map { String($0.prefix(2)) }
        }
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }
}

/// The line under the grid: the hovered day's date with its words, sessions and recorded time,
/// or a hint while the pointer is elsewhere. Fixed height, so the panel never jumps.
@MainActor
private struct ActivityDayDetail: View {
    let day: DayBucket?

    var body: some View {
        HStack(spacing: 14) {
            if let day {
                Text(verbatim: day.date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Stats.locale)))
                    .font(GlassFont.face(.interSemiBold, 12))
                    .foregroundStyle(GlassColor.textPrimary)
                Spacer(minLength: 6)
                figure(String(localized: "Słowa"), DashboardView.integer(day.words))
                figure(String(localized: "Sesje"), DashboardView.integer(day.sessions))
                figure(String(localized: "Nagrania"), DashboardView.recordedTime(day.minutes * 60))
            } else {
                Text("Najedź na dzień, żeby zobaczyć, ile tego dnia podyktowano.")
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textTertiary)
                Spacer(minLength: 0)
            }
        }
        .lineLimit(1)
        .frame(height: 18)
        .animation(nil, value: day?.id)
    }

    private func figure(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(GlassColor.textTertiary)
            Text(verbatim: value)
                .foregroundStyle(GlassColor.textPrimary)
                .monospacedDigit()
        }
        .font(GlassFont.face(.interMedium, 12))
    }
}

@MainActor
private struct ActivityCell: View {
    let day: DayBucket
    let intensity: Double
    let isToday: Bool
    let isHovered: Bool
    let calendar: Calendar

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(fill)
            .overlay {
                if isToday || isHovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(isHovered ? 1 : 0.85), lineWidth: isHovered ? 2 : 1.5)
                }
            }
            .scaleEffect(isHovered ? 1.06 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
            .overlay(alignment: .topLeading) {
                Text(verbatim: String(calendar.component(.day, from: day.date)))
                    .font(GlassFont.face(.interMedium, 10))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .padding(.leading, 5)
                    .padding(.top, 3)
            }
            .frame(height: 32)
            .help(Text(verbatim: tooltip))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: tooltip))
    }

    /// The same steps as the approved lab page: empty, a few words, Fog, Glacier.
    private var fill: Color {
        guard day.words > 0 else { return Color.white.opacity(0.07) }
        switch intensity {
        case ..<0.3: return Color.white.opacity(0.12 + intensity * 0.6)
        case ..<0.6: return VTColor.fog.opacity(0.45 + intensity * 0.5)
        default: return VTColor.glacier.opacity(min(0.55 + intensity * 0.4, 0.95))
        }
    }

    private var tooltip: String {
        let date = day.date.formatted(.dateTime.day().month(.abbreviated).locale(Stats.locale))
        return String(localized: "\(date), słowa: \(day.words)")
    }
}

// MARK: - Trend controls

/// Range, mode and metric as glass segmented capsules.
@MainActor
private struct TrendControls: View {
    @Binding var range: Int
    @Binding var mode: TrendMode
    @Binding var metric: TrendMetric

    var body: some View {
        HStack(spacing: 10) {
            GlassSegmentedPicker(
                selection: $range,
                segments: DashboardSnapshot.rangeOptions.map { GlassSegment($0, title: Text("\($0) d")) }
            )
            .accessibilityLabel(Text("Zakres"))

            GlassSegmentedPicker(selection: $mode, title: { $0.displayName })
                .accessibilityLabel(Text("Tryb"))

            Spacer(minLength: 10)

            GlassSegmentedPicker(selection: $metric, title: { $0.displayName })
                .accessibilityLabel(Text("Miara"))
        }
    }
}
