@testable import AskKeyBroker
import Foundation
import Darwin

final class ApprovalWaitTestState: @unchecked Sendable {
    enum Mode {
        case approve
        case deny
        case legacy
        case pending
        case terminal(BrokerRequestState)
        case missing
    }

    private let lock = NSLock()
    private let tickets: [BrokerApprovalTicket]
    private let mode: Mode
    private var requests: [BrokerTextRunRequest] = []
    private var resolverCalls = 0
    private var spawns = 0
    private var statusCalls: [String: Int] = [:]
    private var allTicketsApproved = false
    private var spawnedBeforeApproval = false
    private let statusObserved = DispatchSemaphore(value: 0)

    init(tickets: [BrokerApprovalTicket], mode: Mode) {
        self.tickets = tickets
        self.mode = mode
    }

    func recordResolverRequest(_ request: BrokerTextRunRequest) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        resolverCalls += 1
    }

    func recordSpawn() {
        lock.lock(); defer { lock.unlock() }
        spawns += 1
        if !allTicketsApproved { spawnedBeforeApproval = true }
    }

    func status(requestID: String, capability: String) -> BrokerRequestState? {
        lock.lock(); defer { lock.unlock() }
        guard tickets.contains(where: { $0.requestID == requestID && $0.capability == capability }) else {
            return nil
        }
        statusObserved.signal()
        statusCalls[capability, default: 0] += 1
        switch mode {
        case .approve:
            guard let index = tickets.firstIndex(where: { $0.capability == capability }) else {
                return nil
            }
            if index == 0 {
                return .approved
            }
            if statusCalls[capability, default: 0] >= 2 {
                allTicketsApproved = true
                return .approved
            }
            return .pending
        case .deny:
            return tickets.first?.capability == capability ? .approved : .denied
        case .legacy:
            return .pending
        case .pending:
            return .pending
        case .terminal(let state):
            return state
        case .missing:
            return nil
        }
    }

    func waitForStatus(timeout: TimeInterval) -> Bool {
        statusObserved.wait(timeout: .now() + timeout) == .success
    }

    var recordedRequests: [BrokerTextRunRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    var resolverCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return resolverCalls
    }

    var spawnCount: Int {
        lock.lock(); defer { lock.unlock() }
        return spawns
    }

    var spawnedBeforeAllTicketsApproved: Bool {
        lock.lock(); defer { lock.unlock() }
        return spawnedBeforeApproval
    }

    func statusCallCount(for capability: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return statusCalls[capability, default: 0]
    }
}
