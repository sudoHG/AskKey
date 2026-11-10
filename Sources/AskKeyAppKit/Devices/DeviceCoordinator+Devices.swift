import AskKeyDevices
import AskKeyVault
import Foundation

/// Delivery checks, renaming, removal and the identity reset.
extension DeviceCoordinator {
    /// Sends a delivery check, after pairing and on request, then polls every
    /// two seconds for up to a minute; a later reply within the check's
    /// 10-minute lifetime still counts. A device stays "not reached yet"
    /// until the first reply.
    package func sendDeliveryCheck(to id: DeviceID) async {
        guard let services, availability == .ready else { return }
        let lifecycle = self.lifecycle
        lastIssue = nil
        do {
            try await services.messenger.sendDeliveryCheck(to: id)
            guard lifecycle == self.lifecycle else { return }
            unreachableDevices.remove(id)
        } catch DeviceTransportError.recipientUnreachable {
            guard lifecycle == self.lifecycle else { return }
            unreachableDevices.insert(id)
            lastIssue = .deliveryCheckFailed
        } catch DeviceIdentityError.unusable {
            guard lifecycle == self.lifecycle else { return }
            identityBecameUnusable()
        } catch DeviceMessengerError.unknownDevice {
            guard lifecycle == self.lifecycle else { return }
            lastIssue = .deviceNotFound
        } catch {
            guard lifecycle == self.lifecycle else { return }
            lastIssue = .deliveryCheckFailed
        }
        await publish()
        startDeliveryPolling()
    }

    func startDeliveryPolling() {
        deliveryPollDeadline = now.addingTimeInterval(Self.deliveryPollDuration)
        guard environment.automaticPolling, deliveryPollTask == nil else { return }
        let sleep = environment.sleep
        deliveryPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await sleep(Self.deliveryPollInterval)
                guard let self, !Task.isCancelled, let deadline = self.deliveryPollDeadline, self.now < deadline else { break }
                await self.refresh()
            }
            self?.deliveryPollTask = nil
        }
    }

    /// Renames a device, in the management session. A rename prepared
    /// against a row whose entry was removed or paired again since is dropped.
    @discardableResult
    package func renameDevice(_ row: PairedDeviceRow, to displayName: String) async -> Bool {
        guard let services else { return false }
        guard managementSessionIsOpen() else {
            lastIssue = .managementRequired
            return false
        }
        lastIssue = nil
        let outcome: PairedDeviceChangeOutcome
        do {
            outcome = try await services.registry.apply(.rename(row.id, pairingID: row.pairingID, displayName: displayName))
        } catch {
            lastIssue = .actionFailed
            await publish()
            return false
        }
        if outcome == .dropped { lastIssue = .deviceNotFound }
        await publish()
        return outcome == .applied
    }

    /// Removes a device at once, in the management session: from then on its
    /// messages are refused, any pairing session or delivery check with it
    /// ends, and it gets an unpair notice. Removal only reduces trust, so it
    /// needs no fresh authentication.
    @discardableResult
    package func removeDevice(_ id: DeviceID) async -> Bool {
        guard let services else { return false }
        guard managementSessionIsOpen() else {
            lastIssue = .managementRequired
            return false
        }
        let lifecycle = self.lifecycle
        lastIssue = nil
        var removed = false
        do {
            let noticeSent = try await services.messenger.removeDevice(id)
            removed = true
            if !noticeSent, lifecycle == self.lifecycle { lastIssue = .unpairNoticeNotSent }
        } catch DeviceMessengerError.unknownDevice {
            if lifecycle == self.lifecycle { lastIssue = .deviceNotFound }
        } catch DeviceIdentityError.unusable {
            // The device is off the list; only the notice could not be signed.
            removed = true
            if lifecycle == self.lifecycle { identityBecameUnusable() }
        } catch {
            if lifecycle == self.lifecycle { lastIssue = .actionFailed }
        }
        guard lifecycle == self.lifecycle else { return removed }
        unreachableDevices.remove(id)
        await publish()
        return removed
    }

    /// The one action an unusable identity or a refused list offers: deletes
    /// this Mac's inbox when CloudKit is reachable, then the keys, the list
    /// and the inbox state, so the person can pair again. Needs the
    /// management session.
    @discardableResult
    package func resetIdentity() async -> Bool {
        guard availability == .identityUnusable || availability == .listRefused else { return false }
        guard managementSessionIsOpen() else {
            lastIssue = .managementRequired
            return false
        }
        let inbox = services?.inbox
        stopServices()
        let lifecycle = self.lifecycle
        if let inbox { try? await inbox.removeInbox() }
        guard lifecycle == self.lifecycle else { return false }
        do {
            try vault.resetDeviceIdentity()
        } catch {
            storageUnavailable(error)
            return false
        }
        lastIssue = nil
        storageFailureMessage = nil
        availability = .ready
        return true
    }
}
