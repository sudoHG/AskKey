import Foundation
import Darwin

extension RestrictedProcess {
    package struct Result: Equatable, Sendable {
        package var status: Int32
        package var stdout: Data
        package var stderr: Data
        package var timedOut: Bool
    }
}
