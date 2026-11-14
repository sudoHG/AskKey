import AskKeyDevices
import Foundation

/// An envelope as the app stores it: the record's plaintext routing fields
/// and its HPKE body, never opened content.
struct StoredEnvelope: Codable, Hashable, Sendable {
    var recordType: String
    var recordName: String
    var sender: String
    var recipient: String
    var kind: Int64
    var sentAt: Date
    var expiresAt: Date
    var body: Data

    init(_ envelope: DeviceEnvelope) {
        recordType = envelope.recordType.rawValue
        recordName = envelope.recordName
        sender = envelope.sender
        recipient = envelope.recipient
        kind = envelope.kind
        sentAt = envelope.sentAt
        expiresAt = envelope.expiresAt
        body = envelope.body
    }

    /// Nil when the stored record type is not one of ADR 0013's.
    var envelope: DeviceEnvelope? {
        MessageRecordType(rawValue: recordType).map {
            DeviceEnvelope(recordType: $0, recordName: recordName, sender: sender, recipient: recipient, kind: kind,
                           sentAt: sentAt, expiresAt: expiresAt, body: body)
        }
    }
}

/// The decision this iPhone sealed for a request: its exact bytes, which
/// are the only bytes ever sent for it (ADR 0014 → Seal once).
struct StoredDecision: Codable, Hashable, Sendable {
    var code: UInt8
    var durationCeiling: UInt64
    var envelope: StoredEnvelope

    var decisionCode: ApprovalDecisionCode? { ApprovalDecisionCode(rawValue: code) }
}

/// How the Mac said a request ended, from its approval-closed message.
struct StoredClosed: Codable, Hashable, Sendable {
    var outcome: UInt8
    var appliedCode: UInt8?
    var appliedDuration: UInt64

    init(_ closed: ApprovalClosed) {
        outcome = closed.outcome.rawValue
        appliedCode = closed.appliedCode?.rawValue
        appliedDuration = closed.appliedDuration
    }

    var closedOutcome: ApprovalClosedOutcome? { ApprovalClosedOutcome(rawValue: outcome) }
}

/// One verified request, as received → decision stored → sent → closed or
/// expired (ADR 0014 → iPhone app → Durable state). The display stays in
/// the sealed envelope; the app opens it again with the stateless verifier.
struct StoredRequest: Codable, Hashable, Sendable {
    /// The request's message ID, which is also its record name.
    var recordName: String
    var macID: String
    var pairingID: Data
    var requestDigest: Data
    /// When the Mac App process that sealed it started, on the Mac's clock.
    var launchTime: Date
    /// The end of the countdown on this iPhone's clock, fixed when the
    /// request was first verified.
    var countdownEnd: Date
    /// The request's transport expiry; the entry is deleted once this
    /// iPhone's clock passes it.
    var transportExpiry: Date
    var envelope: StoredEnvelope
    var decision: StoredDecision?
    /// The last time CloudKit saved the decision, on this iPhone's clock.
    var lastSentAt: Date?
    var closed: StoredClosed?
    /// A later request from the same Mac carried a later launch time: this
    /// one died with the Mac App process that sealed it.
    var gone = false
    /// The person dismissed the finished card; the entry stays until its
    /// transport expiry, so a re-inserted copy is not shown again.
    var dismissed = false

    /// Closed, gone, or past its countdown: nothing more can be decided.
    func isFinished(at now: Date) -> Bool {
        closed != nil || gone || now >= countdownEnd
    }
}

/// An approval-closed message that arrived before its request (ADR 0014 →
/// Other kinds): it keeps that request from being shown.
struct StoredMarker: Codable, Hashable, Sendable {
    var macID: String
    var pairingID: Data
    var requestDigest: Data
    /// The closed message's transport expiry.
    var expiresAt: Date
}

/// Everything the approver keeps between launches. It holds ciphertext,
/// digests and times, never opened request content.
struct StoredApprovals: Codable, Hashable, Sendable {
    var version = 1
    /// The iCloud account's user record name when it was saved. A state
    /// saved under another account is dropped, so one whose deletion failed
    /// at an account change never comes back.
    var account: String?
    var requests: [StoredRequest] = []
    var markers: [StoredMarker] = []

    var isEmpty: Bool { requests.isEmpty && markers.isEmpty }

    /// Removes requests and markers whose transport expiry this iPhone's
    /// clock passed. Returns the record names of removed requests.
    @discardableResult
    mutating func prune(now: Date) -> [String] {
        let expired = requests.filter { $0.transportExpiry <= now }.map(\.recordName)
        requests.removeAll { $0.transportExpiry <= now }
        markers.removeAll { $0.expiresAt <= now }
        return expired
    }

    func index(of recordName: String) -> Int? {
        requests.firstIndex { $0.recordName == recordName }
    }
}

/// Where the approver's state lives: a file in the app's own container,
/// protected until first unlock. The notification extension never reads
/// or writes it (ADR 0014 → iPhone app).
public protocol ApprovalStateStore: AnyObject {
    /// An empty state when nothing is stored. Throws when a stored state
    /// cannot be read or decoded.
    func loadApprovals() throws -> Data?
    func saveApprovals(_ data: Data) throws
    /// Deleting a state that does not exist succeeds.
    func removeApprovals() throws
}

public final class FileApprovalStateStore: ApprovalStateStore {
    private let url: URL

    /// `directory` is the app's Application Support directory by default.
    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = base.appendingPathComponent("Approvals", isDirectory: true).appendingPathComponent("approvals.json")
    }

    public func loadApprovals() throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    public func saveApprovals(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func removeApprovals() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}

extension ApprovalStateStore {
    /// The stored state, or an empty one when none is stored. A state that
    /// does not decode is dropped, so the app never acts on a damaged one.
    /// Nil when the stored state cannot be read now: the caller then writes
    /// nothing, so it is not overwritten.
    func load() -> StoredApprovals? {
        let data: Data?
        do {
            data = try loadApprovals()
        } catch {
            AppLog.failure("Reading the stored requests", error)
            return nil
        }
        guard let data else { return StoredApprovals() }
        guard let state = try? JSONDecoder().decode(StoredApprovals.self, from: data), state.version == 1 else {
            AppLog.failure("Decoding the stored requests", CocoaError(.coderReadCorrupt))
            return StoredApprovals()
        }
        return state
    }

    /// Writes the state, trying up to three times before it gives up.
    func save(_ state: StoredApprovals) throws {
        let data = try JSONEncoder().encode(state)
        var lastError: Error?
        for _ in 0..<3 {
            do {
                try saveApprovals(data)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CocoaError(.fileWriteUnknown)
    }
}
