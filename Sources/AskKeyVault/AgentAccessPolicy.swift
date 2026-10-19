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
    let hasVerifiedPolicy: Bool
    package let isPaused: Bool
    package let pauseNotPersisted: Bool
    package let saveFailure: AgentAccessPolicySaveFailure?
    package let keychainConflict: AppKeychainItemKind?

    package init(policy: AgentAccessPolicy, needsRecovery: Bool, isPaused: Bool? = nil, pauseNotPersisted: Bool = false,
                 saveFailure: AgentAccessPolicySaveFailure? = nil, keychainConflict: AppKeychainItemKind? = nil,
                 readUnavailable: Bool = false, hasVerifiedPolicy: Bool = true) {
        self.policy = policy
        self.needsRecovery = needsRecovery
        self.readUnavailable = readUnavailable
        self.hasVerifiedPolicy = hasVerifiedPolicy
        self.isPaused = isPaused ?? (policy.paused || readUnavailable)
        self.pauseNotPersisted = pauseNotPersisted
        self.saveFailure = saveFailure
        self.keychainConflict = keychainConflict
    }
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

    var errorDescription: String? {
        switch self {
        case .invalidPolicy:
            return "Agent access settings are invalid."
        case .recoveryRequired:
            return "Agent access was paused because its saved settings were missing or changed outside Ask Key. Resume Agent Access to restore the default settings."
        case .unreadable:
            return "Ask Key could not read the saved agent access settings. Allow Keychain access, then try again."
        case .notOwner:
            return "This Ask Key instance does not own Agent access for this library. Change settings in the running instance."
        }
    }
}

extension Notification.Name {
    package static let askKeyAgentAccessPolicyDidChange = Notification.Name("askKeyAgentAccessPolicyDidChange")
}
