import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum FrozenEraseConfirmationPresentation {
    static var label: String { appLocalized("Type ERASE to confirm") }
    static var confirmationText: String {
        AppLanguage.current == "zh-Hans"
            ? LocalVaultEraseLanguage.simplifiedChinese.confirmationText
            : LocalVaultEraseLanguage.english.confirmationText
    }
    static var placeholder: String { confirmationText }
    static let initialText = ""

    static func accepts(_ text: String) -> Bool {
        text == confirmationText
    }
}
