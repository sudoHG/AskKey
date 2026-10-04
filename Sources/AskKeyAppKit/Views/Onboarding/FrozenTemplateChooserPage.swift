import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

struct FrozenTemplateChooserPage: View {
    let onBack: () -> Void
    let onSelect: (CredentialTemplate) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CredentialBackLink(title: appLocalized("Back"), action: onBack)
                Text(appLocalized("What do you want to save?"))
                    .font(Theme.Fonts.title)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, Theme.Spacing.md)
                Text(appLocalized("Choose the closest template. You can add or remove items later."))
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, Theme.Spacing.xs)
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(CredentialTemplate.chooserGroups, id: \.self) { group in
                        VStack(spacing: 0) {
                            ForEach(Array(group.enumerated()), id: \.element) { index, template in
                                templateRow(template)
                                    .overlay(alignment: .top) {
                                        if index > 0 {
                                            Rectangle()
                                                .fill(Theme.separator)
                                                .frame(height: 1)
                                        }
                                    }
                            }
                        }
                        .credentialGroupedListStyle()
                    }
                }
                .padding(.top, Theme.Spacing.xl)
            }
            .padding(Theme.Spacing.xxl)
        }
        .background(Theme.windowBackground)
    }

    private func templateRow(_ template: CredentialTemplate) -> some View {
        Button { onSelect(template) } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: template.symbolName)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.neutralSubtle, in: .rect(cornerRadius: Theme.Radius.control))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.prototypeTitle)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.text)
                    Text(template.prototypeDescription)
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Spacing.sm)
                Image(systemName: "chevron.right")
                    .font(Theme.Fonts.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("credential-template-\(template.rawValue)")
    }
}
