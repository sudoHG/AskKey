import SwiftUI

private final class KitBundleToken {}

extension Bundle {
    /// The framework's bundle, which holds the String Catalog.
    static let kit = Bundle(for: KitBundleToken.self)
}

/// One screen's content: a title, an optional subtitle and a column of
/// sections. The content is drawn by SwiftUI alone, so the same view that
/// the app shows can be rendered for review.
struct ScreenContent<Content: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title, bundle: .kit)
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle, bundle: .kit)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A rounded block of text with a symbol, for instructions and outcomes.
struct NoticeCard: View {
    enum Tone {
        case info
        case warning
        case success
    }

    let symbol: String
    var tone: Tone = .info
    let text: Text

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
            text
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(color.opacity(0.1)))
    }

    private var color: Color {
        switch tone {
        case .info: return .accentColor
        case .warning: return .orange
        case .success: return .green
        }
    }
}

/// A full-width button drawn by SwiftUI.
struct ActionButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case destructive
    }

    var kind: Kind = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(background))
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.45))
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return .accentColor
        case .destructive: return .red
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return .accentColor
        case .secondary: return Color.accentColor.opacity(0.12)
        case .destructive: return Color.red.opacity(0.12)
        }
    }
}

extension View {
    /// Wraps a screen's content for the app: scrollable on a grouped background.
    func screenScaffold() -> some View {
        ScrollView {
            self
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }
}

extension View {
    /// Wraps a tab's content for the app: scrollable on a grouped background
    /// and at least as tall as the visible area, so an empty state centers
    /// itself in the space below any banner.
    func tabScaffold() -> some View {
        GeometryReader { proxy in
            ScrollView {
                self.frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }
}

// MARK: Grouped lists

/// An inset grouped section in the iOS style, drawn by SwiftUI alone so the
/// screens that use it render for review exactly as the app shows them: an
/// optional header, the rows on one rounded card, and an optional footer.
/// Rows separate themselves with `GroupedDivider`.
struct GroupedSection<Content: View, Footer: View>: View {
    var header: Text?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let header {
                header
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous))
            footer
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
        }
    }
}

extension GroupedSection where Footer == EmptyView {
    init(header: Text? = nil, @ViewBuilder content: () -> Content) {
        self.init(header: header, content: content) { EmptyView() }
    }
}

enum GroupedMetrics {
    static let cornerRadius: CGFloat = 26
    static let rowMinHeight: CGFloat = 52
    /// The leading inset of a row's divider when the row starts with a symbol.
    static let symbolInset: CGFloat = 62
}

/// The hairline between two rows of a section.
struct GroupedDivider: View {
    var leadingInset: CGFloat = 16

    var body: some View {
        Divider().padding(.leading, leadingInset)
    }
}

/// A tappable row: the whole row is the target, and it is shaded while pressed.
struct GroupedRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Color(uiColor: .systemFill) : Color.clear)
    }
}

/// The disclosure chevron at a navigating row's trailing edge.
struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// A row with a label and a value; the value moves below the label when
/// both do not fit on one line, as with large Dynamic Type sizes.
struct ValueRow<Title: View, Value: View>: View {
    var symbol: String?
    var symbolColor: Color = .secondary
    @ViewBuilder var label: Title
    @ViewBuilder var value: Value

    var body: some View {
        HStack(spacing: 14) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(symbolColor)
                    .frame(width: 32)
                    .accessibilityHidden(true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    label.foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    value
                }
                VStack(alignment: .leading, spacing: 2) {
                    label.foregroundStyle(.primary)
                    value
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: GroupedMetrics.rowMinHeight)
        .accessibilityElement(children: .combine)
    }
}

/// A problem that needs Settings, at the top of a tab: an orange symbol, one
/// sentence and **Open Settings**.
struct BannerRow: View {
    let symbol: String
    let text: Text
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                text
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onOpenSettings) { Text("common.openSettings", bundle: .kit) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .buttonBorderShape(.capsule)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .accessibilityElement(children: .contain)
    }
}

/// A tab's empty state: a symbol in a circle, a title, one sentence, and an
/// optional accessory below.
struct EmptyStateView<Accessory: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @ViewBuilder var accessory: Accessory
    @ScaledMetric(relativeTo: .largeTitle) private var circle: CGFloat = 72

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .frame(width: circle, height: circle)
                .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            Text(title, bundle: .kit)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(detail, bundle: .kit)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            accessory
                .padding(.top, 10)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}

extension EmptyStateView where Accessory == EmptyView {
    init(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

/// **Pair a Mac**, the primary action of an empty list.
struct PairButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label { Text("list.pair", bundle: .kit) } icon: { Image(systemName: "qrcode.viewfinder") }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }
}

/// A time before `now` in words, such as "2 min. ago", in the screen's language.
enum RelativeTime {
    static func text(_ date: Date, now: Date, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}
