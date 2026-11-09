import AskKeyDevices
import Foundation

/// An in-memory stand-in for the account's private database: one inbox per
/// device, record names unique per inbox, and change tokens. Tests can play
/// a writer to the same account: read every record, drop, delay, duplicate,
/// tamper with and re-insert messages, delete records and expire tokens.
public final class InMemoryDeviceTransport: DeviceTransport, @unchecked Sendable {
    /// What happens to one sent envelope.
    public enum Disposition: Sendable {
        case deliver
        /// Lost in transit.
        case drop
        /// Kept back until `releaseDelayed()`.
        case delay
        /// Delivered now, and again when `releaseDelayed()` runs.
        case duplicate
        /// Delivered with changes.
        case tamper(@Sendable (DeviceEnvelope) -> DeviceEnvelope)
    }

    private struct Record {
        let envelope: DeviceEnvelope
        let sequence: Int
    }

    private let lock = NSLock()
    private var inboxes: [String: [String: Record]] = [:]
    private var sequence = 0
    private var tokenGenerations: [String: UInt64] = [:]
    private var delayed: [DeviceEnvelope] = []
    private var sent: [DeviceEnvelope] = []
    private var sendErrors: [DeviceTransportError] = []
    private var rule: (@Sendable (DeviceEnvelope) -> Disposition)?

    public init() {}

    /// Decides the fate of every envelope sent from now on; nil delivers all.
    public var interceptor: (@Sendable (DeviceEnvelope) -> Disposition)? {
        get { lock.withLock { rule } }
        set { lock.withLock { rule = newValue } }
    }

    /// Every envelope passed to `send`, in order, as the sender produced it.
    public var sentEnvelopes: [DeviceEnvelope] { lock.withLock { sent } }

    /// Makes the next sends throw these errors, one per send.
    public func failNextSends(with errors: [DeviceTransportError]) {
        lock.withLock { sendErrors = errors }
    }

    // MARK: DeviceTransport

    public func send(_ envelope: DeviceEnvelope) async throws {
        let disposition: Disposition = try lock.withLock {
            sent.append(envelope)
            if !sendErrors.isEmpty { throw sendErrors.removeFirst() }
            return rule?(envelope) ?? .deliver
        }
        switch disposition {
        case .deliver: insert(envelope, intoInboxOf: envelope.recipient)
        case .drop: break
        case .delay: lock.withLock { delayed.append(envelope) }
        case .duplicate:
            insert(envelope, intoInboxOf: envelope.recipient)
            lock.withLock { delayed.append(envelope) }
        case .tamper(let change):
            let changed = change(envelope)
            insert(changed, intoInboxOf: changed.recipient)
        }
    }

    public func fetchInboxChanges(of device: DeviceID, since token: InboxChangeToken?) async throws -> InboxChanges {
        try lock.withLock {
            let generation = tokenGenerations[device.text, default: 0]
            var after = 0
            if let token {
                guard token.data.count == 16, token.data.prefix(8).reduce(UInt64(0), { $0 << 8 | UInt64($1) }) == generation else {
                    throw DeviceTransportError.changeTokenExpired
                }
                after = Int(token.data.suffix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
            }
            let changed = (inboxes[device.text] ?? [:]).values
                .filter { $0.sequence > after }
                .sorted { $0.sequence < $1.sequence }
                .map(\.envelope)
            return InboxChanges(envelopes: changed, newToken: Self.token(generation: generation, sequence: sequence))
        }
    }

    public func deleteMessages(_ recordNames: [String], from device: DeviceID) async throws {
        lock.withLock {
            for name in recordNames { inboxes[device.text]?[name] = nil }
        }
    }

    // MARK: A writer to the same account

    /// Writes an envelope into any inbox, replacing a record with the same name.
    public func insert(_ envelope: DeviceEnvelope, intoInboxOf recipient: String) {
        lock.withLock {
            sequence += 1
            inboxes[recipient, default: [:]][envelope.recordName] = Record(envelope: envelope, sequence: sequence)
        }
    }

    public func insert(_ envelope: DeviceEnvelope, intoInboxOf device: DeviceID) {
        insert(envelope, intoInboxOf: device.text)
    }

    /// Delivers every delayed envelope to its recipient.
    public func releaseDelayed() {
        let pending = lock.withLock { () -> [DeviceEnvelope] in
            defer { delayed.removeAll() }
            return delayed
        }
        for envelope in pending { insert(envelope, intoInboxOf: envelope.recipient) }
    }

    /// The records in a device's inbox, oldest change first.
    public func records(in device: DeviceID) -> [DeviceEnvelope] {
        lock.withLock {
            (inboxes[device.text] ?? [:]).values.sorted { $0.sequence < $1.sequence }.map(\.envelope)
        }
    }

    public func deleteRecord(named recordName: String, from device: DeviceID) {
        lock.withLock { _ = inboxes[device.text]?.removeValue(forKey: recordName) }
    }

    /// Makes every token issued so far for this inbox expire.
    public func expireChangeTokens(of device: DeviceID) {
        lock.withLock { tokenGenerations[device.text, default: 0] += 1 }
    }

    private static func token(generation: UInt64, sequence: Int) -> InboxChangeToken {
        var data = withUnsafeBytes(of: generation.bigEndian) { Data($0) }
        withUnsafeBytes(of: UInt64(sequence).bigEndian) { data.append(contentsOf: $0) }
        return InboxChangeToken(data: data)
    }
}
