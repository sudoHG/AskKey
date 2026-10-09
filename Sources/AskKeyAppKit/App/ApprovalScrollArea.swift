import SwiftUI

/// A region that scrolls when its content is taller than the space it gets.
/// While anything is hidden, a thin bar stays visible beside it and the edge
/// where lines continue fades out, so no line looks cut in half.
struct ApprovalScrollArea<Content: View>: View {
    let space: String
    var maxHeight: CGFloat?
    var alignment: Alignment = .leading
    var indicatorOffset: CGFloat = 10
    var identifier: String?
    @ViewBuilder let content: () -> Content
    @State private var contentFrame: CGRect = .zero
    @State private var viewport: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: alignment)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ApprovalScrollContentKey.self,
                        value: [space: geometry.frame(in: .named(space))])
                })
        }
        .scrollIndicators(.never)
        .coordinateSpace(name: space)
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: hiddenAbove ? Self.fade : 0)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: hiddenBelow ? Self.fade : 0)
            }
        }
        .accessibilityIdentifier(identifier ?? space)
        .frame(maxHeight: maxHeight)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: ApprovalScrollViewportKey.self, value: [space: geometry.size.height])
        })
        .overlay(alignment: .topTrailing) {
            if overflows { indicator.offset(x: indicatorOffset) }
        }
        .onPreferenceChange(ApprovalScrollContentKey.self) { contentFrame = $0[space] ?? .zero }
        .onPreferenceChange(ApprovalScrollViewportKey.self) { viewport = $0[space] ?? 0 }
    }

    private static var fade: CGFloat { 24 }
    private var overflows: Bool { contentFrame.height > viewport + 1 && viewport > 0 }
    private var hiddenAbove: Bool { overflows && contentFrame.minY < -1 }
    private var hiddenBelow: Bool { overflows && contentFrame.maxY > viewport + 1 }

    private var indicator: some View {
        let overflow = max(contentFrame.height - viewport, 1)
        let progress = min(1, max(0, -contentFrame.minY / overflow))
        let thumb = max(18, viewport * viewport / max(contentFrame.height, 1))
        return ZStack(alignment: .top) {
            Capsule().fill(Theme.separator).frame(width: 4, height: viewport)
            Capsule().fill(Theme.textTertiary).frame(width: 4, height: thumb)
                .offset(y: progress * (viewport - thumb))
        }
        .frame(width: 4, height: viewport, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// Keyed by area so nested areas never read each other's geometry.
private struct ApprovalScrollContentKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct ApprovalScrollViewportKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Stacks the card's parts like a VStack. When they would outgrow the cap,
/// the scrolling parts give up height in order, lowest value first, so the
/// actions stay visible.
struct ApprovalCardLayout: Layout {
    let maximumHeight: CGFloat
    var minimumFlexibleHeight: CGFloat = 80

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? FrozenAgentApprovalPrompt.contentWidth
        return CGSize(width: width, height: heights(width: width, subviews: subviews).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (subview, height) in zip(subviews, heights(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.midX, y: y), anchor: .top,
                proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
    }

    private func heights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        var heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let flexible = subviews.indices
            .compactMap { index in subviews[index][ApprovalCardFlexibleKey.self].map { (index, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        for index in flexible {
            let excess = heights.reduce(0, +) - maximumHeight
            guard excess > 0 else { break }
            heights[index] = max(min(heights[index], minimumFlexibleHeight), heights[index] - excess)
        }
        return heights
    }
}

/// Marks a scrolling part of the card and the order in which it shrinks.
struct ApprovalCardFlexibleKey: LayoutValueKey {
    static let defaultValue: Int? = nil
}
