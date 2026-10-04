import SwiftUI

/// One option of a `GlassSegmentedPicker`.
struct GlassSegment<Value: Hashable>: Identifiable {
    var value: Value
    var title: Text
    var systemImage: String?

    var id: Value { value }

    init(_ value: Value, title: Text, systemImage: String? = nil) {
        self.value = value
        self.title = title
        self.systemImage = systemImage
    }

    init(_ value: Value, _ title: LocalizedStringKey, systemImage: String? = nil) {
        self.init(value, title: Text(title), systemImage: systemImage)
    }
}

/// Segmented control restyled as a glass capsule: recessed track, brighter glass pill under the
/// selection that slides with a spring (no slide with Reduce Motion).
@MainActor
struct GlassSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    var segments: [GlassSegment<Value>]
    /// Equal-width segments filling the available width, or hugging their titles.
    var fillsWidth: Bool

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(selection: Binding<Value>, segments: [GlassSegment<Value>], fillsWidth: Bool = false) {
        _selection = selection
        self.segments = segments
        self.fillsWidth = fillsWidth
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                segmentButton(segment)
            }
        }
        .padding(3)
        .glassSurface(.track, in: Capsule(), shadow: false)
        .fixedSize(horizontal: !fillsWidth, vertical: true)
        .accessibilityElement(children: .contain)
    }

    private func segmentButton(_ segment: GlassSegment<Value>) -> some View {
        let isSelected = segment.value == selection
        return Button {
            if reduceMotion {
                selection = segment.value
            } else {
                withAnimation(GlassMotion.selection) {
                    selection = segment.value
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let systemImage = segment.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                }
                segment.title
                    .lineLimit(1)
            }
            .font(GlassFont.segment)
            .foregroundStyle(isSelected ? GlassColor.textPrimary : GlassColor.textSecondary)
            .padding(.horizontal, 14)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: GlassTokens.Size.segmentHeight - 6)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.white.opacity(GlassTokens.Opacity.selection))
                        .overlay { Capsule().strokeBorder(GlassColor.rim(top: 0.5, bottom: 0.08), lineWidth: 1) }
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension GlassSegmentedPicker where Value: CaseIterable, Value.AllCases: RandomAccessCollection {
    /// Every case of `Value` in declaration order; `title` returns an already localized string.
    init(
        selection: Binding<Value>,
        fillsWidth: Bool = false,
        title: (Value) -> String,
        systemImage: (Value) -> String? = { _ in nil }
    ) {
        self.init(
            selection: selection,
            segments: Value.allCases.map { GlassSegment($0, title: Text(title($0)), systemImage: systemImage($0)) },
            fillsWidth: fillsWidth
        )
    }
}
