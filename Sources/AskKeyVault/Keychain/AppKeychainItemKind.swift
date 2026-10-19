import Foundation

package enum AppKeychainItemKind: Equatable, Sendable {
    case vaultKey, pendingKey, legacyKey, agentAccessPolicy

    package var conflictMessage: String {
        switch self {
        case .vaultKey:
            return "Ask Key found a vault-key item outside login.keychain-db or duplicate vault-key items. Quit Ask Key. In Keychain Access, move the original Ask Key vault key to the login keychain and remove only verified duplicates, then reopen Ask Key. Do not delete your only vault key."
        case .pendingKey:
            return "Ask Key found a pending vault-key item outside login.keychain-db or duplicate pending vault-key items. Quit Ask Key. In Keychain Access, move the original Ask Key pending key to the login keychain and remove only verified duplicates, then reopen Ask Key. Keep the original key."
        case .legacyKey:
            return "Ask Key found a legacy vault-key item outside login.keychain-db or duplicate legacy vault-key items. Quit Ask Key. In Keychain Access, move the original Ask Key legacy key to the login keychain and remove only verified duplicates, then reopen Ask Key. Keep the original key."
        case .agentAccessPolicy:
            return "Ask Key found an agent-access-policy item outside login.keychain-db or duplicate policy items. Quit Ask Key. In Keychain Access, remove the conflicting Ask Key agent-access-policy items, then reopen Ask Key and use Resume Agent Access. Do not remove vault-key items."
        }
    }
}
