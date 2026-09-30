import Charts
import SwiftUI

/// Trend chart of the dashboard (brief section 6): bars per day in "Dziennie", area plus a
/// 2 pt catmullRom line of the running sum in "Łącznie". Three abbreviated Y ticks, "d MMM"
/// X labels in the UI language with a 1 / 2 / 5 day stride for 7 / 14 / 30 days.
@MainActor
struct TrendChart: View {
    let buckets: [DayBucket]
    let mode: TrendMode
    let metric: TrendMetric
    let range: Int

    private var series: [DayBucket] {
        mode == .cumulative ? Stats.cumulative(buckets) : buckets
    }

    /// X label stride in days for the given range (7 -> 1, 14 -> 2, 30 -> 5).
    static func labelStride(forRange range: Int) -> Int {
        switch range {
        case ...7: return 1
        case ...14: return 2
        default: return 5
        }
    }

    static func xLabel(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: Stats.locale).day().month(.abbreviated))
    }

    // Dusk Glass: luminous white bars fading into the brand violet, a white area and line for the
    // running sum, hairline white grid and white axis labels (docs/design/dusk-glass.md, Pulpit).
    private static let barFill = LinearGradient(
        colors: [Color.white.opacity(0.92), Color.white.opacity(0.5), VTColor.brandViolet.opacity(0.3)],
        startPoint: .top,
        endPoint: .bottom
    )
    private static let areaFill = LinearGradient(
        colors: [Color.white.opacity(0.38), VTColor.brandViolet.opacity(0.18), VTColor.brandViolet.opacity(0.02)],
        startPoint: .top,
        endPoint: .bottom
    )
    private static let gridColor = Color.white.opacity(GlassTokens.Opacity.separator)
    private static let labelColor = Color.white.opacity(0.62)

    var body: some View {
        Chart(series) { bucket in
            let value = bucket.value(for: metric)
            switch mode {
            case .daily:
                BarMark(
                    x: .value("Dzień", bucket.date, unit: .day),
                    y: .value(metric.displayName, value),
                    width: .ratio(0.42)
                )
                .foregroundStyle(Self.barFill)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 2, bottomTrailingRadius: 2, topTrailingRadius: 8, style: .continuous))
            case .cumulative:
                AreaMark(
                    x: .value("Dzień", bucket.date, unit: .day),
                    y: .value(metric.displayName, value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Self.areaFill)
                LineMark(
                    x: .value("Dzień", bucket.date, unit: .day),
                    y: .value(metric.displayName, value)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .foregroundStyle(Color.white.opacity(0.95))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    .foregroundStyle(Self.gridColor)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(Stats.abbreviate(number))
                            .font(GlassFont.ui(11).monospacedDigit())
                            .foregroundStyle(Self.labelColor)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: Self.labelStride(forRange: range))) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Self.xLabel(date))
                            .font(.system(size: 11))
                            .foregroundStyle(Self.labelColor)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.overlay(alignment: .bottom) {
                Rectangle().fill(Self.gridColor).frame(height: 1)
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...yMax)
        .accessibilityLabel(Text("Wykres: \(metric.displayName), \(mode.displayName), \(range) dni"))
    }

    private var xDomain: ClosedRange<Date> {
        guard let first = buckets.first?.date, let last = buckets.last?.date else {
            let now = Date()
            return now...now.addingTimeInterval(86_400)
        }
        return first...(last.addingTimeInterval(86_400))
    }

    private var yMax: Double {
        let peak = series.map { $0.value(for: metric) }.max() ?? 0
        return peak > 0 ? peak * 1.15 : 1
    }
}
