import SwiftUI

/// Puts its subviews side by side in equal columns of equal height when the offered width allows
/// `minColumnWidth` per column, and stacks them full width otherwise (the "Oryginał" / "Po AI"
/// cards of a history row). Decides from the proposal itself, so there is no one-frame jump from
/// a measured width.
struct HistoryVersionLayout: Layout {
    var minColumnWidth: CGFloat = 250
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width
        if let width, isSideBySide(width: width, count: subviews.count) {
            let column = columnWidth(width, count: subviews.count)
            return CGSize(width: width, height: rowHeight(subviews, column: column))
        }
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        let height = sizes.map(\.height).reduce(0, +) + spacing * CGFloat(subviews.count - 1)
        return CGSize(width: width ?? sizes.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        if isSideBySide(width: bounds.width, count: subviews.count) {
            let column = columnWidth(bounds.width, count: subviews.count)
            let height = rowHeight(subviews, column: column)
            for (index, subview) in subviews.enumerated() {
                let x = bounds.minX + CGFloat(index) * (column + spacing)
                subview.place(
                    at: CGPoint(x: x, y: bounds.minY),
                    proposal: ProposedViewSize(width: column, height: height)
                )
            }
            return
        }
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: size.height))
            y += size.height + spacing
        }
    }

    private func isSideBySide(width: CGFloat, count: Int) -> Bool {
        count > 1 && columnWidth(width, count: count) >= minColumnWidth
    }

    private func columnWidth(_ width: CGFloat, count: Int) -> CGFloat {
        (width - spacing * CGFloat(count - 1)) / CGFloat(count)
    }

    private func rowHeight(_ subviews: Subviews, column: CGFloat) -> CGFloat {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
    }
}
