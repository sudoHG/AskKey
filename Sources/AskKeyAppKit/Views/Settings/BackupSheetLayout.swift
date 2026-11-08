import SwiftUI

/// The frame shared by the backup sheets: a title, an optional one-paragraph
/// message, the content, and a bottom row of actions. The actions supply
/// their own `Spacer` to push buttons to the trailing edge.
struct BackupSheetLayout<Content: View, Actions: View>: View {
    let title: String
    var message: String?
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(title)
                    .font(Theme.Fonts.headline)
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            HStack(spacing: Theme.Spacing.sm) {
                actions
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: BackupSheetMetrics.width, alignment: .leading)
        .background(Theme.windowBackground)
    }
}

enum BackupSheetMetrics {
    static let width: CGFloat = 560
    /// The scrolling part of the import preview and result stops growing here.
    static let listMaxHeight: CGFloat = 300
}

/// A warning line with the triangle glyph on the subtle warning surface.
struct BackupNotice: View {
    let text: String
    var isWarning = true

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(Theme.Fonts.secondary)
                .foregroundStyle(isWarning ? Theme.warning : Theme.accent)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .background(isWarning ? Theme.warningSubtle : Theme.accentSubtle, in: .rect(cornerRadius: Theme.Radius.control))
    }
}

/// An inline error under a field or above the actions.
struct BackupErrorText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Fonts.secondary)
            .foregroundStyle(Theme.warning)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("backup-error")
    }
}
