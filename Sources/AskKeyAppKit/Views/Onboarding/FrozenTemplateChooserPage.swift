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
                Button(appLocalized("← Back"), action: onBack)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .font(Theme.Fonts.secondary)
                Text(appLocalized("What do you want to save?"))
                    .font(Theme.Fonts.title)
                    .padding(.top, Theme.Spacing.lg)
                Text(appLocalized("Choose the closest template. You can add or remove items later."))
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, Theme.Spacing.xs)
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
                    ForEach(CredentialTemplate.allCases, id: \.self) { template in
                        Button { onSelect(template) } label: {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                Text(template.prototypeTitle)
                                    .font(Theme.Fonts.body.weight(.semibold))
                                    .foregroundStyle(Theme.text)
                                Text(template.prototypeDescription)
                                    .font(Theme.Fonts.secondary)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                            .padding(14)
                            .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.neutral(0.08)))
                            .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 20)
            }
            .padding(28)
        }
        .background(Theme.windowBackground)
    }
}
