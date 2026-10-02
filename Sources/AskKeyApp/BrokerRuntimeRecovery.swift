import Foundation
import AskKeyBroker

enum BrokerRuntimeFailure {
    static func userFacing(for error: Error) -> (message: String, canRetry: Bool) {
        switch error {
        case BrokerFileWriteError.stagingNotADirectory:
            return (
                "Ask Key could not start Agent access because the secure staging folder is a file. Remove that file, then retry.",
                true
            )
        case BrokerFileWriteError.stagingPermissionDenied:
            return (
                "Ask Key could not start Agent access because it cannot write the secure staging folder. Fix folder permissions, then retry.",
                true
            )
        default:
            return (
                "Ask Key could not start Agent access. Check the local Ask Key folder, then retry.",
                true
            )
        }
    }
}

struct BrokerRuntimeRecovery {
    var isRunning: () -> Bool
    var start: () throws -> Void

    mutating func retry() -> Bool {
        guard !isRunning() else { return false }
        do {
            try start()
            return true
        } catch {
            return false
        }
    }
}
