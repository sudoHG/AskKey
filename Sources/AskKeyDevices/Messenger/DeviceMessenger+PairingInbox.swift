import Foundation

extension DeviceMessenger {
    /// Kinds 1–5 and 9 belong to a session, which verifies the sender.
    /// Requests, challenges, reveals and confirmations go to the current
    /// session; cancellations and withdrawals go to the session they name,
    /// which may be a retired one that can still undo its result.
    func handlePairingMessage(_ inner: InnerMessage, recordName: String, pskSession: PairingSessionID?,
                              now: Date) async throws -> Outcome {
        let list = try await registry.list()
        if let retiredID = retiredSessionID(for: inner, pskSession: pskSession, now: now),
           let index = retiredSessions.firstIndex(where: { $0.qr.sessionID == retiredID }) {
            let outcome = inner.kind == .pairingWithdrawal
                ? retiredSessions[index].handleWithdrawal(inner, now: now)
                : try retiredSessions[index].handlePeerMessage(inner, now: now, list: list)
            return try await finish(outcome, sessionID: retiredID, retired: true)
        }
        guard let current = session, current.isOpen(at: now),
              pskSession == nil || pskSession == current.qr.sessionID else {
            return .refused(.noSession, authenticated: false)
        }
        let outcome: PairingOutcome
        do {
            switch inner.kind {
            case .pairingRequest:
                outcome = try session!.handleRequest(inner, firstFetchedAt: firstFetched[recordName] ?? now,
                                                     now: now, list: list)
            case .pairingWithdrawal:
                outcome = session!.handleWithdrawal(inner, now: now)
            default:
                outcome = try session!.handlePeerMessage(inner, now: now, list: list)
            }
        } catch DeviceIdentityError.unusable {
            session?.close(.identityUnusable)
            throw DeviceIdentityError.unusable
        }
        return try await finish(outcome, sessionID: current.qr.sessionID, retired: false)
    }

    /// The retired session a cancellation or withdrawal belongs to, if it
    /// does not belong to the current session.
    private func retiredSessionID(for inner: InnerMessage, pskSession: PairingSessionID?, now: Date) -> PairingSessionID? {
        switch inner.kind {
        case .pairingWithdrawal:
            guard let pskSession, pskSession != session?.qr.sessionID else { return nil }
            return pskSession
        case .pairingCancellation:
            guard let named = try? PairingCancellationPayload(decoding: inner.payload).sessionID,
                  named != session?.qr.sessionID else { return nil }
            return retiredSessions.first { $0.qr.sessionID == named && $0.peerID == inner.sender && $0.isOpen(at: now) }?
                .qr.sessionID
        default:
            return nil
        }
    }

    /// Commits an undo before the session that asked for it closes, so a
    /// failed removal leaves the message to be retried and the session able
    /// to undo again; then performs the remaining effects.
    private func finish(_ outcome: PairingOutcome, sessionID: PairingSessionID, retired: Bool) async throws -> Outcome {
        switch outcome {
        case .accepted(let effects):
            var remaining: [PairingEffect] = []
            for effect in effects {
                guard case .undo(let id, let pairingID) = effect else {
                    remaining.append(effect)
                    continue
                }
                dropChecks(for: id)
                try await commit(.remove(id, pairingID: pairingID))
                if retired {
                    retiredSessions.removeAll { $0.qr.sessionID == sessionID }
                } else if session?.qr.sessionID == sessionID {
                    session?.close(.undoneByPeer)
                }
            }
            if !retired { await perform(remaining) }
            return .processed
        case .refused(let refusal, let authenticated):
            return .refused(refusal, authenticated: authenticated)
        case .held:
            return .held
        }
    }
}
