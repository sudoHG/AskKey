import Foundation

package enum AppKeychainItemKind: Equatable, Sendable {
    case vaultKey, pendingKey, legacyKey, agentAccessPolicy
    case deviceMessageKey, deviceAgreementKey, deviceApprovalKey, pairedDevices

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
        case .deviceMessageKey:
            return "Ask Key found a device-message-key item outside login.keychain-db or duplicate device-message-key items. Quit Ask Key. In Keychain Access, remove the Ask Key device-message-key items that are not in the login keychain, then reopen Ask Key. If Devices then reports that this Mac's device identity is unusable, reset it and pair your devices again. Do not remove vault-key items."
        case .deviceAgreementKey:
            return "Ask Key found a device-agreement-key item outside login.keychain-db or duplicate device-agreement-key items. Quit Ask Key. In Keychain Access, remove the Ask Key device-agreement-key items that are not in the login keychain, then reopen Ask Key. If Devices then reports that this Mac's device identity is unusable, reset it and pair your devices again. Do not remove vault-key items."
        case .deviceApprovalKey:
            return "Ask Key found a device-approval-key item outside login.keychain-db or duplicate device-approval-key items. Quit Ask Key. In Keychain Access, remove the Ask Key device-approval-key items that are not in the login keychain, then reopen Ask Key. If Devices then reports that this Mac's device identity is unusable, reset it and pair your devices again. Do not remove vault-key items."
        case .pairedDevices:
            return "Ask Key found a paired-devices item outside login.keychain-db or duplicate paired-devices items. Quit Ask Key. In Keychain Access, remove the conflicting Ask Key paired-devices items, then reopen Ask Key and pair your devices again. Do not remove vault-key items."
        }
    }
}

/// The device items under the existing App service (ADR 0013 → Identifiers):
/// the three Secure Enclave key blobs and the authenticated paired-device
/// list. Every device helper names its account explicitly.
package enum DeviceKeychainAccount: String, CaseIterable, Sendable {
    case messageKey = "device-message-key"
    case agreementKey = "device-agreement-key"
    case approvalKey = "device-approval-key"
    case pairedDevices = "paired-devices"

    package var itemKind: AppKeychainItemKind {
        switch self {
        case .messageKey: return .deviceMessageKey
        case .agreementKey: return .deviceAgreementKey
        case .approvalKey: return .deviceApprovalKey
        case .pairedDevices: return .pairedDevices
        }
    }

    /// The largest item a store accepts: a key blob is a few hundred bytes
    /// and a list of 8 devices a few kilobytes.
    static let maximumItemSize = 65_536
}
