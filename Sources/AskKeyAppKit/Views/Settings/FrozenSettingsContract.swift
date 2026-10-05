import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum FrozenSettingsContract {
    static var languageOptions: [String] {
        AppLanguage.publishedModes.map { appLocalized(AppLanguage.titleKey(for: $0)) }
    }
    static var agentAccessSubtitle: String { appLocalized("Once connected, an Agent can look up which credentials Ask Key has and request them within the permissions you set.") }
    static var emptyLibraryAction: String { appLocalized("Create First Credential") }

}
