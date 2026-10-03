import Foundation
import Darwin

extension RestrictedProcess {
    package enum Failure: Error, Equatable {
        case cancelled
        case inputTooLarge
        case outputTooLarge
        case spawnFailed(POSIXErrorCode)
        case ioFailed(POSIXErrorCode)

        package var posixError: POSIXError {
            switch self {
            case .cancelled:
                return POSIXError(.ECANCELED)
            case .inputTooLarge, .outputTooLarge:
                return POSIXError(.EIO)
            case .spawnFailed(let code), .ioFailed(let code):
                return POSIXError(code)
            }
        }

        static func capturedSpawn(_ code: Int32 = errno) -> Failure {
            .spawnFailed(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        static func capturedIO(_ code: Int32 = errno) -> Failure {
            .ioFailed(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
