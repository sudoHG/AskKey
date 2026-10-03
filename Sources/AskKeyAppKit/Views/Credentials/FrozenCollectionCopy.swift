import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum FrozenCollectionCopy {
    static var importAction: String { appLocalized("Import from File") }
    static var newCredentialAction: String { appLocalized("New Credential in This Group") }
    static var deleteAction: String { appLocalized("Delete Group…") }
    static var groupActions: [String] { [importAction, newCredentialAction, deleteAction] }
    static var groupSubtitle: String { appLocalized("Groups organize credentials without changing authorization boundaries. New credentials created here join this group.") }
    static var recycleSubtitle: String { appLocalized("Deleted credentials remain for 30 days, then are removed permanently. Agents cannot access the Recycle Bin.") }
    static var recycleEmptyMessage: String { appLocalized("Credentials deleted from details remain here for 30 days.") }

    static func groupEmptyMessage(group: String) -> String {
        appLocalizedFormat("New credentials are added to “%@”. Move existing credentials here from their details.", group)
    }

    static func showsSearch(
        section: CredentialWorkspaceSection,
        hasCredentials: Bool
    ) -> Bool {
        guard hasCredentials else { return false }
        if case .all = section { return true }
        return false
    }
}
