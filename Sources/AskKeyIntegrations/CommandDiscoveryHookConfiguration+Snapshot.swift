import Darwin
import Foundation

extension CommandDiscoveryHookConfiguration {
    struct Snapshot: Equatable {
        let bytes: Data
        let mode: UInt32
    }
}
