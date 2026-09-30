import SwiftUI

/// Compact widget, mockup 01: a modest glass orb, a free-floating row of 15 white bars and the
/// light "00:18" timer. No bar or container behind them; the bars, the timer and the orb carry
/// their own soft glow and dark halo (`glassFloatingHalo`), and the waveform, timer and status
/// line share ONE wide feathered dark cloud (`RecorderBackdropHalo`) so they read over white
/// windows without two smudges.
/// Paused and processing states add a status line under the waveform, and an active rewrite
/// mode ("Po angielsku") is named there while recording; while the take is transcribed or
/// polished the timer fades out (it would only sit frozen).
@MainActor
struct RecorderCompactView: View {
    let model: RecorderModel
    let namespace: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            OrbButton(phase: model.phase, size: RecorderMetrics.compactOrb) {
                model.onStop()
            }
            .recorderGlass(.orb, in: Circle(), namespace: namespace)

            WaveformView(level: model.level, phase: model.phase, isStill: model.isWaveformStill)
                .overlay(alignment: .top) { status }
                .padding(.leading, RecorderMetrics.compactOrbToWaveform)
                .padding(.trailing, RecorderMetrics.compactWaveformToTimer)

            Text(model.timerText)
                .font(GlassFont.number(RecorderMetrics.compactTimerFont))
                .foregroundStyle(GlassColor.textPrimary)
                .glassFloatingHalo()
                .lineLimit(1)
                .fixedSize()
                .frame(width: RecorderMetrics.compactTimerWidth, alignment: .leading)
                .opacity(model.phase.isProcessing ? 0 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.phase.isProcessing)
                .accessibilityHidden(model.phase.isProcessing)
                .accessibilityLabel(Text("Czas nagrania"))
                .accessibilityValue(Text(verbatim: model.timerText))
        }
        .frame(width: RecorderMetrics.compactSize.width, height: RecorderMetrics.compactSize.height)
        .background(alignment: .topLeading) {
            RecorderBackdropHalo(rect: haloRect)
                .animation(reduceMotion ? nil : GlassMotion.spring, value: haloRect)
        }
    }

    /// One cloud under every mark that shows: the timer while it is visible, the status lines
    /// under the waveform while they are.
    private var haloRect: CGRect {
        let lines = (model.compactStatusText.isEmpty ? 0 : 1) + (model.compactStatusDetail == nil ? 0 : 1)
        return RecorderMetrics.compactHaloRect(showsTimer: !model.phase.isProcessing, statusLines: lines)
    }

    /// Centered under the waveform, which is the visible middle of the row once the timer has
    /// faded out for processing. While AI runs the mode name goes on a second, smaller line:
    /// "Poprawiam z AI · Uporządkuj myśli" on one line would run into the orb. While recording
    /// with a rewrite mode ("Po angielsku") only that smaller line shows, with the mode symbol.
    @ViewBuilder
    private var status: some View {
        let detail = model.compactStatusDetail
        ZStack {
            if !model.compactStatusText.isEmpty || detail != nil {
                VStack(spacing: 1) {
                    if !model.compactStatusText.isEmpty {
                        Text(model.compactStatusText)
                            .font(GlassFont.ui(12, .semibold))
                            .foregroundStyle(GlassColor.textPrimary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if let detail {
                        HStack(spacing: 4) {
                            if let symbol = model.compactStatusSymbol {
                                Image(systemName: symbol)
                                    .font(.system(size: 10, weight: .semibold))
                                    .accessibilityHidden(true)
                            }
                            Text(verbatim: detail)
                                .font(GlassFont.ui(11, .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .foregroundStyle(GlassColor.textPrimary.opacity(0.9))
                    }
                }
                .glassFloatingHalo()
                .accessibilityElement(children: .combine)
                .id(statusKey)
                .transition(.opacity)
            }
        }
        .frame(width: RecorderMetrics.compactStatusWidth)
        .offset(y: RecorderMetrics.compactBarMaxHeight + RecorderMetrics.compactStatusGap)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: statusKey)
    }

    /// Changes whenever the status or the mode under it changes, so both cross-fade.
    private var statusKey: String {
        model.compactStatusText + "|" + (model.compactStatusDetail ?? "")
    }
}
