import Darwin
import Foundation

extension CommandDiscoveryHookConfiguration {
    struct Match {
        let event: String
        let exact: Bool
        let ownLike: Bool
    }
}
