import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum FrozenSettingsContract {
    static var languageOptions: [String] {
        AppLanguage.publishedModes.map { appLocalized(AppLanguage.titleKey(for: $0)) }
    }
    static var agentAccessSubtitle: String { appLocalized("Choose a client. Review how it connects, then decide whether to check or configure.") }
    static var emptyLibraryAction: String { appLocalized("Create First Credential") }

}
