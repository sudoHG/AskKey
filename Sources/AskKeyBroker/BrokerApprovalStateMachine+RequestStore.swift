import Foundation

extension BrokerApprovalStateMachine {
    func withEntry<T>(
        requestID: String,
        capability: String,
        now: Date,
        body: (Entry) throws -> T
    ) throws -> T {
        try mutate {
            expireUnconsumedLocked(now: now)
            guard let entry = matchingEntry(requestID: requestID, capability: capability) else {
                throw BrokerApprovalError.requestNotFound
            }
            return try body(entry)
        }
    }

    func updateEntry(
        requestID: String,
        capability: String,
        now: Date,
        body: (inout Entry) throws -> Void
    ) throws -> BrokerApprovalTicket {
        try mutate {
            expireUnconsumedLocked(now: now)
            guard let operationID = entriesByOperationID.first(where: {
                $0.value.requestID == requestID && $0.value.capability == capability
            })?.key, var entry = entriesByOperationID[operationID] else {
                throw BrokerApprovalError.requestNotFound
            }
            try body(&entry)
            entriesByOperationID[operationID] = entry
            return ticket(for: entry)
        }
    }

    static func valid(_ request: BrokerApprovalOperationRequest) -> Bool {
        let required = [
            request.operationID,
            request.targetID,
            request.payloadDigest,
        ]
        return required.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= BrokerLimits.maximumFieldBytes
        } && [request.credentialName, request.callerName, request.callerPurpose]
            .compactMap { $0 }
            .allSatisfy { $0.utf8.count <= BrokerLimits.maximumFieldBytes }
            && validSubject(request)
            && [request.retransmissionDigest].compactMap { $0 }.allSatisfy {
                $0.utf8.count == 64 && $0.unicodeScalars.allSatisfy {
                    CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
                }
            }
            && request.payloadDigest.utf8.count == 64
            && request.payloadDigest.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
            }
    }

    private static func validSubject(_ request: BrokerApprovalOperationRequest) -> Bool {
        if request.operation == .organize {
            guard request.credentialID.isEmpty, request.targetID == "credential-library",
                  request.credentialName == nil, request.display == nil,
                  let ids = request.organizationCredentialIDs else { return false }
            return ids == Array(Set(ids)).sorted() && ids.allSatisfy {
                !$0.isEmpty && $0.utf8.count <= BrokerLimits.maximumFieldBytes
            }
        }
        return request.organizationCredentialIDs == nil && !request.credentialID.isEmpty
            && request.credentialID.utf8.count <= BrokerLimits.maximumFieldBytes
            && (request.operation == .create || request.targetID == request.credentialID)
    }

    func makeRetentionRoom() throws {
        guard entriesByOperationID.count >= BrokerLimits.maximumRetainedRequestStates else { return }
        guard let index = operationOrder.firstIndex(where: {
            guard let state = entriesByOperationID[$0]?.state else { return false }
            return state != .pending && state != .approved
        }) else {
            throw BrokerApprovalError.capacityReached
        }
        entriesByOperationID.removeValue(forKey: operationOrder.remove(at: index))
    }

    func matchingEntry(requestID: String, capability: String) -> Entry? {
        // ponytail: bounded O(n) lookup (max 256); add an index only if the cap grows.
        entriesByOperationID.values.first {
            $0.requestID == requestID && $0.capability == capability
        }
    }

    func ticket(for entry: Entry) -> BrokerApprovalTicket {
        .init(
            requestID: entry.requestID,
            capability: entry.capability,
            state: entry.state,
            retryCount: entry.retryCount
        )
    }
}
