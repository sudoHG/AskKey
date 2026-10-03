import Foundation
import Darwin

// Connection and stopped are accessed only on the session's serial queue.
final class BrokerSignalState: @unchecked Sendable {
    enum Connection {
        case runtime(controlFD: Int32, socketFD: Int32)
        case request(socketFD: Int32)
    }

    let cancellation = BrokerCancellation()
    let receivedSignal = DispatchSemaphore(value: 0)
    var connection: Connection?
    var stopped = false

    func checkCancellation() throws {
        guard !stopped else { throw BrokerCancellationError.cancelled }
        try cancellation.check()
    }

    func receive(_ signalNumber: Int32) {
        guard !stopped else { return }
        cancellation.cancel()
        receivedSignal.signal()
        switch connection {
        case .runtime(let controlFD, let socketFD):
            var value = UInt8(signalNumber)
            if write(controlFD, &value, 1) != 1 {
                _ = shutdown(socketFD, SHUT_RDWR)
            }
        case .request(let socketFD):
            // A status query owns no target process; interrupt its blocking IO.
            _ = shutdown(socketFD, SHUT_RDWR)
        case nil:
            break
        }
    }
}
