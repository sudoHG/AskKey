import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum CredentialWorkspaceRoute: Equatable {
    case library
    case pendingRequests
    case accessRecords
    case agentAccess
    case recycleBin
    case templateChooser
    case editor(template: CredentialTemplate, credentialID: String?)
    case fileImport
    case credentialDetail(String)
    case settings

}
