import AskKeyDevices
import Foundation

/// Deciding, sending and polling (ADR 0014 → iPhone app, Retries).
extension AppModel {
    /// A failed send is tried again after this long, or after CloudKit's retry-after.
    static let sendRetryInterval: TimeInterval = 2
    /// A saved decision is sent again after this long without a closed message.
    static let resendInterval: TimeInterval = 30
    /// The foreground poll while a pending or sent request is shown.
    static let activePollInterval: TimeInterval = 2
    static let idlePollInterval: TimeInterval = 10

    // MARK: Deciding

    /// Builds, stores and sends one decision. Allow Once and the timed
    /// allowance sign with the approval key, which asks for Face ID or
    /// Touch ID with a new context each time and no passcode button; Deny
    /// asks for nothing. The time left, the iCloud account, the identity
    /// and the Mac's approval flag are checked before, and for Allow again
    /// after the prompt. A cancelled or failed prompt sends nothing, and
    /// the person may decide again while time is left. The decision's
    /// sealed bytes are stored before the first send and are the only
    /// bytes ever sent for this request.
    public func decide(_ code: ApprovalDecisionCode, requestID: String) async {
        guard stage == .ready, let services, decidingRequest == nil, let message = openedContent[requestID],
              case .request(let request) = message.message, request.offers.contains(code),
              let index = approvals.index(of: requestID), approvals.requests[index].decision == nil,
              !approvals.requests[index].isFinished(at: environment.clock.now()) else { return }
        decidingRequest = requestID
        decisionProblems[requestID] = nil
        defer {
            decidingRequest = nil
            isAuthenticating = false
        }
        if let problem = await sendingProblem(requestID, message: message, services: services) {
            if approvals.index(of: requestID) != nil { decisionProblems[requestID] = problem }
            return
        }
        let sealed: SealedDeviceMessage
        do {
            isAuthenticating = code != .deny
            sealed = try await services.sealer.sealApprovalDecision(code, answering: message,
                                                                    approvalReason: allowReason(message, request))
            isAuthenticating = false
        } catch let error as DeviceIdentityError {
            isAuthenticating = false
            switch error {
            case .authenticationCancelled: decisionProblems[requestID] = .cancelled
            case .authenticationFailed: decisionProblems[requestID] = .failed
            case .authenticationUnavailable: decisionProblems[requestID] = .unavailable
            case .unusable, .secureEnclaveUnavailable, .keyCreationFailed: identityBecameUnusable()
            }
            return
        } catch {
            AppLog.failure("Sealing a decision", error)
            decisionProblems[requestID] = .other
            return
        }
        if code != .deny, let problem = await sendingProblem(requestID, message: message, services: services) {
            if approvals.index(of: requestID) != nil { decisionProblems[requestID] = problem }
            return
        }
        guard self.services === services, let current = approvals.index(of: requestID),
              approvals.requests[current].decision == nil,
              !approvals.requests[current].isFinished(at: environment.clock.now()) else { return }
        var state = approvals
        state.requests[current].decision = StoredDecision(code: code.rawValue,
                                                          durationCeiling: code == .timedAllowance ? request.timedDuration : 0,
                                                          envelope: StoredEnvelope(sealed.envelope))
        do {
            try persist(state)
        } catch {
            AppLog.failure("Storing a decision", error)
            decisionProblems[requestID] = .storage
            return
        }
        approvals = state
        rebuildRequests()
        await sendDueMessages()
    }

    /// Nil when a decision may be sent now: time is left, the identity is
    /// the one that verified the request, the Mac still carries the
    /// approval flag, and the iCloud account is the stored one.
    private func sendingProblem(_ requestID: String, message: VerifiedApprovalMessage,
                                services: DeviceServices) async -> DecisionProblem? {
        guard hasTimeLeft(requestID) else { return .timeUp }
        guard await accountAllowsSending(services) else { return .account }
        guard let list = try? await services.registry.list(), self.services === services, stage == .ready else {
            return .other
        }
        knownList = list
        guard approves(message.senderID, pairingID: message.pairingID, in: list) else { return .other }
        return hasTimeLeft(requestID) ? nil : .timeUp
    }

    private func hasTimeLeft(_ requestID: String) -> Bool {
        guard let index = approvals.index(of: requestID) else { return false }
        return !approvals.requests[index].isFinished(at: environment.clock.now())
    }

    /// Whether no other iCloud account than the stored one is signed in.
    /// iCloud that cannot answer now, for example offline, does not stop
    /// storing a decision, which is then sent once it answers. A change, a
    /// sign-out or a restriction goes through the account refresh, which
    /// shows the notice and drops what it drops.
    func accountAllowsSending(_ services: DeviceServices) async -> Bool {
        let stored = environment.localState.inboxPosition?.userRecordName
        let state = await services.transport.accountState(storedUserRecordName: stored)
        guard self.services === services else { return false }
        switch state {
        case .available:
            if accountNotice != nil { await refreshAccount() }
            return accountNotice == nil && self.services === services
        case .temporarilyUnavailable:
            return true
        case .accountChanged, .noAccount, .restricted:
            await refreshAccount()
            return false
        }
    }

    /// The Face ID prompt's reason, in the card's words.
    private func allowReason(_ message: VerifiedApprovalMessage, _ request: ApprovalRequest) -> String {
        let requester = request.requesterName.isEmpty
            ? String(localized: "request.localAgent", bundle: .kit) : request.requesterName
        let mac = knownList?.device(message.senderID)?.displayName ?? message.sender.displayName
        return String(localized: "request.allow.reason \(requester) \(mac) \(request.credentialName)", bundle: .kit)
    }

    // MARK: Sending

    /// Sends what is due: stored decisions until CloudKit saves them (every
    /// 2 seconds or after CloudKit's retry-after, "recipient unreachable"
    /// included) and again every 30 seconds without a closed message while
    /// the countdown runs; receipts and approver confirmations until saved
    /// or expired. Calls made while sending wait and send once more.
    func sendDueMessages() async {
        if let running = sendWork {
            sendAgain = true
            await running.value
            return
        }
        let work = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.sendAgain = false
                await self.sendOnce()
            } while self.sendAgain && self.stage == .ready
            // Cleared in the same step as the last check, so no call is lost.
            self.sendWork = nil
        }
        sendWork = work
        await work.value
    }

    /// Every send re-reads the live state after the previous one: a
    /// decision goes out only while its entry still holds it, is open and
    /// within its countdown, its Mac still carries the approval flag here,
    /// and the services and the account are the ones it was made under.
    private func sendOnce() async {
        guard let services else { return }
        for recordName in approvals.requests.map(\.recordName) {
            guard mayStillSend(services) else { return }
            let now = environment.clock.now()
            guard let index = approvals.index(of: recordName) else { continue }
            let entry = approvals.requests[index]
            guard let decision = entry.decision, let envelope = decision.envelope.envelope, entry.closed == nil, !entry.gone,
                  now < entry.countdownEnd, (nextAttempts[recordName] ?? .distantPast) <= now, macApproves(entry) else {
                continue
            }
            if let last = entry.lastSentAt, now.timeIntervalSince(last) < Self.resendInterval { continue }
            let saved = await send(envelope, retryKey: recordName, services: services)
            guard self.services === services else { return }
            guard saved, let current = approvals.index(of: recordName), approvals.requests[current].decision == decision else {
                continue
            }
            var state = approvals
            state.requests[current].lastSentAt = environment.clock.now()
            commitApprovals(state)
            rebuildRequests()
        }
        for name in outbox.keys.sorted() {
            guard mayStillSend(services) else { return }
            let now = environment.clock.now()
            guard let message = outbox[name], message.envelope.expiresAt > now,
                  (nextAttempts[name] ?? .distantPast) <= now else { continue }
            if case .receipt(let request) = message.purpose, approvals.index(of: request) == nil {
                outbox[name] = nil
                continue
            }
            let saved = await send(message.envelope, retryKey: name, services: services)
            guard self.services === services else { return }
            if case .confirmation(let mac, _) = message.purpose, !saved, approverConfirmation?.macID == mac.text {
                approverConfirmation?.problem = .retrying
            }
            guard saved, outbox.removeValue(forKey: name) != nil else { continue }
            if case .confirmation(let mac, let pairingID) = message.purpose {
                await confirmationSaved(mac: mac, pairingID: pairingID, services: services)
            }
        }
    }

    private func mayStillSend(_ services: DeviceServices) -> Bool {
        stage == .ready && self.services === services && accountNotice == nil && approvalsReadable
    }

    /// The request's Mac is on the list as last read, with the request's
    /// pairing ID and the approval flag, and its approval has not ended here.
    private func macApproves(_ entry: StoredRequest) -> Bool {
        guard let mac = DeviceID(text: entry.macID), let pairing = PairingID(rawValue: entry.pairingID),
              let list = knownList else { return false }
        return approves(mac, pairingID: pairing, in: list)
    }

    private func send(_ envelope: DeviceEnvelope, retryKey: String, services: DeviceServices) async -> Bool {
        do {
            try await services.transport.send(envelope)
            nextAttempts[retryKey] = nil
            return true
        } catch {
            var wait = Self.sendRetryInterval
            if let transportError = error as? DeviceTransportError, case .rateLimited(let retryAfter?) = transportError {
                wait = max(wait, retryAfter)
            }
            nextAttempts[retryKey] = environment.clock.now().addingTimeInterval(wait)
            AppLog.failure("Sending an approval message", error)
            return false
        }
    }

    /// After every fetch: drops what expired, refreshes the cards, removes
    /// the notifications of settled requests and sends what is due. A
    /// stored state that could not be read, or stored requests that could
    /// not be opened yet, are tried again first.
    func serviceApprovals() async {
        if let services {
            if !approvalsReadable {
                loadApprovals()
                if approvalsReadable { await restoreApprovals(services) }
            } else if approvals.requests.contains(where: { openedContent[$0.recordName] == nil }) {
                await restoreApprovals(services)
            }
        }
        let now = environment.clock.now()
        var state = approvals
        let expired = state.prune(now: now)
        if state != approvals { commitApprovals(state) }
        forget(expired)
        for (name, message) in outbox where message.envelope.expiresAt <= now {
            outbox[name] = nil
            nextAttempts[name] = nil
            if case .confirmation(let mac, _) = message.purpose, approverConfirmation?.macID == mac.text {
                approverConfirmation?.stage = .entering
                approverConfirmation?.problem = .notSent
            }
        }
        rebuildRequests()
        settleRequestNotifications(also: expired)
        await sendDueMessages()
    }

    // MARK: Polling

    /// While the app is in front: every 2 seconds while a pending or sent
    /// request is shown or a message waits to be sent, otherwise every 10.
    public var foregroundPollInterval: TimeInterval {
        let now = environment.clock.now()
        let busy = requests.contains { !$0.phase(at: now).isFinished } || !outbox.isEmpty
        return busy ? Self.activePollInterval : Self.idlePollInterval
    }

    /// Polls the inbox on the foreground schedule until the task is cancelled.
    public func runForegroundPolling() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(foregroundPollInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await processInbox()
        }
    }
}
