import SwiftUI

/// The two tabs of Modele and Ustawienia: "Podstawowe" holds what everyone needs, "Zaawansowane"
/// the own keys, the model list and the fine-tuning. Each page opens on "Podstawowe".
enum SettingsLevel: Hashable, Sendable {
    case basic
    case advanced
}

/// "Podstawowe | Zaawansowane" in the page header (`ToolPage` accessory).
@MainActor
struct SettingsLevelPicker: View {
    @Binding var level: SettingsLevel

    var body: some View {
        GlassSegmentedPicker(selection: $level, segments: [
            GlassSegment(SettingsLevel.basic, "Podstawowe"),
            GlassSegment(SettingsLevel.advanced, "Zaawansowane", systemImage: "slider.horizontal.3"),
        ])
        .accessibilityLabel(Text("Widok ustawień"))
    }
}
