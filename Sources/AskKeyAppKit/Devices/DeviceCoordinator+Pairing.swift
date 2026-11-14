import AskKeyDevices
import AskKeyVault
import Foundation

/// Pairing as the initiator (ADR 0013 → Pairing).
extension DeviceCoordinator {
    /// **Pair a Device…**, in the management session: creates the identity
    /// on the first pairing (after checking the Secure Enclave and the
    /// account), prepares the inbox and its subscriptions, opens a session
    /// and shows its QR code, then polls about once a second while the
    /// session is open. The open sheet keeps the management session from
    /// expiring for idleness until the session ends or the sheet closes.
    package func startPairing() async {
        guard environment.backend != nil, pairing?.isActive != true else { return }
        if services == nil, availability == .loading || availability == .storageUnavailable {
            _ = openStoredServices()
        }
        switch availability {
        case .ready:
            break
        case .secureEnclaveUnavailable:
            return failPairing(.secureEnclaveUnavailable)
        case .identityUnusable, .listRefused:
            return failPairing(.identityUnusable)
        case .storageUnavailable, .loading, .notConfigured:
            return failPairing(.storageUnavailable)
        }
        guard managementSessionIsOpen() else {
            pairing = .failed(.managementRequired)
            return
        }
        pairingGeneration += 1
        let generation = pairingGeneration
        pairing = .preparing
        pairingFeedback = nil
        pairingExpiresAt = nil
        acquireExpiryHold()
        do {
            guard try await openServicesForPairing(generation: generation), generation == pairingGeneration,
                  let services else { return }
            if account != .available { await refreshAccount() }
            guard generation == pairingGeneration else { return }
            guard account == .available else { return failPairing(.accountUnavailable(account)) }
            do {
                _ = try await services.inbox.prepareInbox()
            } catch {
                guard generation == pairingGeneration else { return }
                return failPairing(.iCloudUnavailable)
            }
            guard generation == pairingGeneration, self.services === services else { return }
            let qr = try await services.messenger.startPairing(displayName: environment.displayName())
            guard generation == pairingGeneration, self.services === services else {
                await services.messenger.cancelPairing()
                return
            }
            pairing = .showingQRCode(text: qr.text, expiresAt: qr.qrExpiry)
            pairingExpiresAt = qr.qrExpiry.addingTimeInterval(Self.sessionExtension)
            startPairingPolling()
        } catch DeviceIdentityError.secureEnclaveUnavailable {
            guard generation == pairingGeneration else { return }
            availability = .secureEnclaveUnavailable
            failPairing(.secureEnclaveUnavailable)
        } catch DeviceIdentityError.unusable {
            guard generation == pairingGeneration else { return }
            identityBecameUnusable()
            failPairing(.identityUnusable)
        } catch DeviceIdentityError.keyCreationFailed {
            guard generation == pairingGeneration else { return }
            failPairing(.keyCreationFailed)
        } catch {
            guard generation == pairingGeneration else { return }
            failPairing(.storageUnavailable)
        }
    }

    /// Opens the stored identity's services, or creates the identity: Secure
    /// Enclave keys in memory, then the account check, and only with an
    /// available account are the key blobs stored. Returns false when the
    /// session cannot start; `pairing` says why.
    private func openServicesForPairing(generation: Int) async throws -> Bool {
        if openStoredServices() { return true }
        guard availability == .ready, let backend = environment.backend else {
            failPairing(availability == .identityUnusable ? .identityUnusable : .storageUnavailable)
            return false
        }
        guard backend.isSecureEnclaveAvailable else { throw DeviceIdentityError.secureEnclaveUnavailable }
        let created = try backend.createIdentity()
        let inbox = backend.makeInbox(for: DeviceID(messagePublicKey: created.identity.messagePublicKey))
        let answer = await inbox.accountState(storedUserRecordName: nil)
        guard generation == pairingGeneration else { return false }
        guard case .available(let name) = answer else {
            account = Self.status(of: answer)
            failPairing(.accountUnavailable(account))
            return false
        }
        guard managementSessionIsOpen() else {
            failPairing(.managementRequired)
            return false
        }
        try vault.saveDeviceIdentityKeyBlobs(created.blobs)
        let state = DeviceInboxState(listAccount: name)
        try environment.inboxState.save(state)
        guard openServices(identity: created.identity, inbox: inbox) else {
            failPairing(.storageUnavailable)
            return false
        }
        account = .available
        await use(account: name, state: state)
        activateApproversIfNeeded()
        return true
    }

    /// The person typed the code the iPhone shows. Nothing here signs or
    /// sends a confirmation; the third wrong code ends the session.
    package func enterPairingCode(_ text: String) async {
        guard case .enteringCode = pairing, let services else { return }
        let generation = pairingGeneration
        do {
            try await services.messenger.enterPairingCode(text)
            guard generation == pairingGeneration else { return }
            pairingFeedback = nil
        } catch DeviceMessengerError.invalidCodeFormat {
            guard generation == pairingGeneration else { return }
            pairingFeedback = .invalidCodeFormat
        } catch DeviceMessengerError.wrongCode(let remaining) {
            guard generation == pairingGeneration else { return }
            pairingFeedback = .wrongCode(attemptsRemaining: remaining)
        } catch {
            guard generation == pairingGeneration else { return }
            pairingFeedback = nil
        }
        await publish()
    }

    /// Confirms an accepted code. The approval signature asks for system
    /// authentication first; a cancelled or failed one sends nothing, is not
    /// an attempt, and can be retried without entering the code again. The
    /// device is added once the iPhone's verified confirmation is also held,
    /// without asking again in this session.
    package func confirmPairing() async {
        guard case .codeAccepted = pairing, let services else { return }
        let generation = pairingGeneration
        pairingFeedback = nil
        do {
            try await services.messenger.confirmPairing(approvalReason: ManagementAuthenticationAction.pairDevice.reasonKey)
        } catch DeviceIdentityError.authenticationCancelled {
            if generation == pairingGeneration { pairingFeedback = .authenticationCancelled }
        } catch DeviceIdentityError.authenticationFailed, DeviceIdentityError.authenticationUnavailable {
            if generation == pairingGeneration { pairingFeedback = .authenticationFailed }
        } catch DeviceIdentityError.unusable {
            if generation == pairingGeneration { identityBecameUnusable() }
        } catch {
            // The session ended or a prompt is already open; the phase shows it.
        }
        await publish()
    }

    /// **Cancel**, closing the sheet, locking management or closing its
    /// window. Ends a session that has not added the device and tells the
    /// iPhone; a device already added stays.
    package func cancelPairing() async {
        guard pairing != nil else { return }
        pairingGeneration += 1
        finishPairingSession()
        pairing = nil
        pairingExpiresAt = nil
        pairingFeedback = nil
        guard let services else { return }
        await services.messenger.cancelPairing()
        await publish()
    }

    /// The management session ended (locked, expired or its window closed).
    /// An open approver sheet ends too, with its code and authorization.
    package func managementSessionEnded() async {
        if approverConfirmation?.isActive == true { cancelApproverConfirmation() }
        guard pairingIsLive else {
            finishPairingSession()
            return
        }
        await cancelPairing()
    }

    /// Whether the sheet's session is still open: before the device was
    /// added, or after it, until the session expires, because the iPhone may
    /// still cancel and so undo the pairing (ADR 0013 → Pairing, step 7).
    var pairingIsLive: Bool {
        if pairing?.isActive == true { return true }
        guard case .paired = pairing, let expiry = pairingExpiresAt else { return false }
        return now < expiry
    }

    /// Runs inside the approval signature: system authentication for the
    /// accepted code, recorded with the Vault for this session's device.
    func authorizePairingSignature(reason: String) async throws {
        guard case .codeAccepted(let peer) = pairing, environment.isManagementSessionActive() else {
            throw DeviceIdentityError.authenticationCancelled
        }
        let generation = pairingGeneration
        isAuthenticatingPairing = true
        let authenticate = environment.authenticate
        let prompt = Task { @MainActor in await authenticate(reason) }
        pairingAuthentication = prompt
        let result = await prompt.value
        if generation == pairingGeneration {
            isAuthenticatingPairing = false
            pairingAuthentication = nil
        }
        guard generation == pairingGeneration, !prompt.isCancelled, pairing == .codeAccepted(peer: peer),
              environment.isManagementSessionActive() else {
            throw DeviceIdentityError.authenticationCancelled
        }
        switch result {
        case .authenticated(let authenticator):
            do {
                try vault.authorizeDevicePairing(with: peer.deviceID, using: authenticator)
            } catch {
                throw DeviceIdentityError.authenticationFailed
            }
        case .cancelled:
            throw DeviceIdentityError.authenticationCancelled
        case .failed:
            throw DeviceIdentityError.authenticationFailed
        }
    }

    // MARK: Phase

    func applyPairingPhase(_ phase: PairingPhase?) {
        guard let current = pairing, current != .preparing, let phase else { return }
        guard current.isActive else {
            // After pairing, only the iPhone undoing it changes what the sheet shows.
            if case .paired = current, phase == .ended(.undoneByPeer) {
                pairing = .ended(.undoneByPeer)
                environment.log(.pairingEnded(.undoneByPeer))
                finishPairingSession()
            }
            return
        }
        switch phase {
        case .showingQRCode(let qr):
            pairing = .showingQRCode(text: qr.text, expiresAt: qr.qrExpiry)
        case .waitingForResponder(let peer):
            if case .waitingForIPhone(peer, _) = current { return }
            pairing = .waitingForIPhone(peer: peer, since: now)
        case .enteringCode(let peer, let remaining):
            if case .enteringCode = current {} else { environment.log(.revealVerified) }
            pairing = .enteringCode(peer: peer, attemptsRemaining: remaining)
        case .codeAccepted(let peer):
            pairing = .codeAccepted(peer: peer)
        case .waitingForPeer(let peer):
            pairing = .waitingForIPhoneConfirmation(peer: peer)
        case .paired(let peer, _):
            pairing = .paired(peer: peer)
            pairingFeedback = nil
            environment.log(.devicePaired)
            // The add used the authorization. Polling and the hold on idle
            // expiry go on while the sheet is open and the session can still
            // be undone.
            isAuthenticatingPairing = false
            vault.endDevicePairingAuthorization()
            deliveryCheckAfterPairing = peer.deviceID
        case .ended(let reason):
            pairing = .ended(reason)
            environment.log(.pairingEnded(reason))
            finishPairingSession()
            if reason == .identityUnusable { identityBecameUnusable() }
        case .waitingForChallenge, .showingCode:
            // Responder phases; the Mac is always the initiator.
            break
        }
    }

    func failPairing(_ failure: PairingStartFailure) {
        pairing = .failed(failure)
        finishPairingSession()
    }

    /// The session paired, ended or was left: stop its polling and drop its
    /// hold on idle expiry and its authorization.
    func finishPairingSession() {
        pairingPollTask?.cancel()
        pairingPollTask = nil
        pairingAuthentication?.cancel()
        pairingAuthentication = nil
        releaseExpiryHold()
        isAuthenticatingPairing = false
        vault.endDevicePairingAuthorization()
    }

    // MARK: Schedules

    func startPairingPolling() {
        pairingPollTask?.cancel()
        pairingPollTask = nil
        guard environment.automaticPolling else { return }
        let sleep = environment.sleep
        pairingPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, await self.pairingLoopStep() else { return }
                try? await sleep(Self.pairingPollInterval)
            }
        }
    }

    /// One turn of the sheet's polling loop. Returns whether to go on; when
    /// the session can no longer change, also while this turn polled, its
    /// polling and its hold on idle expiry end here.
    func pairingLoopStep() async -> Bool {
        await pairingTick()
        guard !Task.isCancelled else { return false }
        guard pairingIsLive else {
            finishPairingSession()
            return false
        }
        return true
    }

    /// One tick of an open pairing sheet: keeps the management session open
    /// for idleness, or cancels the session when it is gone, then polls. Once
    /// the session can no longer change, its polling and hold end.
    func pairingTick() async {
        guard pairingIsLive else {
            finishPairingSession()
            return
        }
        guard managementSessionIsOpen() else {
            await managementSessionEnded()
            return
        }
        await refresh()
    }

    /// Whether the App's management session is open, renewing the Vault's.
    func managementSessionIsOpen() -> Bool {
        guard environment.isManagementSessionActive() else { return false }
        do {
            try vault.requireDeviceManagementSession()
            return true
        } catch {
            return false
        }
    }

    func acquireExpiryHold() {
        if expiryHold == nil { expiryHold = SessionPolicy.holdIdleExpiry() }
    }

    func releaseExpiryHold() {
        expiryHold?.release()
        expiryHold = nil
    }

    static func status(of answer: CloudKitAccountState) -> DeviceAccountStatus {
        switch answer {
        case .available: return .available
        case .accountChanged: return .accountChanged
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .temporarilyUnavailable
        }
    }
}
