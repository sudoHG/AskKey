import SwiftUI

/// What the overflow line counts while a capped region hides content.
enum ApprovalOverflowUnit: Equatable {
    case lines(height: CGFloat)
    case steps
    case sections
}

enum ApprovalOverflow {
    /// The line shown while content is hidden below; nil once the end is
    /// visible. Steps are counted; other hidden sections are named.
    static func hint(unit: ApprovalOverflowUnit, hiddenHeight: CGFloat, hiddenSteps: Int = 0,
                     hiddenNames: [String] = []) -> String? {
        guard hiddenHeight > 1 else { return nil }
        if case .lines(let height) = unit {
            let lines = max(1, Int(((hiddenHeight - 1) / max(height, 1)).rounded(.up)))
            return lines == 1
                ? appLocalized("1 more line — scroll to see it")
                : appLocalizedFormat("%lld more lines — scroll to see them", lines)
        }
        if unit == .steps, hiddenSteps > 0 {
            return hiddenSteps == 1
                ? appLocalized("1 more step — scroll to see it")
                : appLocalizedFormat("%lld more steps — scroll to see them", hiddenSteps)
        }
        guard !hiddenNames.isEmpty else { return appLocalized("More below — scroll to see it") }
        return appLocalizedFormat("Below: %@", hiddenNames.joined(separator: appLocalized("List separator")))
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
    @State private var markers: [ApprovalScrollMarkerValue] = []

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
        let hidden = markers.filter { $0.maxY > viewport + 1 }
        var names: [String] = []
        for name in hidden.compactMap(\.name) where !names.contains(name) { names.append(name) }
        return ApprovalOverflow.hint(unit: unit, hiddenHeight: contentFrame.maxY - viewport,
            hiddenSteps: hidden.filter(\.step).count, hiddenNames: names)
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
            Text(verbatim: text).lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.8)
        }
        .font(Theme.Fonts.caption)
        .foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("approval-overflow-hint")
    }
}

extension View {
    /// Marks a section, named in the overflow line, or a counted step.
    func approvalScrollMarker(name: String? = nil, step: Bool = false) -> some View {
        modifier(ApprovalScrollMarker(name: name, step: step))
    }
}

struct ApprovalScrollMarkerValue: Equatable {
    let maxY: CGFloat
    let name: String?
    let step: Bool
}

private struct ApprovalScrollMarker: ViewModifier {
    let name: String?
    let step: Bool
    @Environment(\.approvalScrollSpace) private var space

    func body(content: Content) -> some View {
        content.background(GeometryReader { geometry in
            Color.clear.preference(key: ApprovalScrollMarkerKey.self, value: space.map {
                [$0: [ApprovalScrollMarkerValue(maxY: geometry.frame(in: .named($0)).maxY, name: name, step: step)]]
            } ?? [:])
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
    static let defaultValue: [String: [ApprovalScrollMarkerValue]] = [:]
    static func reduce(value: inout [String: [ApprovalScrollMarkerValue]],
                       nextValue: () -> [String: [ApprovalScrollMarkerValue]]) {
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

    /// A card that would overflow first shrinks the parts that can be
    /// compact, such as the icon, then lets the body scroll.
    private func heights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        func measure(compact: Bool) -> [CGFloat] {
            subviews.map { subview in
                let height = compact ? subview[ApprovalCardCompactHeightKey.self] : nil
                return subview.sizeThatFits(ProposedViewSize(width: width, height: height)).height
            }
        }
        var heights = measure(compact: false)
        if heights.reduce(0, +) > maximumHeight { heights = measure(compact: true) }
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

/// The height a part takes on a card that would otherwise overflow.
struct ApprovalCardCompactHeightKey: LayoutValueKey {
    static let defaultValue: CGFloat? = nil
}
