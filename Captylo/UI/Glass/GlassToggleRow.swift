import SwiftUI

/// Row with the blue glass switch ("Automatycznie kopiuj transkrypcję").
@MainActor
struct GlassToggleRow: View {
    var title: Text
    var subtitle: Text?
    var systemImage: String?
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, systemImage: String? = nil, isOn: Binding<Bool>) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.systemImage = systemImage
        _isOn = isOn
    }

    init(title: Text, subtitle: Text? = nil, systemImage: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        _isOn = isOn
    }

    var body: some View {
        GlassRow(title: title, subtitle: subtitle, systemImage: systemImage) {
            Toggle(isOn: $isOn) {
                title
            }
            .toggleStyle(.glassSwitch)
            .labelsHidden()
        }
        .accessibilityElement(children: .combine)
    }
}
