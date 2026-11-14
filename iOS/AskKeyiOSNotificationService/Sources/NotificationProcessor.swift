import AskKeyDevices
import CloudKit
import Foundation
import os

/// The one record a push names, in this iPhone's own inbox, and sends to a
/// Mac's existing inbox. It has no way to delete a record, and it never
/// creates or repairs a zone.
protocol NotificationInbox: Sendable {
    /// Nil when there is no record with that name.
    func fetchMessage(named recordName: String) async throws -> DeviceEnvelope?
    func send(_ envelope: DeviceEnvelope) async throws
}

/// The CloudKit inbox of this iPhone.
struct CloudKitNotificationInbox: NotificationInbox {
    let transport: CloudKitDeviceTransport

    func fetchMessage(named recordName: String) async throws -> DeviceEnvelope? {
        let fetch = try await transport.fetchMessages(named: [recordName], from: transport.deviceID,
                                                      recreatingMissingZone: false)
        return fetch.envelopes.first { $0.recordName == recordName }
    }

    func send(_ envelope: DeviceEnvelope) async throws {
        try await transport.send(envelope)
    }
}

/// A push as the extension reads it: only what CloudKit's query
/// notification says, every part of it a routing hint.
struct PushInfo: Equatable, Sendable {
    /// The record the push names, when it is a message ID.
    let recordName: String?
    let subscriptionID: String?
    let zoneName: String?

    init(userInfo: [AnyHashable: Any]) {
        let query = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification
        let name = query?.recordID?.recordName
        recordName = name.flatMap { MessageID(text: $0) == nil ? nil : $0 }
        subscriptionID = query?.subscriptionID
        zoneName = query?.recordID?.zoneID.zoneName
    }
}

/// Why a notification keeps the generic text. None of them sends anything.
enum GenericReason: Equatable, Sendable {
    case notAMessagePush
    /// The keychain cannot be read, for example before the first unlock
    /// since the phone started, or a key no longer works.
    case keysUnavailable
    case noIdentity
    case otherDevice
    case listUnavailable
    /// This build has no CloudKit container.
    case noContainer
    case fetchFailed
    case notFound
    case refused(DeviceMessageRefusal)
    case notARequest
    case notFromMac
    case notApprover
    /// The system's time ran out; whatever is left sends nothing.
    case timedOut
}

/// A detailed notification: the card sentence, a thread per Mac and the
/// interruption level the budget allows.
struct RequestNotification: Equatable, Sendable {
    let body: String
    let threadIdentifier: String
    let isTimeSensitive: Bool
}

enum NotificationDecision: Equatable, Sendable {
    case generic(GenericReason)
    /// Generic text after replying to a verified delivery check.
    case answeredDeliveryCheck
    case request(RequestNotification)
}

/// Everything the processor uses, so tests can stand in for it.
struct NotificationEnvironment: Sendable {
    var keychain: ExtensionKeychain
    /// Restores the identity from its key blobs; restoring reads only the
    /// public keys and uses no key.
    var restoreIdentity: @Sendable (DeviceIdentityKeyBlobs) throws -> any DeviceIdentity
    /// Nil when this build has no CloudKit container.
    var makeInbox: @Sendable (DeviceID) -> (any NotificationInbox)?
    var clock: any DeviceClock
    var strings: NotificationStrings
}

/// One push, from the record it names to the notification (ADR 0014 →
/// Notification Service Extension). It shows details only for an approval
/// request that verifies and comes from a Mac whose entry carries this
/// iPhone's approval flag, and sends only a receipt for such a request or a
/// reply to a verified delivery check, both with the message key. It never
/// deletes a record, writes the paired-device list, uses the approval key
/// or checks replay. Once the task is cancelled it sends nothing more.
struct NotificationProcessor: Sendable {
    let environment: NotificationEnvironment

    func process(_ push: PushInfo) async -> NotificationDecision {
        let decision = await decide(push)
        NotificationLog.decision(decision, recordName: push.recordName)
        return decision
    }

    private func decide(_ push: PushInfo) async -> NotificationDecision {
        guard let recordName = push.recordName else { return .generic(.notAMessagePush) }
        let identity: any DeviceIdentity
        do {
            guard let blobs = try environment.keychain.identityBlobs() else { return .generic(.noIdentity) }
            identity = try environment.restoreIdentity(blobs)
        } catch {
            return .generic(.keysUnavailable)
        }
        let deviceID = DeviceID(messagePublicKey: identity.messagePublicKey)
        guard CloudKitInboxLayout.isPush(subscriptionID: push.subscriptionID, zoneName: push.zoneName, for: deviceID) else {
            return .generic(.otherDevice)
        }
        let list: PairedDeviceList
        do {
            list = try environment.keychain.pairedDeviceList()
        } catch {
            return .generic(.listUnavailable)
        }
        guard let inbox = environment.makeInbox(deviceID) else { return .generic(.noContainer) }
        let envelope: DeviceEnvelope?
        do {
            envelope = try await inbox.fetchMessage(named: recordName)
        } catch {
            return .generic(Task.isCancelled ? .timedOut : .fetchFailed)
        }
        guard !Task.isCancelled else { return .generic(.timedOut) }
        guard let envelope, envelope.recordName == recordName else { return .generic(.notFound) }
        let verdict: DeviceMessageVerdict
        do {
            verdict = try DeviceMessageVerifier(identity: identity, list: list).verify(envelope, now: environment.clock.now())
        } catch {
            return .generic(.keysUnavailable)
        }
        let sealer = DeviceMessageSealer(identity: identity, clock: environment.clock)
        switch verdict {
        case .refused(let refusal):
            return .generic(.refused(refusal))
        case .deliveryCheck(let check):
            guard let reply = try? sealer.sealDeliveryCheckReply(answering: check) else { return .generic(.keysUnavailable) }
            guard await send(reply.envelope, to: inbox) else { return .generic(.timedOut) }
            NotificationStateStore(keychain: environment.keychain)
                .recordDeliveryCheck(recordName, at: environment.clock.now())
            return .answeredDeliveryCheck
        case .approval(let message):
            guard case .request(let request) = message.message else { return .generic(.notARequest) }
            guard message.sender.platform == .macOS else { return .generic(.notFromMac) }
            guard message.sender.isApprover else { return .generic(.notApprover) }
            let body = NotificationText.requestBody(request, macName: message.sender.displayName,
                                                    strings: environment.strings)
            // The app sends its own receipt when it processes the request,
            // so one that cannot be sealed or sent here changes nothing else.
            if let receipt = try? sealer.sealApprovalReceipt(answering: message) {
                guard await send(receipt.envelope, to: inbox) else { return .generic(.timedOut) }
            }
            guard !Task.isCancelled else { return .generic(.timedOut) }
            let timeSensitive = NotificationStateStore(keychain: environment.keychain)
                .claimTimeSensitive(for: message.senderID, at: environment.clock.now())
            return .request(RequestNotification(body: body, threadIdentifier: "mac_" + message.senderID.text,
                                                isTimeSensitive: timeSensitive))
        }
    }

    /// Sends unless the system's time ran out; false only then. A failed
    /// send is logged and otherwise ignored: the app replies again.
    private func send(_ envelope: DeviceEnvelope, to inbox: any NotificationInbox) async -> Bool {
        guard !Task.isCancelled else { return false }
        do {
            try await inbox.send(envelope)
        } catch {
            NotificationLog.sendFailed(envelope.recordName, error)
        }
        return true
    }
}

/// The unified log, without content: record names and reasons only.
enum NotificationLog {
    private static let logger = Logger(subsystem: "com.sudohg.askkey.ios.notification-service", category: "Notifications")

    static func decision(_ decision: NotificationDecision, recordName: String?) {
        let name = recordName ?? "none"
        switch decision {
        case .generic(let reason):
            logger.notice("Record \(name, privacy: .public): generic text, \(String(describing: reason), privacy: .public)")
        case .answeredDeliveryCheck:
            logger.notice("Record \(name, privacy: .public): answered a delivery check")
        case .request(let notification):
            logger.notice("Record \(name, privacy: .public): request shown, time-sensitive \(notification.isTimeSensitive, privacy: .public)")
        }
    }

    static func sendFailed(_ recordName: String, _ error: Error) {
        let code = (error as? DeviceTransportError).map { String(describing: $0) }
            ?? "\((error as NSError).domain) \((error as NSError).code)"
        logger.error("Sending \(recordName, privacy: .public) failed: \(code, privacy: .public)")
    }
}
