import Foundation

/// Fetches known records of a device's own inbox by name (ADR 0014 →
/// Polling the known records), separate from `DeviceTransport` so that
/// other conformers keep compiling. The CloudKit and in-memory transports
/// adopt it. Like everything a transport returns, the records are routing
/// hints until the messenger has verified them.
public protocol NamedInboxFetching: Sendable {
    /// The records with these names in `device`'s inbox. A name with no
    /// record is reported as missing, not as an error; each record's result
    /// stands on its own. Once the service asks to wait, the names not yet
    /// answered are reported failed with `retryAfter`, and the records
    /// already fetched are returned. Throws a `DeviceTransportError` when
    /// the first request fails as a whole, for example
    /// `rateLimited(retryAfter:)`. The caller waits at least `retryAfter`
    /// before the next fetch.
    func fetchMessages(named recordNames: [String], from device: DeviceID) async throws -> NamedInboxFetch
}

public struct NamedInboxFetch: Sendable {
    public var envelopes: [DeviceEnvelope]
    /// No record has this name yet ("not yet").
    public var missingRecordNames: [String]
    /// Records whose fields do not form an envelope; they are refused and deleted.
    public var malformedRecordNames: [String]
    /// Records that failed to fetch; they are fetched again later.
    public var failedRecordNames: [String]
    /// The longest wait CloudKit asked for, in a per-record answer or a
    /// later request that failed as a whole.
    public var retryAfter: TimeInterval?

    public init(envelopes: [DeviceEnvelope] = [], missingRecordNames: [String] = [], malformedRecordNames: [String] = [],
                failedRecordNames: [String] = [], retryAfter: TimeInterval? = nil) {
        self.envelopes = envelopes
        self.missingRecordNames = missingRecordNames
        self.malformedRecordNames = malformedRecordNames
        self.failedRecordNames = failedRecordNames
        self.retryAfter = retryAfter
    }
}
