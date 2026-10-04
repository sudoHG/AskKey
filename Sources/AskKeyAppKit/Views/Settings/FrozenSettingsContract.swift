import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum FrozenSettingsContract {
    static var languageOptions: [String] {
        AppLanguage.publishedModes.map { appLocalized(AppLanguage.titleKey(for: $0)) }
    }
    static var agentAccessSubtitle: String { appLocalized("Once connected, an Agent first looks up which credentials Ask Key has, then asks within the permissions you set.") }
    static var emptyLibraryAction: String { appLocalized("Create First Credential") }

}
