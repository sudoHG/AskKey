import Foundation
import Darwin

/// A single caller retains this session across sequential runtime and approval
/// status requests. Signals remain latched between connections; an active
/// runtime still receives them through its existing control pipe.
public final class BrokerSignalSession {
    private let sources: [(Int32, sig_t?, DispatchSourceSignal)]
    private let queue: DispatchQueue
    private let permit: BrokerSignalPermit
    private let state: BrokerSignalState

    public init() {
        permit = BrokerSignalPermit()
        let signalState = BrokerSignalState()
        state = signalState
        let forwardingQueue = DispatchQueue(label: "com.sudohg.askkey.signal-forwarding")
        queue = forwardingQueue
        sources = ([SIGINT, SIGTERM] as [Int32]).map { signalNumber in
            let previous = signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: forwardingQueue)
            source.setEventHandler {
                signalState.receive(signalNumber)
            }
            source.resume()
            return (signalNumber, previous, source)
        }
    }

    deinit { stop() }

    public func checkCancellation() throws {
        try queue.sync { try state.checkCancellation() }
    }

    public func waitUnlessCancelled(for interval: TimeInterval) throws {
        try checkCancellation()
        _ = state.receivedSignal.wait(timeout: .now() + interval)
        try checkCancellation()
    }

    public var isCancelled: Bool { state.cancellation.isCancelled }

    public func stop() {
        let shouldStop = queue.sync {
            guard !state.stopped else { return false }
            state.stopped = true
            state.connection = nil
            return true
        }
        guard shouldStop else { return }
        for (signalNumber, previous, source) in sources {
            source.cancel()
            queue.sync {}
            _ = signal(signalNumber, previous)
        }
        permit.release()
    }

    func attachRuntime(controlFD: Int32, socketFD: Int32) throws {
        try attach(.runtime(controlFD: controlFD, socketFD: socketFD))
    }

    func attachRequest(socketFD: Int32) throws {
        try attach(.request(socketFD: socketFD))
    }

    private func attach(_ connection: BrokerSignalState.Connection) throws {
        try queue.sync {
            // Attachment is ordered with signal handling, so a cancellation
            // already recorded by this session cannot start another request.
            // Once attached, runtime control retains its existing boundary.
            try state.checkCancellation()
            guard state.connection == nil else {
                throw BrokerSocketError.systemError("signal-session", EBUSY)
            }
            state.connection = connection
        }
    }

    func detach() {
        // Drain forwarding work before the caller closes or reuses its FDs.
        queue.sync { state.connection = nil }
    }

    func performWrite<T>(_ write: () -> T) throws -> T {
        try queue.sync {
            try state.checkCancellation()
            return write()
        }
    }
}
