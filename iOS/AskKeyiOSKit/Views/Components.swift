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
