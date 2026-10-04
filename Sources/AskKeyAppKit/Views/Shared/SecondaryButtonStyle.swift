import SwiftUI

/// A secondary action: white surface, bordered. Irreversible actions use
/// the warning role for their text.
struct SecondaryButtonStyle: ButtonStyle {
    var irreversible = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.body)
            .foregroundStyle(irreversible ? Theme.warning : Theme.text)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: Theme.controlHeight)
            .background(
                configuration.isPressed ? Theme.neutralSubtle : Theme.surface,
                in: .rect(cornerRadius: Theme.Radius.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .stroke(Theme.neutral(0.16), lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondaryAction: SecondaryButtonStyle { .init() }
    static var irreversibleAction: SecondaryButtonStyle { .init(irreversible: true) }
}
