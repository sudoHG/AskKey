import SwiftUI

/// The one status label a row may carry: a dot and text in one of the three
/// color roles.
struct StatusLabel: View {
    enum Role: Equatable {
        case neutral
        case accent
        case warning
    }

    let title: String
    let role: Role

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Circle()
                .fill(foreground)
                .frame(width: 6, height: 6)
            Text(title)
                .lineLimit(1)
        }
        .font(Theme.Fonts.secondary.weight(.medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 3)
        .background(background, in: Capsule())
        .fixedSize()
    }

    private var foreground: Color {
        switch role {
        case .neutral: return Theme.textSecondary
        case .accent: return Theme.accent
        case .warning: return Theme.warning
        }
    }

    private var background: Color {
        switch role {
        case .neutral: return Theme.neutralSubtle
        case .accent: return Theme.accentSubtle
        case .warning: return Theme.warningSubtle
        }
    }
}
