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
                    .foregroundStyle(Theme.brand)
                    .font(.system(size: 12.5, weight: .medium))
                Text(appLocalized("What do you want to save?"))
                    .font(.system(size: 20, weight: .bold))
                    .padding(.top, 16)
                Text(appLocalized("Choose the closest template. You can add or remove items later."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, 4)
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
                    ForEach(CredentialTemplate.allCases, id: \.self) { template in
                        Button { onSelect(template) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(template.prototypeTitle)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                Text(template.prototypeDescription)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                            .padding(14)
                            .background(Theme.panelBackground, in: .rect(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.neutral(0.08)))
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
