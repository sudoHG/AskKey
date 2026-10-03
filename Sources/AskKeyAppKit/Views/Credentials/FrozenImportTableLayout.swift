import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

struct FrozenImportTableLayout: Layout {
    static let columnWeights: [CGFloat] = [1, 1.4]
    private let spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == Self.columnWeights.count else { return .zero }
        let width = proposal.width ?? subviews.reduce(spacing) {
            $0 + $1.sizeThatFits(.unspecified).width
        }
        let widths = columnWidths(totalWidth: width)
        let height = zip(subviews, widths).map { subview, width in
            subview.sizeThatFits(.init(width: width, height: proposal.height)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == Self.columnWeights.count else { return }
        let widths = columnWidths(totalWidth: bounds.width)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: .init(width: width, height: bounds.height)
            )
            x += width + spacing
        }
    }

    private func columnWidths(totalWidth: CGFloat) -> [CGFloat] {
        let available = max(0, totalWidth - spacing)
        let totalWeight = Self.columnWeights.reduce(0, +)
        return Self.columnWeights.map { available * $0 / totalWeight }
    }
}
