import Foundation

/// What became of the records one named fetch asked for.
public struct NamedFetchReport: Hashable, Sendable {
    /// Each found record's outcome, as in a poll, and `failed` for records
    /// that failed to fetch.
    public var outcomes: [String: InboxMessageOutcome] = [:]
    /// Names without a record: "not yet", which is not an error.
    public var notYet: [String] = []
    /// The longest wait CloudKit asked for; wait at least this long before
    /// the next named fetch.
    public var retryAfter: TimeInterval?

    public init() {}
}

/// The handler reported a failure; the message stays for a retry.
struct ApprovalHandlerFailure: Error {}

extension DeviceMessenger {
    /// Kinds 10–14 from a device on the list whose message-key signature
    /// verified: `AskKeyDevices` checks the payload, the pairing ID and the
    /// approval-key signature, then the handler checks the rest and commits
    /// the effect. A handler failure counts toward the three failures. With
    /// `holdingMismatch`, from an open session's peer, a pairing ID that is
    /// not the entry's is held like kinds 6–8; the handler's refusals are final.
    func applyApproval(_ inner: InnerMessage, envelope: DeviceEnvelope, from entry: PairedDevice,
                       holdingMismatch: Bool) async throws -> Outcome {
        switch ApprovalVerification.verify(inner, from: entry) {
        case .failure(.bindingMismatch) where holdingMismatch:
            return .held
        case .failure(let refusal):
            return .refused(refusal, authenticated: true)
        case .success(let message):
            guard let approvalHandler else { return .refused(.unexpectedKind, authenticated: true) }
            let verified = ApprovalVerification.verified(message, inner: inner, envelope: envelope, from: entry)
            switch await approvalHandler(verified) {
            case .processed:
                return .processed
            case .refused(let refusal):
                return .refused(refusal, authenticated: true)
            case .failed:
                throw ApprovalHandlerFailure()
            }
        }
    }

    /// Fetches known records of this device's inbox by name (ADR 0014 →
    /// Polling the known records), such as a decision under its response ID
    /// or a receipt under its receipt ID, and handles each found record
    /// exactly as the zone-change poll does: the same refusal rules and
    /// handler, deletion of processed and refused records, and the same
    /// three-failure limit, so a handler should retry brief work itself
    /// before it answers `failed`. It never moves the change token. A
    /// message both paths find takes effect once. Throws
    /// `DeviceMessengerError.namedFetchUnavailable` when the transport
    /// cannot fetch by name, `DeviceIdentityError` when this device's own key
    /// no longer works, and transport errors.
    public func fetchNamedMessages(_ recordNames: [String]) async throws -> NamedFetchReport {
        guard let fetcher = transport as? any NamedInboxFetching else {
            throw DeviceMessengerError.namedFetchUnavailable
        }
        let fetch = try await fetcher.fetchMessages(named: recordNames, from: deviceID)
        var inbox = InboxReport()
        _ = try await process(fetch.envelopes, malformed: fetch.malformedRecordNames, failed: fetch.failedRecordNames,
                              carrying: [], into: &inbox)
        var report = NamedFetchReport()
        report.outcomes = inbox.outcomes
        report.notYet = fetch.missingRecordNames
        report.retryAfter = fetch.retryAfter
        return report
    }
}
