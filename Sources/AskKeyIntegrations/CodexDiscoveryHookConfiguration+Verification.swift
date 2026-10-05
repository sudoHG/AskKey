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
        return matches.count == Self.expectedEvents.count && matches.allSatisfy { !$0.legacy }
    }
}
