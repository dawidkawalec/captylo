import SwiftUI

/// Every Glass component on the dusk wallpaper: the living catalog behind
/// `--design-preview glass-gallery` (docs/design/dusk-glass.md). The left column rebuilds the
/// lower panel of mockup 03 from the components; the right column shows the remaining ones.
/// Demo-only values use `Text(verbatim:)` so they never enter the string catalog.
@MainActor
struct GlassGallery: View {
    private enum Range: Hashable, CaseIterable {
        case day, week, month
    }

    @State private var autoCopy = true
    @State private var saveAfter = true
    @State private var range: Range = .week
    @State private var mode = 0
    @State private var name = "Captylo"
    @State private var key = "sk-or-v1-design-preview"

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            mockupPanel
                .frame(width: 440)
            VStack(alignment: .leading, spacing: 20) {
                tiles
                controls
                fields
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 32)
        .padding(.top, 52)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .duskWindow(role: .sheet)
    }

    // MARK: Mockup 03 panel

    private var mockupPanel: some View {
        GlassPanel(spacing: 12) {
            GlassCard {
                GlassSectionHeader("Transkrypcja na żywo", systemImage: "doc.text")
                GlassRowSeparator()
                Text(verbatim: RecorderDemo.sampleText)
                    .font(GlassFont.ui(15))
                    .foregroundStyle(GlassColor.textPrimary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GlassRowSeparator()
                .padding(.top, 4)
            VStack(spacing: 0) {
                GlassRow("Mikrofon", systemImage: "mic") {
                    GlassMenuValue("MacBook Pro (Wbudowany)") {
                        Button(String("MacBook Pro (Wbudowany)")) {}
                        Button(String("AirPods Pro")) {}
                    }
                }
                GlassRow("Język transkrypcji", systemImage: "globe") {
                    GlassMenuValue("Polski") {
                        Button(String("Polski")) {}
                        Button(String("English")) {}
                    }
                }
            }
            GlassRowSeparator()
            VStack(spacing: 0) {
                GlassToggleRow("Automatycznie kopiuj transkrypcję", systemImage: "doc", isOn: $autoCopy)
                GlassToggleRow("Zapisz transkrypcję po zakończeniu", systemImage: "folder", isOn: $saveAfter)
            }
            HStack(spacing: 14) {
                Button {} label: {
                    Label("Pauza", systemImage: "pause.fill")
                }
                .buttonStyle(.glass(.neutral, fillsWidth: true))
                Button {} label: {
                    Label("Zakończ", systemImage: "stop.fill")
                }
                .buttonStyle(.glass(.destructive, fillsWidth: true))
            }
            .padding(.top, 4)
        }
    }

    // MARK: Right column

    private var tiles: some View {
        HStack(spacing: 14) {
            GlassStatTile("Słowa", value: "4 812", systemImage: "text.word.spacing", tint: VTColor.brandViolet)
            GlassStatTile("Sesje", value: "42", systemImage: "waveform", tint: VTColor.brandPink)
            GlassStatTile("Nagrany czas", value: "1:07:32", systemImage: "clock", tint: VTColor.brandOrange)
        }
    }

    private var controls: some View {
        GlassPanel(spacing: 16) {
            GlassSectionHeader(title: Text(verbatim: "Przyciski i wybór"), systemImage: "slider.horizontal.3") {
                GlassBadge(title: Text(verbatim: "Nowy"), tone: .accent)
            }
            GlassSegmentedPicker(selection: $range, title: { range in
                switch range {
                case .day: return "Dzień"
                case .week: return "7 dni"
                case .month: return "30 dni"
                }
            })
            GlassSegmentedPicker(
                selection: $mode,
                segments: [
                    GlassSegment(0, title: Text(verbatim: "Słupki"), systemImage: "chart.bar"),
                    GlassSegment(1, title: Text(verbatim: "Linia"), systemImage: "chart.xyaxis.line"),
                ],
                fillsWidth: true
            )
            HStack(spacing: 10) {
                Button("Dalej") {}
                    .buttonStyle(.glass(.accent))
                Button("Wstecz") {}
                    .buttonStyle(.glass)
                Button("Usuń") {}
                    .buttonStyle(.glass(.destructive, size: .small, shape: .capsule))
                Button("Pobierz") {}
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                    .disabled(true)
            }
            HStack(spacing: 8) {
                GlassBadge("Gotowy", systemImage: "checkmark", tone: .success)
                GlassBadge(title: Text(verbatim: "Szybki wybór"), tone: .neutral)
                GlassBadge(title: Text(verbatim: "Pobieranie 42%"), tone: .warning)
                GlassBadge(title: Text(verbatim: "Błąd"), tone: .danger)
                Spacer(minLength: 0)
                GlassIconBadge(systemImage: "cpu")
                GlassIconBadge(systemImage: "keyboard", tint: VTColor.brandViolet)
                GlassIconBadge(systemImage: "sparkles", tint: VTColor.brandOrange)
            }
        }
    }

    private var fields: some View {
        GlassPanel(spacing: 12) {
            GlassSectionHeader(title: Text(verbatim: "Pola"), systemImage: "character.cursor.ibeam")
            TextField(String("Nazwa"), text: $name)
                .textFieldStyle(.glass)
            GlassSecureField("Klucz API do AI", text: $key)
            GlassCard(style: .raised) {
                GlassRow(title: Text(verbatim: "Karta uniesiona"), subtitle: Text(verbatim: "GlassCard(style: .raised)"), systemImage: "square.stack") {
                    GlassRowValue("Otwórz", chevron: .right)
                }
            }
        }
    }
}
