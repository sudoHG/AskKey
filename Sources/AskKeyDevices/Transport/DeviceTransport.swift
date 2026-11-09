import Foundation

/// Carries envelopes between devices' inboxes. The CloudKit transport
/// (#285) implements it over the account's private database; tests use the
/// in-memory transport in `AskKeyDevicesTestSupport`. Nothing a transport
/// returns is trusted until the recipient has verified it.
public protocol DeviceTransport: Sendable {
    /// Writes the envelope into the inbox of `envelope.recipient`. A missing
    /// inbox is reported as `DeviceTransportError.recipientUnreachable`; a
    /// failed send is never retried without the caller.
    func send(_ envelope: DeviceEnvelope) async throws

    /// The changes in `device`'s own inbox since `token`, or all of it when
    /// `token` is nil. An expired token throws
    /// `DeviceTransportError.changeTokenExpired`.
    func fetchInboxChanges(of device: DeviceID, since token: InboxChangeToken?) async throws -> InboxChanges

    /// Deletes processed or refused messages from `device`'s own inbox.
    func deleteMessages(_ recordNames: [String], from device: DeviceID) async throws
}

/// An opaque position in an inbox's change history. The caller keeps it, per
/// storage namespace and per iCloud account.
public struct InboxChangeToken: Hashable, Sendable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }
}

public struct InboxChanges: Sendable {
    /// Messages added or changed since the token.
    public var envelopes: [DeviceEnvelope]
    /// Records that could not be read as envelopes; they are refused and deleted.
    public var malformedRecordNames: [String]
    public var newToken: InboxChangeToken
    /// More changes follow; fetch again from `newToken`.
    public var moreComing: Bool

    public init(envelopes: [DeviceEnvelope], malformedRecordNames: [String] = [], newToken: InboxChangeToken,
                moreComing: Bool = false) {
        self.envelopes = envelopes
        self.malformedRecordNames = malformedRecordNames
        self.newToken = newToken
        self.moreComing = moreComing
    }
}

public enum DeviceTransportError: Error, Equatable, Sendable {
    /// The change token expired; fetch the whole inbox again from no token.
    case changeTokenExpired
    /// The recipient's inbox does not exist.
    case recipientUnreachable
    case networkUnavailable
    case rateLimited(retryAfter: TimeInterval?)
    case quotaExceeded
    case notAuthenticated
    case serviceUnavailable
}

/// Every time-dependent path takes an injected clock.
public protocol DeviceClock: Sendable {
    func now() -> Date
}

public struct SystemDeviceClock: DeviceClock {
    public init() {}

    public func now() -> Date { Date() }
}
