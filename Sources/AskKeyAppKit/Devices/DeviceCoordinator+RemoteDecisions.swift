import AskKeyBroker
import AskKeyDevices
import AskKeyVault
import Foundation

/// The approval messages an iPhone sends the Mac, how a verified decision is
/// applied, and how every approver learns how a request ended (ADR 0014 →
/// Verifying and applying a decision, Closed messages).
extension DeviceCoordinator {
    /// How often a decision is tried against the Vault and the Broker before
    /// its failure counts as "not applied".
    static let applyAttempts = 3

    /// The handler `AskKeyDevices` calls with every verified kind 10–14
    /// message, after it checked the envelope, the payload, the pairing ID and
    /// the approval-key signature (checks 1, 3 and 6). The Mac accepts only
    /// what an iPhone sends it.
    func handleApprovalMessage(_ message: VerifiedApprovalMessage) async -> ApprovalMessageHandling {
        switch message.message {
        case .decision(let decision):
            return await handleRemoteDecision(message, decision)
        case .receipt(let receipt):
            return handleReceipt(message, receipt)
        case .confirmation(let confirmation):
            return await handleApproverConfirmation(message, confirmation)
        case .request, .closed:
            return .refused(.unexpectedKind)
        }
    }

    // MARK: Decisions

    /// Checks 2, 4 and 5 against the outstanding entry, then consumes it and
    /// applies the decision through the Vault. A decision that fails a check
    /// is refused without effect and leaves the entry as it was.
    func handleRemoteDecision(_ message: VerifiedApprovalMessage,
                              _ decision: ApprovalDecision) async -> ApprovalMessageHandling {
        guard let (requestID, index) = outstandingEntry(where: {
            $0.approverID == message.senderID && $0.responseID == message.messageID
        }), var track = remoteRequests[requestID] else { return .refused(.bindingMismatch) }
        let entry = track.entries[index]
        guard !entry.decided, entry.pairingID == message.pairingID,
              Self.digestsMatch(decision.requestDigest, entry.requestDigest), entry.offers.contains(decision.code),
              decision.code != .timedAllowance || decision.durationCeiling == entry.timedDuration,
              let code = BrokerRemoteDecisionCode(rawValue: decision.code.rawValue) else {
            return .refused(.bindingMismatch)
        }
        // All six checks passed: the entry is consumed whatever the Broker does.
        track.entries[index].decided = true
        track.applying += 1
        remoteRequests[requestID] = track
        let result = await applyRemoteDecision(code, ceiling: decision.durationCeiling, entry: entry,
                                               pending: track.pending, deviceName: message.sender.displayName)
        finishRemoteDecision(result, code: decision.code, entry: entry, requestID: requestID,
                             deviceName: message.sender.displayName)
        return .processed
    }

    enum RemoteApplyResult {
        case outcome(BrokerRemoteDecisionOutcome)
        case failed
    }

    /// Runs the Vault entry off the main actor. A brief failure, one the
    /// Broker did not report as final, is tried again.
    private func applyRemoteDecision(_ code: BrokerRemoteDecisionCode, ceiling: UInt64, entry: OutstandingRemoteRequest,
                                     pending: BrokerPendingApproval, deviceName: String) async -> RemoteApplyResult {
        let vault = self.vault
        let sleep = environment.sleep
        let attempts = Self.applyAttempts
        let retryDelay = 0.2
        return await Task.detached(priority: .userInitiated) {
            for attempt in 1...attempts {
                do {
                    return .outcome(try vault.decideRemoteAgentApproval(
                        requestID: pending.requestID, capability: pending.capability, operationRequest: pending.request,
                        approver: entry.approverID, pairingID: entry.pairingID, generation: entry.generation,
                        deviceName: deviceName, code: code, durationCeiling: TimeInterval(ceiling)))
                } catch is BrokerApprovalError {
                    return .failed
                } catch {
                    if attempt < attempts { try? await sleep(retryDelay) }
                }
            }
            return .failed
        }.value
    }

    /// Sends the deciding approver its outcome and closes the request for
    /// the others once it left pending.
    private func finishRemoteDecision(_ result: RemoteApplyResult, code: ApprovalDecisionCode,
                                      entry: OutstandingRemoteRequest, requestID: String, deviceName: String) {
        guard var track = remoteRequests[requestID],
              track.entries.contains(where: { $0.responseID == entry.responseID && $0.decided }) else {
            // The account changed or the services stopped meanwhile; nothing is sent.
            return
        }
        track.applying -= 1
        track.entries.removeAll { $0.responseID == entry.responseID }
        remoteRequests[requestID] = track
        switch result {
        case .outcome(.applied(_, let grantedSeconds)):
            track.appliedBy = entry.pairingID
            remoteRequests[requestID] = track
            enqueueClosed(.applied, appliedCode: code, appliedDuration: code == .timedAllowance ? grantedSeconds : 0,
                          for: entry)
            lastRemoteDecision = RemoteAppliedDecision(requestID: requestID, deviceName: deviceName, approved: code != .deny)
            requestLeftPending(requestID, state: code == .deny ? .denied : .approved)
        case .outcome(.notPending(let state, let decidedBy)):
            enqueueClosed(RemoteClosedOutcome.outcome(for: state, decidedByApprover: decidedBy != nil), for: entry)
            requestLeftPending(requestID, state: state)
        case .outcome(.approverInactive):
            // The flag is gone or the set no longer holds this generation: the
            // approver's other requests end too.
            enqueueClosed(.cancelled, for: entry)
            closeRemoteRequests(of: entry.approverID, pairingID: entry.pairingID)
        case .outcome(.notApplicable), .failed:
            let state = brokerState(of: track)
            guard state == .pending else {
                enqueueClosed(RemoteClosedOutcome.outcome(for: state, decidedByApprover: track.appliedBy != nil), for: entry)
                requestLeftPending(requestID, state: state)
                break
            }
            // Never turned into another decision: outcome 6, then a
            // replacement with the current offers and the original deadline.
            enqueueClosed(.notApplied, for: entry)
            Task { [weak self] in await self?.deliverRemoteRequest(requestID, only: entry.approverID) }
        }
        publishRemoteStatus()
        startRemoteLoopIfNeeded()
    }

    /// The request's state now; an entry the Broker no longer holds ended by
    /// expiry if its deadline passed, otherwise by cancellation.
    func brokerState(of track: RemoteRequestTrack) -> BrokerRequestState {
        if let state = try? vault.approvalRequests.status(requestID: track.requestID, capability: track.pending.capability) {
            return state
        }
        return track.deadline.map { now >= $0 } == true ? .expired : .cancelled
    }

    // MARK: Receipts

    /// A receipt marks its request delivered; it needs an outstanding entry
    /// for its sender whose receipt ID and request digest it matches.
    func handleReceipt(_ message: VerifiedApprovalMessage, _ receipt: ApprovalReceipt) -> ApprovalMessageHandling {
        guard let (requestID, index) = outstandingEntry(where: {
            $0.approverID == message.senderID && $0.receiptID == message.messageID
        }), var track = remoteRequests[requestID] else { return .refused(.bindingMismatch) }
        guard track.entries[index].pairingID == message.pairingID,
              Self.digestsMatch(receipt.requestDigest, track.entries[index].requestDigest) else {
            return .refused(.bindingMismatch)
        }
        if track.entries[index].deliveredAt == nil {
            track.entries[index].deliveredAt = now
            remoteRequests[requestID] = track
            publishRemoteStatus()
        }
        return .processed
    }

    // MARK: Closing

    /// The request left pending: every approver that still has it open gets
    /// the outcome that ended it, once no decision for it is being applied.
    func requestLeftPending(_ requestID: String, state known: BrokerRequestState? = nil) {
        guard var track = remoteRequests[requestID] else { return }
        let state = known ?? track.ended ?? brokerState(of: track)
        guard state != .pending else { return }
        track.ended = state
        guard track.applying == 0 else {
            remoteRequests[requestID] = track
            return
        }
        for entry in track.entries {
            enqueueClosed(RemoteClosedOutcome.outcome(for: state, decidedByApprover: track.appliedBy != nil), for: entry)
        }
        remoteRequests[requestID] = nil
        publishRemoteStatus()
        updateRemoteActivity()
    }

    /// Ends one approver's outstanding requests with outcome 5 after it was
    /// turned off, removed, paired again or found inactive. Entries whose
    /// decision is being applied keep their own outcome.
    func closeRemoteRequests(of device: DeviceID, pairingID: PairingID) {
        for (requestID, var track) in remoteRequests {
            let closing = track.entries.filter { $0.belongs(to: device, pairingID: pairingID) && !$0.decided }
            guard !closing.isEmpty else { continue }
            for entry in closing { enqueueClosed(.cancelled, for: entry) }
            track.entries.removeAll { $0.belongs(to: device, pairingID: pairingID) && !$0.decided }
            remoteRequests[requestID] = track
        }
        publishRemoteStatus()
        updateRemoteActivity()
    }

    /// Seals a closing message to the entry held at sealing and sends it,
    /// retried with the same bytes until its transport expiry. Nothing is
    /// sent while the account is unavailable.
    func enqueueClosed(_ outcome: ApprovalClosedOutcome, appliedCode: ApprovalDecisionCode? = nil,
                       appliedDuration: UInt64 = 0, for entry: OutstandingRemoteRequest) {
        guard let services, account == .available else { return }
        let sealed: SealedDeviceMessage
        do {
            sealed = try services.messenger.sealer.sealApprovalClosed(
                outcome, appliedCode: appliedCode, appliedDuration: min(appliedDuration, 7_200),
                requestDigest: entry.requestDigest, to: entry.recipient)
        } catch {
            environment.log(.closedMessageNotSealed)
            return
        }
        closedMessages[sealed.messageID] = PendingClosedMessage(envelope: sealed.envelope, retryAt: nil)
        Task { [weak self] in await self?.transmitClosedMessage(sealed.messageID) }
    }

    func transmitClosedMessage(_ messageID: MessageID) async {
        guard let services, var message = closedMessages[messageID] else { return }
        message.retryAt = nil
        closedMessages[messageID] = message
        let lifecycle = self.lifecycle
        var retryAt: Date?
        do {
            try await services.inbox.send(message.envelope)
        } catch DeviceTransportError.rateLimited(let retryAfter) {
            retryAt = now.addingTimeInterval(max(retryAfter ?? 0, Self.remoteRetryInterval))
        } catch {
            retryAt = now.addingTimeInterval(Self.remoteRetryInterval)
        }
        guard lifecycle == self.lifecycle, closedMessages[messageID] != nil else { return }
        if let retryAt, retryAt < message.envelope.expiresAt {
            closedMessages[messageID]?.retryAt = retryAt
            startRemoteLoopIfNeeded()
        } else {
            closedMessages[messageID] = nil
        }
    }

    // MARK: Revocation

    /// The removal hook `AskKeyDevices` calls before any removal of `entry`
    /// commits: a removal here, an unpair notice, an undone pairing or
    /// pairing again. The device leaves the Broker's set first; then its
    /// requests close (ADR 0014 → Revocation).
    func deviceWillBeRemoved(_ entry: PairedDevice) {
        vault.approvalRequests.removeActiveApprover(pairingID: entry.pairingID.rawValue)
        closeRemoteRequests(of: entry.deviceID, pairingID: entry.pairingID)
        if let attempt = approverAttempt, attempt.device.id == entry.deviceID, attempt.device.pairingID == entry.pairingID {
            endApproverAttempt(.deviceRemoved)
        }
    }

    // MARK: Helpers

    func outstandingEntry(where matches: (OutstandingRemoteRequest) -> Bool) -> (String, Int)? {
        for (requestID, track) in remoteRequests {
            if let index = track.entries.firstIndex(where: matches) { return (requestID, index) }
        }
        return nil
    }

    static func digestsMatch(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
