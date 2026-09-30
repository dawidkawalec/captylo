import SwiftUI

/// Expanded widget, mockups 03 / 04: the header capsule (orb, waveform, timer, status line) and
/// under it the glass panel with the live transcript card, the Mikrofon, Język transkrypcji and
/// Tryb AI menus, the two output switches and the "Pauza" / "Zakończ" buttons. Shown while the
/// pointer is over the widget.
@MainActor
struct RecorderExpandedView: View {
    @Bindable var model: RecorderModel
    let namespace: Namespace.ID

    var body: some View {
        VStack(spacing: RecorderMetrics.headerGap) {
            header
            panel
        }
        .frame(width: RecorderMetrics.expandedWidth)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            OrbButton(phase: model.phase, isGlass: false) {
                model.onStop()
            }

            VStack(spacing: 7) {
                WaveformView(
                    level: model.level,
                    phase: model.phase,
                    barCount: WaveformMath.expandedBarCount,
                    barWidth: RecorderMetrics.expandedBarWidth,
                    barGap: RecorderMetrics.expandedBarGap,
                    maxHeight: RecorderMetrics.expandedBarMaxHeight,
                    isStill: model.isWaveformStill
                )
                Text(model.statusText)
                    .font(GlassFont.ui(13))
                    .foregroundStyle(GlassColor.textSecondary)
                    .glassTextShadow()
                    .lineLimit(1)
                    .fixedSize()
                    .id(model.statusText)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity)

            Text(model.timerText)
                .font(GlassFont.number(RecorderMetrics.expandedTimerFont))
                .foregroundStyle(GlassColor.textPrimary)
                .glassTextShadow()
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(Text("Czas nagrania"))
                .accessibilityValue(Text(verbatim: model.timerText))
        }
        .padding(.leading, 16)
        .padding(.trailing, 20)
        .frame(width: RecorderMetrics.expandedWidth, height: RecorderMetrics.headerHeight)
        .recorderGlass(
            .header,
            in: RoundedRectangle(cornerRadius: RecorderMetrics.headerRadius, style: .continuous),
            namespace: namespace
        )
    }

    // MARK: Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: RecorderMetrics.panelSpacing) {
            LiveTranscriptCard(text: model.partialText, phase: model.phase, isPreviewEnabled: model.showLivePreview)
            if let controls = model.controls {
                GlassRowSeparator()
                    .padding(.top, 2)
                VStack(spacing: 0) {
                    microphoneRow(controls)
                    languageRow(controls)
                    aiModeRow(controls)
                }
                GlassRowSeparator()
                VStack(spacing: 0) {
                    RecorderToggleRow(
                        title: Text("Automatycznie kopiuj transkrypcję"),
                        systemImage: "doc",
                        isOn: Binding(get: { controls.autoCopy }, set: { controls.autoCopy = $0 })
                    )
                    RecorderToggleRow(
                        title: Text("Zapisz transkrypcję po zakończeniu"),
                        systemImage: "folder",
                        isOn: Binding(get: { controls.saveTranscript }, set: { controls.saveTranscript = $0 })
                    )
                }
            }
            Spacer(minLength: 0)
            buttons(model.controls)
        }
        .padding(RecorderMetrics.panelPadding)
        .frame(width: RecorderMetrics.expandedWidth, height: RecorderMetrics.panelHeight, alignment: .top)
        .recorderGlass(
            .panel,
            in: RoundedRectangle(cornerRadius: GlassTokens.Radius.panel, style: .continuous),
            namespace: namespace
        )
    }

    private func microphoneRow(_ controls: any RecorderWidgetControls) -> some View {
        let name = controls.currentMicrophoneName ?? String(localized: "Domyślny systemowy")
        return RecorderRow(
            title: Text("Mikrofon"),
            subtitle: model.microphoneChangePending ? Text("Od następnego nagrania") : nil,
            systemImage: "mic"
        ) {
            RecorderMenuValue(value: name, label: Text("Mikrofon"), isMenuOpen: $model.isMenuOpen) {
                let selected = controls.selectedMicrophoneID
                var items = [
                    RecorderMenuItem(
                        id: "system-default",
                        title: String(localized: "Domyślny systemowy"),
                        isChecked: selected == nil,
                        action: { [model] in model.selectMicrophone(id: nil) }
                    ),
                ]
                for (index, input) in controls.microphones.enumerated() {
                    items.append(RecorderMenuItem(
                        id: input.id,
                        title: input.name,
                        isChecked: selected == input.id,
                        startsGroup: index == 0,
                        action: { [model] in model.selectMicrophone(id: input.id) }
                    ))
                }
                return items
            }
        }
    }

    private func languageRow(_ controls: any RecorderWidgetControls) -> some View {
        RecorderRow(title: Text("Język transkrypcji"), systemImage: "globe") {
            RecorderMenuValue(
                value: RecorderLanguageOptions.name(for: controls.language),
                label: Text("Język transkrypcji"),
                isMenuOpen: $model.isMenuOpen
            ) {
                let current = controls.language
                return RecorderLanguageOptions.all.enumerated().map { index, option in
                    RecorderMenuItem(
                        id: option.code,
                        title: option.name,
                        isChecked: option.code == current,
                        startsGroup: index == 1,
                        action: { controls.language = option.code }
                    )
                }
            }
        }
    }

    /// "Bez AI" or a mode. The controller reads the mode when the take stops, so a pick made
    /// while recording applies to this take.
    private func aiModeRow(_ controls: any RecorderWidgetControls) -> some View {
        RecorderRow(title: Text("Tryb AI"), systemImage: "sparkles") {
            RecorderMenuValue(
                value: RecorderAIModeOptions.currentName(of: controls),
                label: Text("Tryb AI"),
                isMenuOpen: $model.isMenuOpen
            ) {
                RecorderAIModeOptions.menuItems(for: controls)
            }
        }
    }

    // MARK: Buttons

    private func buttons(_ controls: (any RecorderWidgetControls)?) -> some View {
        HStack(spacing: 12) {
            Button {
                controls?.togglePause()
            } label: {
                if model.phase == .paused {
                    Label("Wznów", systemImage: "play.fill")
                } else {
                    Label("Pauza", systemImage: "pause.fill")
                }
            }
            .buttonStyle(.glass(.neutral, fillsWidth: true))
            .disabled(controls == nil || !model.canControlTake)

            Button {
                model.onStop()
            } label: {
                Label("Zakończ", systemImage: "stop.fill")
            }
            .buttonStyle(.glass(.destructive, fillsWidth: true))
            .disabled(!model.canControlTake)
        }
    }
}
