import Foundation
import AskKeyBroker

private enum ApprovalWaitError: Error, LocalizedError {
    case stopped(String)
    case timedOut
    case invalidTickets

    var errorDescription: String? {
        switch self {
        case .stopped(let state):
            return "Ask Key approval wait stopped (\(state)); the command was not resumed."
        case .timedOut:
            return "Ask Key approval wait expired; the command was not resumed."
        case .invalidTickets:
            return "Ask Key returned an invalid approval response; the command was not resumed."
        }
    }
}

/// Retain the original request in this process: a later Agent terminal call can
/// inherit a different PATH even when its command and working directory match.
func runWaitingForApproval(
    _ request: BrokerTextRunRequest,
    using client: BrokerSocketClient
) throws -> BrokerTextRunResult {
    let signals = BrokerSignalSession()
    defer { signals.stop() }
    do {
        return try runWaitingForApproval(request, using: client, signals: signals)
    } catch {
        if signals.isCancelled { throw ApprovalWaitError.stopped("cancelled") }
        throw error
    }
}

private func runWaitingForApproval(
    _ request: BrokerTextRunRequest,
    using client: BrokerSocketClient,
    signals: BrokerSignalSession
) throws -> BrokerTextRunResult {
    var result = try client.run(request, signalSession: signals)
    let deadline = ProcessInfo.processInfo.systemUptime + 300
    var announced = false
    while case .approvalRequired(let operationID, let tickets) = result {
        try signals.checkCancellation()
        guard operationID == request.operationID, !tickets.isEmpty else {
            throw ApprovalWaitError.invalidTickets
        }
        if !announced {
            try FileHandle.standardError.write(contentsOf: Data(
                "Ask Key is waiting for approval. Keep this process running; it will continue after approval.\n".utf8
            ))
            announced = true
        }
        while true {
            try signals.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ApprovalWaitError.timedOut
            }
            var allApproved = true
            for ticket in tickets {
                let response = try client.send(.init(
                    version: BrokerProtocolVersion.current,
                    method: "request.status",
                    requestID: ticket.requestID,
                    capability: ticket.capability
                ), signalSession: signals)
                try signals.checkCancellation()
                switch response {
                case .success(.requestStatus(.pending)):
                    allApproved = false
                case .success(.requestStatus(.approved)):
                    break
                case .success(.requestStatus(let state)):
                    throw ApprovalWaitError.stopped(state.rawValue)
                case .failure(let code):
                    throw BrokerSocketError.brokerFailure(code)
                default:
                    throw BrokerSocketError.malformedResponse
                }
            }
            if allApproved { break }
            try signals.waitUnlessCancelled(for: 0.5)
        }
        // Broker still validates the complete payload and consumes approval.
        // A status response alone never authorizes spawning the target here.
        try signals.checkCancellation()
        result = try client.run(request, signalSession: signals)
    }
    return result
}
