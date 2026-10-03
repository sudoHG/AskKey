import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum CredentialSidebarSelection: Equatable {
    case credentials
    case pendingRequests
    case accessRecords
    case agentAccess
    case recycleBin
    case settings
}
