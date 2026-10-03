import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum CredentialWorkspaceSection: Hashable {
    case all
    case ungrouped
    case named(String)
    case accessRecords
    case recycleBin
    case agentAccess

    var importDestinationGroup: String? {
        if case .named(let name) = self { return name }
        return nil
    }

    var showsCredentialImport: Bool {
        switch self {
        case .all, .ungrouped, .named: return true
        case .accessRecords, .recycleBin, .agentAccess: return false
        }
    }
}
