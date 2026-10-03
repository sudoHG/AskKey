import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialWorkspaceRoute {
    var sidebarSelection: CredentialSidebarSelection {
        switch self {
        case .pendingRequests: return .pendingRequests
        case .accessRecords: return .accessRecords
        case .agentAccess: return .agentAccess
        case .recycleBin: return .recycleBin
        case .settings: return .settings
        default: return .credentials
        }
    }
}
