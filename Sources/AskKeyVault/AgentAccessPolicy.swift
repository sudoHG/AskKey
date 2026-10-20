import Foundation

/// App-owned settings authenticated together in an App-only Keychain item.
package struct AgentAccessPolicy: Codable, Equatable, Sendable {
    var formatVersion = 1
    package var paused: Bool
    package var readApprovalAuthentication: Bool
    package var timedAllowanceEnabled: Bool
    package var timedAllowanceMinutes: Int

    package static let defaults = AgentAccessPolicy(
        paused: false, readApprovalAuthentication: true,
        timedAllowanceEnabled: true, timedAllowanceMinutes: 30
    )

    package static let failClosed = AgentAccessPolicy(
        paused: true, readApprovalAuthentication: true,
        timedAllowanceEnabled: false, timedAllowanceMinutes: 30
    )

    func validate() throws {
        guard formatVersion == 1,
              Vault.allowedTimedAllowanceMinutes.contains(timedAllowanceMinutes) else {
            throw AgentAccessPolicyError.invalidPolicy
        }
    }

    func restricted(by other: Self) -> Self {
        Self(paused: paused || other.paused,
             readApprovalAuthentication: readApprovalAuthentication || other.readApprovalAuthentication,
             timedAllowanceEnabled: timedAllowanceEnabled && other.timedAllowanceEnabled,
             timedAllowanceMinutes: min(timedAllowanceMinutes, other.timedAllowanceMinutes))
    }
}

package struct AgentAccessPolicyState: Equatable, Sendable {
    package let policy: AgentAccessPolicy
    package let needsRecovery: Bool
    let readUnavailable: Bool
    package let readFailure: AgentAccessPolicyReadFailure?
    let hasVerifiedPolicy: Bool
    package let isPaused: Bool
    package let pauseNotPersisted: Bool
    package let saveFailure: AgentAccessPolicySaveFailure?
    package let keychainConflict: AppKeychainItemKind?

    package init(policy: AgentAccessPolicy, needsRecovery: Bool, isPaused: Bool? = nil, pauseNotPersisted: Bool = false,
                 saveFailure: AgentAccessPolicySaveFailure? = nil, keychainConflict: AppKeychainItemKind? = nil,
                 readUnavailable: Bool = false, hasVerifiedPolicy: Bool = true,
                 readFailure: AgentAccessPolicyReadFailure? = nil) {
        self.policy = policy
        self.needsRecovery = needsRecovery
        self.readUnavailable = readUnavailable
        self.readFailure = readUnavailable ? (readFailure ?? .unavailable) : nil
        self.hasVerifiedPolicy = hasVerifiedPolicy
        self.isPaused = isPaused ?? (policy.paused || readUnavailable)
        self.pauseNotPersisted = pauseNotPersisted
        self.saveFailure = saveFailure
        self.keychainConflict = keychainConflict
    }
}

package enum AgentAccessPolicyReadFailure: Error, LocalizedError, Equatable, Sendable {
    case unavailable, accessDenied

    package var messageKey: String {
        switch self {
        case .unavailable:
            return "Ask Key could not read the saved agent access settings. Allow Keychain access, then try again."
        case .accessDenied:
            return "The keychain is unlocked, but this Ask Key build cannot read the saved Agent access policy. Review that item's access control in Keychain Access; do not delete vault keys."
        }
    }

    package var errorDescription: String? { messageKey }
}

struct AgentAccessPolicyLatches {
    var pause = false
    var pausePersisted = false
    var recovery = false
    var saveFailure: AgentAccessPolicySaveFailure?
}

enum AgentAccessPolicyError: Error, LocalizedError {
    case invalidPolicy
    case recoveryRequired
    case unreadable
    case notOwner
    case ownershipRevoked

    var isOwnershipFailure: Bool {
        switch self {
        case .notOwner, .ownershipRevoked: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidPolicy:
            return "Agent access settings are invalid."
        case .recoveryRequired:
            return "Agent access is paused until its settings are confirmed. This is needed once after updating to 0.3.2, or when saved settings cannot be verified. Choose Resume Agent Access and complete system authentication to restore the defaults: authentication for read approvals and 30-minute timed allowances. You can change these in Settings afterwards."
        case .unreadable:
            return "Ask Key could not read the saved agent access settings. Allow Keychain access, then try again."
        case .notOwner:
            return "This Ask Key instance does not own Agent access for this library. Change settings in the running instance."
        case .ownershipRevoked:
            return "This Ask Key instance has stopped serving this library because socket ownership could not be verified. Agent access is paused here. Check the local Ask Key folder, then retry."
        }
    }
}

extension Notification.Name {
    package static let askKeyAgentAccessPolicyDidChange = Notification.Name("askKeyAgentAccessPolicyDidChange")
}
