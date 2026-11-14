import Foundation

/// The active-approver set (ADR 0014 → Approvers). It lives only in memory,
/// under the approval lock, so it is the linearization point between
/// revocation and remote decisions: every path that ends or suspends a
/// device's authority removes it here first, and the remote decision path
/// checks it inside the same locked transition from pending.
extension BrokerApprovalStateMachine {
    /// Read before reading the paired-device list for an addition.
    package func activeApproverRevocationCount() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return approverRevocationCount
    }

    /// Adds approvers whose flag the caller read on the list after reading
    /// `revocationCount`. Refuses the whole addition if any removal or
    /// emptying happened since. An approver not yet in the set gets a new
    /// generation from a counter that only grows, so neither a reload nor
    /// turning approval off and on revives an earlier generation; one still
    /// in the set has held authority without interruption and keeps its own.
    /// Returns the generation of every given pairing ID.
    @discardableResult
    package func addActiveApprovers(
        _ pairingIDs: [Data], revocationCount: UInt64
    ) throws -> [Data: UInt64] {
        guard pairingIDs.allSatisfy({ $0.count == 16 }), Set(pairingIDs).count == pairingIDs.count else {
            throw BrokerActiveApproverError.malformedPairingID
        }
        lock.lock(); defer { lock.unlock() }
        guard revocationCount == approverRevocationCount else {
            throw BrokerActiveApproverError.revocationRaced
        }
        var generations: [Data: UInt64] = [:]
        for pairingID in pairingIDs {
            if let current = activeApprovers[pairingID] {
                generations[pairingID] = current
                continue
            }
            lastApproverGeneration += 1
            activeApprovers[pairingID] = lastApproverGeneration
            generations[pairingID] = lastApproverGeneration
        }
        return generations
    }

    /// Ends one approver's authority before the caller writes storage or
    /// closes its requests. Always counts as a revocation.
    package func removeActiveApprover(pairingID: Data) {
        lock.lock(); defer { lock.unlock() }
        activeApprovers.removeValue(forKey: pairingID)
        approverRevocationCount &+= 1
    }

    /// Suspends every approver, for an account change, a sign-out, an
    /// identity reset or a local erase.
    package func removeAllActiveApprovers() {
        lock.lock(); defer { lock.unlock() }
        activeApprovers.removeAll()
        approverRevocationCount &+= 1
    }

    /// The generation to record in an outstanding entry when sealing, or nil
    /// when the device is not an active approver.
    package func activeApproverGeneration(pairingID: Data) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return activeApprovers[pairingID]
    }

    func isActiveApproverLocked(_ approver: BrokerRemoteApprover) -> Bool {
        activeApprovers[approver.pairingID] == approver.generation
    }
}
