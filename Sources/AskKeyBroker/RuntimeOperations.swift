import CryptoKit
import Foundation

/// Runtime identity is independent of permission and approval identity. One
/// instance belongs to the App runtime, covering silent and approved deliveries.
final class BrokerRuntimeOperations: @unchecked Sendable {
    private struct Entry {
        let digest: Data
        var inFlight: Bool
        var result: Result<BrokerTextRunResult, Error>?
    }
    private let condition = NSCondition()
    private let receiptCapacity: Int
    // Retain compact identity/result receipts for this runtime's lifetime. They
    // never contain credential material, commands or inherited environment.
    // Completed work must neither consume concurrency slots nor be forgotten;
    // capacity rejects only new identities, so existing receipts remain replayable.
    private var entries: [Data: Entry] = [:]
    private var inFlightCount = 0

    init(receiptCapacity: Int = BrokerLimits.maximumRuntimeReceiptCount) {
        self.receiptCapacity = min(
            BrokerLimits.maximumRuntimeReceiptCount,
            max(1, receiptCapacity)
        )
    }

    func perform(
        _ request: BrokerTextRunRequest,
        cancellation: BrokerCancellation,
        operation: () throws -> BrokerTextRunResult
    ) throws -> BrokerTextRunResult {
        try BrokerTextRuntime.validateRequestBeforeReceipt(request)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let identifier = Data(SHA256.hash(data: Data(request.operationID.utf8)))
        let digest = Data(SHA256.hash(data: try encoder.encode(request)))
        condition.lock()
        var waited = false
        while let existing = entries[identifier] {
            guard existing.digest == digest else {
                condition.unlock()
                throw BrokerApprovalError.payloadMismatch
            }
            if existing.inFlight {
                if cancellation.isCancelled {
                    condition.unlock()
                    throw BrokerCancellationError.cancelled
                }
                waited = true
                _ = condition.wait(until: Date().addingTimeInterval(0.05))
                continue
            }
            if let result = existing.result {
                // An approval response is resumable on a later invocation. A
                // concurrent retransmission only observes this invocation's result.
                if case .success(.approvalRequired) = result, !waited {
                    guard inFlightCount < BrokerLimits.maximumConcurrentRequests else {
                        condition.unlock()
                        throw BrokerProviderError.resourceExhausted
                    }
                    entries[identifier]?.inFlight = true
                    inFlightCount += 1
                    break
                }
                condition.unlock()
                return try result.get()
            }
        }
        if entries[identifier] == nil {
            guard entries.count < receiptCapacity else {
                condition.unlock()
                throw BrokerProviderError.resourceExhausted
            }
            if inFlightCount >= BrokerLimits.maximumConcurrentRequests {
                condition.unlock()
                throw BrokerProviderError.resourceExhausted
            }
            entries[identifier] = Entry(digest: digest, inFlight: true, result: nil)
            inFlightCount += 1
        }
        condition.unlock()
        let result = Result { try operation() }
        condition.lock()
        entries[identifier]?.result = result
        entries[identifier]?.inFlight = false
        inFlightCount -= 1
        condition.broadcast()
        condition.unlock()
        return try result.get()
    }
}
