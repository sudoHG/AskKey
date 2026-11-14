import AskKeyDevices
import AskKeyVault
import Foundation

/// Turning a paired iPhone's approval on and off (ADR 0014 → Approvers).
extension DeviceCoordinator {
    /// The approver code exists for at most this long.
    static let approverCodeLifetime: TimeInterval = 5 * 60
    static let approverCodeAttempts = 3
    /// The inbox's zone poll runs about once a second while the sheet waits,
    /// because a confirmation has a random message ID.
    static let approverPollInterval: TimeInterval = 1

    /// **Approve agent requests**, step 1, in the management session: asks
    /// for system authentication, records it with the Vault for this device
    /// and pairing, then shows a new six-digit code for at most 5 minutes
    /// and polls for the iPhone's confirmation. The open sheet keeps the
    /// management session from expiring for idleness.
    package func startApproverConfirmation(for id: DeviceID) async {
        guard approverConfirmation?.isActive != true else { return }
        guard let services, availability == .ready, account == .available,
              let row = devices.first(where: { $0.id == id }), row.platform == .iOS, !row.isApprover else {
            approverConfirmation = .ended(.unavailable)
            return
        }
        guard managementSessionIsOpen() else {
            approverConfirmation = .ended(.managementRequired)
            return
        }
        approverGeneration += 1
        let generation = approverGeneration
        approverConfirmation = .authenticating(device: row)
        acquireApproverExpiryHold()
        let authenticate = environment.authenticate
        let reason = ManagementAuthenticationAction.manage.reasonKey
        let prompt = Task { @MainActor in await authenticate(reason) }
        approverAuthentication = prompt
        let result = await prompt.value
        guard generation == approverGeneration else { return }
        approverAuthentication = nil
        // The sheet may have closed, management locked, the services or the
        // device's entry changed while the prompt was open.
        guard !prompt.isCancelled, managementSessionIsOpen(), self.services === services,
              devices.contains(where: { $0.id == row.id && $0.pairingID == row.pairingID && !$0.isApprover }) else {
            return endApproverAttempt(.authenticationCancelled)
        }
        switch result {
        case .authenticated(let authenticator):
            do {
                try vault.authorizeDeviceApprover(row.id, pairingID: row.pairingID, using: authenticator)
            } catch {
                return endApproverAttempt(.authenticationFailed)
            }
        case .cancelled:
            return endApproverAttempt(.authenticationCancelled)
        case .failed:
            return endApproverAttempt(.authenticationFailed)
        }
        let code = ApproverCode.random()
        let expiresAt = now.addingTimeInterval(Self.approverCodeLifetime)
        approverAttempt = ApproverAttempt(device: row, code: code, expiresAt: expiresAt,
                                          attemptsRemaining: Self.approverCodeAttempts)
        approverCode = code
        approverConfirmation = .waitingForIPhone(device: row, expiresAt: expiresAt,
                                                 attemptsRemaining: Self.approverCodeAttempts)
        startApproverPolling()
    }

    /// **Cancel** or closing the sheet: discards the code and the authorization.
    package func cancelApproverConfirmation() {
        guard approverConfirmation != nil else { return }
        approverGeneration += 1
        finishApproverAttempt()
        approverConfirmation = nil
    }

    func endApproverAttempt(_ reason: ApproverConfirmationEndReason) {
        approverGeneration += 1
        finishApproverAttempt()
        approverConfirmation = .ended(reason)
    }

    /// Drops the code, the polling, the hold on idle expiry and the Vault's
    /// approver authorization.
    func finishApproverAttempt() {
        approverAuthentication?.cancel()
        approverAuthentication = nil
        approverAttempt = nil
        approverCode = nil
        approverPollTask?.cancel()
        approverPollTask = nil
        approverExpiryHold?.release()
        approverExpiryHold = nil
        vault.endDeviceApproverAuthorization()
    }

    /// Step 3: a confirmation from the selected entry whose code proof
    /// matches turns approval on; one with another proof counts as a wrong
    /// code, and the third ends the attempt. A matching confirmation from
    /// any other entry ends the attempt, because that device knows the code;
    /// one that does not match is refused without counting.
    func handleApproverConfirmation(_ message: VerifiedApprovalMessage,
                                    _ confirmation: ApproverConfirmation) async -> ApprovalMessageHandling {
        guard let mac = services?.deviceID, var attempt = approverAttempt, !attempt.enabling,
              case .waitingForIPhone = approverConfirmation else { return .refused(.noSession) }
        guard now < attempt.expiresAt else {
            endApproverAttempt(.expired)
            return .refused(.noSession)
        }
        let matches = attempt.code.matches(proof: confirmation.codeProof, mac: mac, phone: message.senderID,
                                           pairingID: message.pairingID)
        guard message.senderID == attempt.device.id, message.pairingID == attempt.device.pairingID else {
            if matches {
                environment.log(.approverCodeEnteredElsewhere)
                endApproverAttempt(.enteredOnOtherDevice(name: message.sender.displayName))
            }
            return .refused(.bindingMismatch)
        }
        guard matches else {
            attempt.attemptsRemaining -= 1
            guard attempt.attemptsRemaining > 0 else {
                endApproverAttempt(.tooManyWrongCodes)
                return .refused(.bindingMismatch)
            }
            approverAttempt = attempt
            approverConfirmation = .waitingForIPhone(device: attempt.device, expiresAt: attempt.expiresAt,
                                                     attemptsRemaining: attempt.attemptsRemaining)
            return .refused(.bindingMismatch)
        }
        attempt.enabling = true
        approverAttempt = attempt
        await enableApprover(attempt.device)
        return .processed
    }

    /// Writes the flag, which uses the Vault's authorization up, then adds
    /// only this device to the Broker's set, so other approvers keep their
    /// generations.
    private func enableApprover(_ row: PairedDeviceRow) async {
        guard let services else { return }
        let generation = approverGeneration
        let outcome: PairedDeviceChangeOutcome?
        do {
            outcome = try await services.registry.apply(.setApprover(row.id, pairingID: row.pairingID, enabled: true))
        } catch {
            outcome = nil
        }
        if outcome == .applied {
            if approversLoaded {
                do {
                    try vault.activateStoredApprovers(only: row.pairingID)
                } catch {
                    // The next account check loads the whole set again.
                    approversLoaded = false
                    environment.log(.approverActivationFailed)
                }
            } else {
                activateApproversIfNeeded()
            }
            environment.log(.approverEnabled)
        }
        await publish()
        guard generation == approverGeneration else { return }
        switch outcome {
        case .applied?:
            let updated = devices.first { $0.id == row.id && $0.pairingID == row.pairingID } ?? row
            approverGeneration += 1
            finishApproverAttempt()
            approverConfirmation = .enabled(device: updated)
        case nil:
            endApproverAttempt(.notSaved)
        default:
            endApproverAttempt(.deviceRemoved)
        }
    }

    /// Turns a device's approval off, in the management session: it leaves
    /// the Broker's set first, then the flag is written, then its outstanding
    /// requests close with outcome 5 (ADR 0014 → Revocation). Reducing
    /// authority needs no fresh authentication.
    @discardableResult
    package func disableApprover(_ row: PairedDeviceRow) async -> Bool {
        guard let services else { return false }
        guard managementSessionIsOpen() else {
            lastIssue = .managementRequired
            return false
        }
        lastIssue = nil
        vault.approvalRequests.removeActiveApprover(pairingID: row.pairingID.rawValue)
        let lifecycle = self.lifecycle
        var applied = false
        do {
            let outcome = try await services.registry.apply(.setApprover(row.id, pairingID: row.pairingID, enabled: false))
            applied = outcome == .applied
            if outcome == .dropped, lifecycle == self.lifecycle { lastIssue = .deviceNotFound }
        } catch {
            if lifecycle == self.lifecycle { lastIssue = .actionFailed }
        }
        guard lifecycle == self.lifecycle else { return applied }
        closeRemoteRequests(of: row.id, pairingID: row.pairingID)
        await publish()
        return applied
    }

    // MARK: Schedule

    func startApproverPolling() {
        approverPollTask?.cancel()
        approverPollTask = nil
        guard environment.automaticPolling else { return }
        let sleep = environment.sleep
        approverPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await sleep(Self.approverPollInterval)
                guard let self, !Task.isCancelled, await self.approverLoopStep() else { return }
            }
        }
    }

    /// One turn of the open sheet: ends the attempt when its code expired or
    /// management closed, otherwise keeps management open and polls.
    /// Returns whether to go on.
    func approverLoopStep() async -> Bool {
        guard let attempt = approverAttempt, case .waitingForIPhone = approverConfirmation else { return false }
        guard now < attempt.expiresAt else {
            endApproverAttempt(.expired)
            return false
        }
        guard managementSessionIsOpen() else {
            cancelApproverConfirmation()
            return false
        }
        await refresh()
        return approverAttempt != nil
    }

    func acquireApproverExpiryHold() {
        if approverExpiryHold == nil { approverExpiryHold = SessionPolicy.holdIdleExpiry() }
    }
}
