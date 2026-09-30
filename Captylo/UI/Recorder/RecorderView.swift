import SwiftUI

/// Widget root hosted by `RecorderPanel`: a fixed transparent canvas sized for the expanded
/// state (`RecorderMetrics.canvas`) with the compact widget (mockup 01) or the expanded one
/// (mockups 03 / 04) bottom-anchored inside it (gotcha 57). On macOS 26 both live in one
/// `GlassEffectContainer`, so the orb glass morphs into the header capsule and back.
@MainActor
struct RecorderView: View {
    let model: RecorderModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNamespace

    var body: some View {
        glassGroup
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, RecorderMetrics.margin)
            .frame(width: RecorderMetrics.canvas.width, height: RecorderMetrics.canvas.height, alignment: .bottom)
            .opacity(model.isPresented ? 1 : 0)
            .scaleEffect(model.isPresented || reduceMotion ? 1 : 0.96, anchor: .bottom)
            // Dark glass keeps the white type legible over bright windows (mockup 04).
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var glassGroup: some View {
        if #available(macOS 26.0, *), !GlassTokens.forcesFallback {
            // Below the header / panel gap, so the two stay separate shapes.
            GlassEffectContainer(spacing: 2) {
                stack
            }
        } else {
            stack
        }
    }

    private var stack: some View {
        ZStack(alignment: .bottom) {
            if model.isExpanded {
                RecorderExpandedView(model: model, namespace: glassNamespace)
                    .transition(expandedTransition)
            } else {
                RecorderCompactView(model: model, namespace: glassNamespace)
                    .transition(compactTransition)
            }
        }
    }

    private var expandedTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom))
    }

    private var compactTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .bottom))
    }
}
