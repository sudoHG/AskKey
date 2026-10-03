import Darwin
import Foundation

extension CodexDiscoveryHookConfiguration {
    struct HookGroupMatch {
        let eventName: String
        let group: [String: Any]
    }
}
