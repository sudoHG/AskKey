import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum CredentialEditorInteractionPresentation {
    static func inputVisibility(
        template: CredentialTemplate,
        isSecret: Bool,
        isRevealed: Bool
    ) -> CredentialEditorInputVisibility {
        template == .custom || !isSecret || isRevealed ? .plain : .secure
    }
}
