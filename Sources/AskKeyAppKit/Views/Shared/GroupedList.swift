import SwiftUI

/// A grouped list: rows on one surface, optionally under a small section
/// header. Replaces walls of equal-weight cards. Put a
/// `GroupedListSeparator` between rows.
struct GroupedList<Content: View>: View {
    var header: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let header {
                Text(header)
                    .font(Theme.Fonts.secondary.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.leading, Theme.Spacing.xs)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                content
            }
            .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
            .clipShape(.rect(cornerRadius: Theme.Radius.group))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.group)
                    .stroke(Theme.separator, lineWidth: 1)
            )
        }
    }
}

/// The inset hairline between two rows of a `GroupedList`.
struct GroupedListSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
            .padding(.leading, Theme.Spacing.lg)
    }
}
