import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum CredentialEmptyPresentation {
    static func title(section: CredentialWorkspaceSection, searchText: String) -> String {
        if !searchText.isEmpty { return appLocalized("No Matching Credentials") }
        switch section {
        case .all: return appLocalized("No credentials yet")
        case .ungrouped: return appLocalized("No ungrouped credentials")
        default: return appLocalized("This group is empty")
        }
    }

    static func message(section: CredentialWorkspaceSection, searchText: String) -> String {
        if !searchText.isEmpty { return appLocalized("Try a different search term.") }
        switch section {
        case .all:
            return appLocalized("Create one, or import from a file / .env. Agents can request it after it is saved.")
        case .ungrouped:
            return appLocalized("All credentials are grouped, or there are no credentials yet.")
        case .named(let name):
            return FrozenCollectionCopy.groupEmptyMessage(group: name)
        default:
            return appLocalized("New credentials created here are added directly to this group.")
        }
    }

    static func action(section: CredentialWorkspaceSection, searchText: String) -> String? {
        guard searchText.isEmpty else { return nil }
        switch section {
        case .all: return FrozenSettingsContract.emptyLibraryAction
        case .named: return appLocalized("New Credential in This Group")
        default: return nil
        }
    }
}
