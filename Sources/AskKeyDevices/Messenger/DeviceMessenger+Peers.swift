import Foundation

extension DeviceMessenger {
    public func pairedDevices() async throws -> [PairedDevice] {
        try await registry.list().devices
    }

    /// Sends a delivery check to a paired device. Its reply, accepted within
    /// the check's 10-minute lifetime, marks the device as reached; without
    /// one the check is recorded as unanswered. Returns the check's message ID.
    @discardableResult
    public func sendDeliveryCheck(to id: DeviceID) async throws -> MessageID {
        guard let entry = try await registry.list().device(id) else { throw DeviceMessengerError.unknownDevice }
        let now = clock.now()
        let sealed = try seal(.deliveryCheck, PairingIDPayload(pairingID: entry.pairingID).encoded, to: entry.card,
                              lifetime: MessageKind.deliveryCheckLifetime, now: now)
        let check = PendingCheck(peer: id, pairingID: entry.pairingID, sentAt: UnixTime.date(UnixTime.seconds(now)),
                                 expiresAt: sealed.envelope.expiresAt)
        let messageID = sealed.inner.messageID
        pendingChecks[messageID] = check
        try await registry.apply(.recordDeliveryCheck(id, pairingID: entry.pairingID, result: .pending(sentAt: check.sentAt)))
        do {
            try await transport.send(sealed.envelope)
        } catch {
            pendingChecks[messageID] = nil
            _ = try? await registry.apply(.recordDeliveryCheck(id, pairingID: entry.pairingID,
                                                               result: .noReply(sentAt: check.sentAt)))
            throw error
        }
        return messageID
    }

    /// Removes a paired device at once, ends any pairing session or delivery
    /// check with it, then sends it an unpair notice. Returns whether the
    /// notice was sent; the local removal holds either way.
    @discardableResult
    public func removeDevice(_ id: DeviceID) async throws -> Bool {
        // End the sessions first, so that none can add the device back while
        // the list is being written.
        let effects = endSessions(with: id)
        dropChecks(for: id)
        var removed: PairedDevice?
        while let entry = try await registry.list().device(id) {
            if try await registry.apply(.remove(id, pairingID: entry.pairingID)) == .applied { removed = entry }
        }
        await perform(effects)
        guard let entry = removed else { throw DeviceMessengerError.unknownDevice }
        do {
            let sealed = try seal(.unpairNotice, PairingIDPayload(pairingID: entry.pairingID).encoded, to: entry.card,
                                  lifetime: MessageKind.unpairNoticeLifetime, now: clock.now())
            try await transport.send(sealed.envelope)
            return true
        } catch {
            return false
        }
    }

    public func renameDevice(_ id: DeviceID, to displayName: String) async throws {
        guard let entry = try await registry.list().device(id),
              try await registry.apply(.rename(id, pairingID: entry.pairingID, displayName: displayName)) == .applied else {
            throw DeviceMessengerError.unknownDevice
        }
    }

    func seal(_ kind: MessageKind, _ payload: Data, to card: DeviceCard, lifetime: TimeInterval,
              now: Date) throws -> MessageCodec.Sealed {
        let sentAt = UnixTime.seconds(now)
        return try MessageCodec.seal(kind: kind, payload: payload, identity: identity, recipient: card.deviceID,
                                     recipientKey: card.agreementPublicKey, preSharedKey: nil, sentAt: sentAt,
                                     expiresAt: sentAt + Int64(lifetime))
    }
}
