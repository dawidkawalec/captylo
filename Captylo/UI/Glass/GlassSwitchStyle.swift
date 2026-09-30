import SwiftUI

/// The blue switch of mockup 03, drawn by hand so it stays blue in inactive windows and panels
/// (the native `NSSwitch` turns gray whenever the app is not frontmost, which is most of the
/// widget's life). `Toggle(...).toggleStyle(.glassSwitch)`.
struct GlassSwitchStyle: ToggleStyle {
    /// Windows and panels.
    static let size = CGSize(width: 46, height: 28)
    /// The expanded widget: about 7.5 % of the panel width like mockup 03, knob 18 pt.
    static let compactSize = CGSize(width: 38, height: 22)

    var isCompact = false

    func makeBody(configuration: Configuration) -> some View {
        GlassSwitchBody(configuration: configuration, size: isCompact ? Self.compactSize : Self.size)
    }
}

extension ToggleStyle where Self == GlassSwitchStyle {
    static var glassSwitch: GlassSwitchStyle { GlassSwitchStyle() }
    /// Smaller switch for dense rows (the expanded widget).
    static var glassSwitchCompact: GlassSwitchStyle { GlassSwitchStyle(isCompact: true) }
}

@MainActor
private struct GlassSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    let size: CGSize

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isOn = configuration.isOn
        let knob = size.height - 4
        Button {
            if reduceMotion {
                configuration.isOn.toggle()
            } else {
                withAnimation(GlassMotion.press) {
                    configuration.isOn.toggle()
                }
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(
                        isOn
                            ? AnyShapeStyle(LinearGradient(colors: [GlassColor.toggle, GlassColor.toggle.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(Color.white.opacity(0.18))
                    )
                    .overlay {
                        Capsule().strokeBorder(GlassColor.rim(top: isOn ? 0.35 : 0.25, bottom: 0.05), lineWidth: 1)
                    }
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: knob, height: knob)
                    .padding(2)
            }
            .frame(width: size.width, height: size.height)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) {
                configuration.label
            }
        }
    }
}
