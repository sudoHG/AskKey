import SwiftUI

/// What the overflow line counts while a capped region hides content.
enum ApprovalOverflowUnit: Equatable {
    case lines(height: CGFloat)
    case steps
    case sections
}

enum ApprovalOverflow {
    /// The line shown while content is hidden below; nil once the end is visible.
    static func hint(unit: ApprovalOverflowUnit, hiddenHeight: CGFloat, hiddenMarkers: Int) -> String? {
        guard hiddenHeight > 1 else { return nil }
        switch unit {
        case .lines(let height):
            let lines = max(1, Int(((hiddenHeight - 1) / max(height, 1)).rounded(.up)))
            return lines == 1
                ? appLocalized("1 more line — scroll to see it")
                : appLocalizedFormat("%lld more lines — scroll to see them", lines)
        case .steps where hiddenMarkers > 0:
            return hiddenMarkers == 1
                ? appLocalized("1 more step — scroll to see it")
                : appLocalizedFormat("%lld more steps — scroll to see them", hiddenMarkers)
        case .sections where hiddenMarkers > 0:
            return hiddenMarkers == 1
                ? appLocalized("1 more section below — scroll to see it")
                : appLocalizedFormat("%lld more sections below — scroll to see them", hiddenMarkers)
        case .steps, .sections:
            return appLocalized("More below — scroll to see it")
        }
    }
}

/// A capped region that never cuts content silently: while its content is
/// taller than the space it gets, a scroll bar stays visible and a line under
/// it says how much is still below.
struct ApprovalScrollArea<Content: View>: View {
    let space: String
    let unit: ApprovalOverflowUnit
    var maxHeight: CGFloat?
    var indicatorOffset: CGFloat = 10
    var identifier: String?
    @ViewBuilder let content: (ScrollViewProxy) -> Content
    @State private var contentFrame: CGRect = .zero
    @State private var viewport: CGFloat = 0
    @State private var markers: [CGFloat] = []

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            ScrollViewReader { proxy in
                ScrollView {
                    content(proxy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.approvalScrollSpace, space)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: ApprovalScrollContentKey.self,
                                value: [space: geometry.frame(in: .named(space))])
                        })
                }
                .scrollIndicators(.never)
                .coordinateSpace(name: space)
                .accessibilityIdentifier(identifier ?? space)
                .frame(maxHeight: maxHeight)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ApprovalScrollViewportKey.self, value: [space: geometry.size.height])
                })
            }
            .overlay(alignment: .topTrailing) {
                if overflows { indicator.offset(x: indicatorOffset) }
            }
            // Stays while the content overflows so the region never jumps.
            if overflows { hintLabel(hint ?? appLocalized("Reached the end")) }
        }
        .onPreferenceChange(ApprovalScrollContentKey.self) { contentFrame = $0[space] ?? .zero }
        .onPreferenceChange(ApprovalScrollViewportKey.self) { viewport = $0[space] ?? 0 }
        .onPreferenceChange(ApprovalScrollMarkerKey.self) { markers = $0[space] ?? [] }
    }

    private var overflows: Bool { contentFrame.height > viewport + 1 && viewport > 0 }

    private var hint: String? {
        ApprovalOverflow.hint(unit: unit, hiddenHeight: contentFrame.maxY - viewport,
            hiddenMarkers: markers.filter { $0 > viewport + 1 }.count)
    }

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

    private func hintLabel(_ text: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            if hint != nil { Image(systemName: "chevron.down").imageScale(.small) }
            Text(verbatim: text)
        }
        .font(Theme.Fonts.caption)
        .foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("approval-overflow-hint")
    }
}

extension View {
    /// Marks a step or section whose bottom edge the overflow line counts.
    func approvalScrollMarker() -> some View { modifier(ApprovalScrollMarker()) }
}

private struct ApprovalScrollMarker: ViewModifier {
    @Environment(\.approvalScrollSpace) private var space

    func body(content: Content) -> some View {
        content.background(GeometryReader { geometry in
            Color.clear.preference(key: ApprovalScrollMarkerKey.self,
                value: space.map { [$0: [geometry.frame(in: .named($0)).maxY]] } ?? [:])
        })
    }
}

private struct ApprovalScrollSpaceKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private extension EnvironmentValues {
    var approvalScrollSpace: String? {
        get { self[ApprovalScrollSpaceKey.self] }
        set { self[ApprovalScrollSpaceKey.self] = newValue }
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

private struct ApprovalScrollMarkerKey: PreferenceKey {
    static let defaultValue: [String: [CGFloat]] = [:]
    static func reduce(value: inout [String: [CGFloat]], nextValue: () -> [String: [CGFloat]]) {
        value.merge(nextValue()) { $0 + $1 }
    }
}

/// Stacks the card's parts and gives the one flexible part, the scrolling
/// body, whatever height remains under the cap, so the actions stay visible.
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
        let excess = heights.reduce(0, +) - maximumHeight
        if excess > 0, let index = subviews.firstIndex(where: { $0[ApprovalCardFlexibleKey.self] }) {
            heights[index] = max(minimumFlexibleHeight, heights[index] - excess)
        }
        return heights
    }
}

struct ApprovalCardFlexibleKey: LayoutValueKey {
    static let defaultValue = false
}
