import Darwin
import Foundation

extension CodexDiscoveryHookConfiguration {
    public func hasExpectedHook() throws -> Bool {
        mutationLock.lock()
        defer { mutationLock.unlock() }

        guard let snapshot = try readHooksSnapshot() else { return false }
        let document = try parseDocument(snapshot.bytes)
        let matches = try matchingHookGroups(in: document)
        try validateOwnHook(matches)
        guard let own = matches.first else { return false }
        guard own.eventName == "PreToolUse", jsonEqual(own.group, Self.expectedHookGroup) else {
            throw CodexDiscoveryHookConfigurationError.customHookMismatch
        }
        return true
    }
}
