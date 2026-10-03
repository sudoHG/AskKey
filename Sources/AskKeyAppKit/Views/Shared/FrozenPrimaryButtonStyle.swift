import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

struct FrozenPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.brand.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(.rect(cornerRadius: 7))
    }
}
