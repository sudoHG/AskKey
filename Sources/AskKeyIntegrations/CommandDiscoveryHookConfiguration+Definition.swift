import Darwin
import Foundation

extension CommandDiscoveryHookConfiguration {
    struct Definition {
        let root: [String: Any]
        let groups: [String: [[String: Any]]]
        let commands: [String]
        let canonical: Data
    }
}
