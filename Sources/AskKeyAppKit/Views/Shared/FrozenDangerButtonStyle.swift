import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

struct FrozenDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.secondary.weight(.semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: 30)
            .background(Theme.warning.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(.rect(cornerRadius: 7))
    }
}
