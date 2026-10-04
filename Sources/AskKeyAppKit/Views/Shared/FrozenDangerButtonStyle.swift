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
            .background(Theme.warning.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(.rect(cornerRadius: Theme.Radius.control))
    }
}
