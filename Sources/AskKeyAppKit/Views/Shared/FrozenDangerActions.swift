import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum FrozenDangerActions {
    static var initialTitles: [String] { [
        appLocalized("Delete Group…"), appLocalized("Delete Permanently…"), appLocalized("Delete…"), appLocalized("Pause Agent Access"), appLocalized("Clear Records…"),
    ] }
    static var groupConfirmationTitle: String { appLocalized("Confirm Group Deletion") }
    static var credentialConfirmationTitle: String { appLocalized("Move to Recycle Bin") }
    static var recordsConfirmationTitle: String { appLocalized("Confirm Clear") }
    static var permanentCredentialConfirmationTitle: String {
        appLocalized("Confirm Permanent Deletion")
    }
    static var confirmationTitles: [String] { [
        groupConfirmationTitle, credentialConfirmationTitle, recordsConfirmationTitle,
    ] }
}
