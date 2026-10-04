import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

struct FrozenDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.body.weight(.medium))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: Theme.controlHeight)
            // A shape background stays inside the label's frame; a plain color
            // background would extend into the title-bar safe area near the
            // top edge and stretch the button's hit and accessibility frame.
            .background(
                Theme.warning.opacity(configuration.isPressed ? 0.78 : 1),
                in: .rect(cornerRadius: Theme.Radius.control)
            )
            .contentShape(.rect(cornerRadius: Theme.Radius.control))
    }
}
