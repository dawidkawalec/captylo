import SwiftUI

/// Step container on the dusk wallpaper (docs/design/dusk-glass.md, "Onboarding"). The welcome
/// step floats on its own; the other steps share one frosted `GlassPanel` that hugs its content
/// (and scrolls when it would not fit) under a slim glass progress track, with the
/// Wstecz / Pomiń wprowadzenie / Dalej bar at the bottom. Steps cross-fade inside the panel.
@MainActor
struct OnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let model: OnboardingModel

    /// Height of the current step's content, so the panel hugs it instead of filling the window.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ZStack {
            if model.step == .welcome {
                WelcomeStep(model: model)
                    .transition(.opacity)
            } else {
                flow
                    .transition(.opacity)
            }
        }
        .animation(stepAnimation, value: model.step == .welcome)
        .frame(width: OnboardingPresenter.windowSize.width, height: OnboardingPresenter.windowSize.height)
        .duskWindow(role: .onboarding, extendsUnderTitleBar: true)
        .environment(\.windowBackgroundStyle, model.settings.windowBackground)
        .environment(\.windowTone, model.settings.windowTone)
    }

    private var stepAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: VTMotion.onboardingStepDuration)
    }

    private var flow: some View {
        VStack(spacing: 0) {
            progress
                .padding(.top, 34)
                .padding(.horizontal, 40)

            // Top-aligned at a fixed offset under the progress track: the panel's top edge stays
            // put on every "Dalej", the free space falls to the bottom above the footer.
            stepPanel
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 18)

            footer
                .padding(.horizontal, 36)
                .padding(.bottom, 26)
        }
    }

    // MARK: Progress

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Krok \(model.step.index + 1) z \(OnboardingStep.allCases.count)")
                    .monospacedDigit()
                Spacer()
                Text(verbatim: model.step.title)
            }
            .font(GlassFont.caption.weight(.medium))
            // On the bright sky of the wallpaper: primary white with a dark halo for contrast.
            .foregroundStyle(GlassColor.textPrimary)
            .shadow(color: .black.opacity(0.35), radius: 6, y: 1)

            OnboardingProgressTrack(fraction: model.step.progress)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Postęp wprowadzenia"))
        .accessibilityValue(Text("Krok \(model.step.index + 1) z \(OnboardingStep.allCases.count)"))
    }

    // MARK: Panel

    private var stepPanel: some View {
        GlassPanel(padding: 0, spacing: 0) {
            ScrollView(.vertical) {
                ZStack(alignment: .top) {
                    stepContent
                        .id(model.step)
                        .transition(.opacity)
                }
                .animation(stepAnimation, value: model.step)
                .padding(GlassTokens.Padding.panel + 2)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: contentHeight > 0 ? contentHeight : .infinity)
            .clipShape(RoundedRectangle(cornerRadius: GlassTokens.Radius.panel, style: .continuous))
            .animation(reduceMotion ? nil : GlassMotion.spring, value: contentHeight)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .welcome: EmptyView()
        case .permissions: PermissionsStep(model: model)
        case .model: ModelStep(model: model)
        case .shortcut: ShortcutStep(model: model)
        case .tryIt: TryItStep(model: model)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            if model.canGoBack {
                Button {
                    model.goBack()
                } label: {
                    Label("Wstecz", systemImage: "chevron.left")
                }
                .buttonStyle(.glass(.neutral, shape: .capsule))
            }
            Spacer()
            if model.canSkip {
                // Ends the whole onboarding, not just this step: the label says so.
                Button("Pomiń wprowadzenie") {
                    model.skip()
                }
                .buttonStyle(OnboardingTextButtonStyle())
            }
            Button {
                model.advance()
            } label: {
                Text(verbatim: model.primaryTitle)
                    .frame(minWidth: 84)
            }
            // Capsule like "Zaczynamy" on the welcome step: one primary shape throughout.
            .buttonStyle(.glass(.accent, size: .large, shape: .capsule))
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canAdvance)
        }
    }
}

/// "Pomiń wprowadzenie": plain secondary text that brightens on hover and press.
private struct OnboardingTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OnboardingTextButtonBody(configuration: configuration)
    }
}

@MainActor
private struct OnboardingTextButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(GlassFont.body)
            .foregroundStyle(isHovered || configuration.isPressed ? GlassColor.textPrimary : GlassColor.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: GlassTokens.Size.buttonHeight)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}
