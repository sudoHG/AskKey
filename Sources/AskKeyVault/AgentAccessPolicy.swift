import Foundation

/// App-owned settings authenticated together as one value in the library.
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
}

package struct AgentAccessPolicyState: Equatable, Sendable {
    package let policy: AgentAccessPolicy
    package let needsRecovery: Bool

    package init(policy: AgentAccessPolicy, needsRecovery: Bool) {
        self.policy = policy
        self.needsRecovery = needsRecovery
    }
}

enum AgentAccessPolicyError: Error, LocalizedError {
    case invalidPolicy
    case recoveryRequired

    var errorDescription: String? {
        switch self {
        case .invalidPolicy:
            return "Agent access settings are invalid."
        case .recoveryRequired:
            return "Agent access was paused because its saved settings were missing or changed outside Ask Key. Resume Agent Access to restore the default settings."
        }
    }
}
