import AskKeyBroker
import AskKeyVault

struct CredentialLibraryPresentation {
    let credentials: [ManagedTextCredential]
    let allowances: [BrokerTimedAllowance]

    init(credentials: [ManagedTextCredential], allowances: [BrokerTimedAllowance],
         section: CredentialWorkspaceSection, searchText: String) {
        self.allowances = allowances
        self.credentials = credentials.filter { credential in
            switch section {
            case .all: break
            case .accessRecords, .recycleBin, .agentAccess: return false
            case .ungrouped:
                if credential.groupName != nil { return false }
            case .named(let name):
                if credential.groupName != name { return false }
            }
            if searchText.isEmpty { return true }
            let query = searchText.lowercased()
            return credential.name.lowercased().contains(query)
                || (credential.groupName?.lowercased().contains(query) ?? false)
                || credential.usageInstructions.lowercased().contains(query)
        }
    }
}
