import Foundation
import Darwin

extension RestrictedProcess {
    package enum InteractiveFailure: Error, Equatable {
        case cancelled
        case timedOut
        case inputTooLarge
        case outputTooLarge
        case processExited(Int32)
        case spawnFailed(POSIXErrorCode)
        case ioFailed(POSIXErrorCode)

        static func capturedSpawn(_ code: Int32 = errno) -> Self {
            .spawnFailed(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        static func capturedIO(_ code: Int32 = errno) -> Self {
            .ioFailed(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
