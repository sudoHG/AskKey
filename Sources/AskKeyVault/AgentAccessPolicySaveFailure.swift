import Foundation

/// Retained with the process pause so dismissing an alert cannot hide an
/// unsuccessful policy save, or describe a settings change as a user pause.
package struct AgentAccessPolicySaveFailure: Error, LocalizedError, Equatable, Sendable {
    package enum Operation: Equatable, Sendable { case pause, settings, resume }
    package let operation: Operation
    package let persistedStateIsUnknown: Bool
    package let keychainConflict: AppKeychainItemKind?

    init(_ operation: Operation, cause: Error) {
        self.operation = operation
        persistedStateIsUnknown = (cause as? AppKeyStoreError)?.policyMayHaveChanged ?? false
        keychainConflict = (cause as? AppKeyStoreError)?.conflictingItemKind
    }

    package var messageKeys: [String] {
        let message: String
        switch (operation, persistedStateIsUnknown) {
        case (.pause, false):
            message = "Agent access is paused in this run of Ask Key. No policy change was written. The pause may be lost when Ask Key restarts."
        case (.pause, true):
            message = "Agent access is paused in this run of Ask Key, but Ask Key could not verify the saved policy. The pause may be lost when Ask Key restarts."
        case (.settings, false):
            message = "Ask Key could not save the agent access settings. No policy change was written. Agent access stays paused in this run; the pause may be lost when Ask Key restarts."
        case (.settings, true):
            message = "Ask Key could not verify whether the agent access settings were saved. Agent access stays paused in this run because the saved policy is unknown; the pause may be lost when Ask Key restarts."
        case (.resume, false):
            message = "Ask Key could not save the Resume Agent Access change. No policy change was written. Agent access stays paused in this run; the pause may be lost when Ask Key restarts."
        case (.resume, true):
            message = "Ask Key could not verify whether the Resume Agent Access change was saved. Agent access stays paused in this run because the saved policy is unknown; the pause may be lost when Ask Key restarts."
        }
        return [message] + (keychainConflict.map { [$0.conflictMessage] } ?? [])
    }

    package var errorDescription: String? { messageKeys.joined(separator: "\n") }
}
