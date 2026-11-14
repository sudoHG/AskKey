import AskKeyAppKit
import AskKeyDevices
import AskKeyDevicesTestSupport
import CryptoKit
import Foundation

/// Device services for the E2E App (#288) and App tests: software keys, an
/// in-memory transport standing in for the account's private database, and
/// an account the test sets. Nothing here creates a CloudKit object.
package final class FakeDeviceServicesBackend: DeviceServicesBackend, @unchecked Sendable {
    package let transport: InMemoryDeviceTransport
    package let clock: any DeviceClock
    private let lock = NSLock()
    private var secureEnclave = true
    private var account: CloudKitAccountState
    private var failRestore = false
    private var restored: [SoftwareDeviceIdentity] = []
    private var prepared: [DeviceID] = []
    private var removed: [DeviceID] = []
    private var checks = 0
    private var answerGate: (@Sendable () async -> Void)?
    private var fetchHook: (@Sendable () async -> Void)?
    private var preparationError: DeviceTransportError?
    private var namedFetchFailures: [DeviceTransportError] = []
    private var namedFetchWaits: [TimeInterval] = []
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    package init(transport: InMemoryDeviceTransport = InMemoryDeviceTransport(), clock: any DeviceClock = SystemDeviceClock(),
                 account: CloudKitAccountState = .available(userRecordName: "_synthetic-account-1")) {
        self.transport = transport
        self.clock = clock
        self.account = account
    }

    package var isSecureEnclaveAvailable: Bool {
        get { lock.withLock { secureEnclave } }
        set { lock.withLock { secureEnclave = newValue } }
    }

    /// What the next account check answers; `accountChanged` is derived from
    /// the stored account, as CloudKit does.
    package var accountState: CloudKitAccountState {
        get { lock.withLock { account } }
        set { lock.withLock { account = newValue } }
    }

    /// Makes the next restores fail as a key copied to another Mac does.
    package var restoreFails: Bool {
        get { lock.withLock { failRestore } }
        set { lock.withLock { failRestore = newValue } }
    }

    /// Makes inbox preparations throw this error.
    package var inboxPreparationError: DeviceTransportError? {
        get { lock.withLock { preparationError } }
        set { lock.withLock { preparationError = newValue } }
    }

    /// Every identity restored from stored blobs, most recent last.
    package var restoredIdentities: [SoftwareDeviceIdentity] { lock.withLock { restored } }
    /// Each inbox preparation, by device.
    package var preparedInboxes: [DeviceID] { lock.withLock { prepared } }
    /// Each inbox removal, by device.
    package var removedInboxes: [DeviceID] { lock.withLock { removed } }
    /// How many account checks were made.
    package var accountChecks: Int { lock.withLock { checks } }

    /// Runs at the start of every inbox fetch, for example to let time pass
    /// while a poll is out.
    package var beforeFetch: (@Sendable () async -> Void)? {
        get { lock.withLock { fetchHook } }
        set { lock.withLock { fetchHook = newValue } }
    }

    /// Runs after an account check read its answer and before it returns it,
    /// so a test can let a later check overtake an earlier one.
    package var accountAnswerGate: (@Sendable () async -> Void)? {
        get { lock.withLock { answerGate } }
        set { lock.withLock { answerGate = newValue } }
    }

    package var registersForRemoteNotifications: Bool { false }

    /// Makes the next named fetches throw these errors, one per fetch.
    package func failNextNamedFetches(with errors: [DeviceTransportError]) {
        lock.withLock { namedFetchFailures = errors }
    }

    /// Makes the next named fetches ask to wait this long, one per fetch,
    /// as CloudKit's retry-after does.
    package func askNextNamedFetchesToWait(_ seconds: [TimeInterval]) {
        lock.withLock { namedFetchWaits = seconds }
    }

    fileprivate func namedFetchAnswer() throws -> TimeInterval? {
        try lock.withLock {
            if !namedFetchFailures.isEmpty { throw namedFetchFailures.removeFirst() }
            return namedFetchWaits.isEmpty ? nil : namedFetchWaits.removeFirst()
        }
    }

    package func createIdentity() throws -> (identity: any DeviceIdentity, blobs: DeviceIdentityKeyBlobs) {
        let message = P256.Signing.PrivateKey()
        let agreement = P256.KeyAgreement.PrivateKey()
        let approval = P256.Signing.PrivateKey()
        let identity = SoftwareDeviceIdentity(messageKey: message, agreementKey: agreement, approvalKey: approval)
        let blobs = DeviceIdentityKeyBlobs(message: message.rawRepresentation, agreement: agreement.rawRepresentation,
                                           approval: approval.rawRepresentation)
        return (identity, blobs)
    }

    package func restoreIdentity(from blobs: DeviceIdentityKeyBlobs) throws -> any DeviceIdentity {
        guard !restoreFails,
              let message = try? P256.Signing.PrivateKey(rawRepresentation: blobs.message),
              let agreement = try? P256.KeyAgreement.PrivateKey(rawRepresentation: blobs.agreement),
              let approval = try? P256.Signing.PrivateKey(rawRepresentation: blobs.approval) else {
            throw DeviceIdentityError.unusable
        }
        let identity = SoftwareDeviceIdentity(messageKey: message, agreementKey: agreement, approvalKey: approval)
        lock.withLock { restored.append(identity) }
        return identity
    }

    package func makeInbox(for device: DeviceID) -> any DeviceInbox {
        FakeDeviceInbox(backend: self, device: device)
    }

    package func accountChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    /// Plays the system's account-change notification.
    package func signalAccountChange() {
        for continuation in lock.withLock({ Array(continuations.values) }) { continuation.yield() }
    }

    /// The push a test sends for `device`'s inbox.
    package static func pushHint(for device: DeviceID) -> [AnyHashable: Any] {
        ["askkey-synthetic-inbox": device.text]
    }

    package func isPushHint(_ userInfo: [AnyHashable: Any], for device: DeviceID) -> Bool {
        userInfo["askkey-synthetic-inbox"] as? String == device.text
    }

    fileprivate func recordPreparation(_ device: DeviceID) throws {
        try lock.withLock {
            if let preparationError { throw preparationError }
            prepared.append(device)
        }
    }

    fileprivate func recordAccountCheck() -> CloudKitAccountState {
        lock.withLock {
            checks += 1
            return account
        }
    }

    fileprivate func recordRemoval(_ device: DeviceID) {
        lock.withLock { removed.append(device) }
    }
}

/// One device's inbox over the shared in-memory transport.
final class FakeDeviceInbox: DeviceInbox, @unchecked Sendable {
    private let backend: FakeDeviceServicesBackend
    private let device: DeviceID

    init(backend: FakeDeviceServicesBackend, device: DeviceID) {
        self.backend = backend
        self.device = device
    }

    func send(_ envelope: DeviceEnvelope) async throws {
        try await backend.transport.send(envelope)
    }

    func fetchInboxChanges(of device: DeviceID, since token: InboxChangeToken?) async throws -> InboxChanges {
        await backend.beforeFetch?()
        return try await backend.transport.fetchInboxChanges(of: device, since: token)
    }

    func deleteMessages(_ recordNames: [String], from device: DeviceID) async throws {
        try await backend.transport.deleteMessages(recordNames, from: device)
    }

    func prepareInbox() async throws -> InboxPreparation {
        try backend.recordPreparation(device)
        return InboxPreparation()
    }

    func accountState(storedUserRecordName: String?) async -> CloudKitAccountState {
        let state = backend.recordAccountCheck()
        await backend.accountAnswerGate?()
        if case .available(let current) = state, let storedUserRecordName, storedUserRecordName != current {
            return .accountChanged(userRecordName: current)
        }
        return state
    }

    func removeInbox() async throws {
        backend.recordRemoval(device)
    }
}

extension FakeDeviceInbox: NamedInboxFetching {
    func fetchMessages(named recordNames: [String], from device: DeviceID) async throws -> NamedInboxFetch {
        await backend.beforeFetch?()
        let wait = try backend.namedFetchAnswer()
        var fetch = try await backend.transport.fetchMessages(named: recordNames, from: device)
        fetch.retryAfter = wait
        return fetch
    }
}

/// An iPhone in the same process: software keys, its own list in memory,
/// and the backend's transport and clock. It pairs, and acts as an approver
/// (ADR 0014): it keeps every verified request and closed message, and sends
/// decisions, receipts and approver confirmations. The person's steps on the
/// phone are its methods.
package final class SimulatedPairingPhone: @unchecked Sendable {
    package let identity = SoftwareDeviceIdentity()
    package let store = InMemoryPairedDeviceListStore()
    package let messenger: DeviceMessenger
    package let approvals = SimulatedApproverInbox()
    private let transport: any DeviceTransport

    package init(transport: any DeviceTransport, clock: any DeviceClock) {
        self.transport = transport
        let approvals = self.approvals
        messenger = DeviceMessenger(identity: identity, platform: .iOS, registry: PairedDeviceRegistry(store: store),
                                    transport: transport, clock: clock,
                                    approvalHandler: { approvals.handle($0) })
    }

    package var deviceID: DeviceID { messenger.deviceID }

    package func scan(_ qrText: String, name: String = "Synthetic Phone") async throws {
        try await messenger.joinPairing(scannedText: qrText, displayName: name)
    }

    @discardableResult
    package func poll() async throws -> InboxReport {
        try await messenger.poll()
    }

    /// The code the phone's pairing screen shows, once its reveal was sent.
    package func shownCode() async -> String? {
        if case .showingCode(let code, _, _) = await messenger.pairingPhase { return code.formatted }
        return nil
    }

    package func confirm() async throws {
        try await messenger.confirmPairing(approvalReason: "Synthetic phone confirmation")
    }

    package func cancel() async {
        await messenger.cancelPairing()
    }

    package func pairedDevices() async throws -> [PairedDevice] {
        try await messenger.pairedDevices()
    }

    package var phase: PairingPhase? {
        get async { await messenger.pairingPhase }
    }

    // MARK: Approver

    /// Every verified approval request this phone received, oldest first.
    package var requests: [VerifiedApprovalMessage] { approvals.requests }
    /// Every verified closed message this phone received, oldest first.
    package var closedMessages: [VerifiedApprovalMessage] { approvals.closed }

    /// Seals a decision for a received request and saves it to the Mac's inbox.
    @discardableResult
    package func decide(_ code: ApprovalDecisionCode, on request: VerifiedApprovalMessage) async throws -> SealedDeviceMessage {
        let sealed = try await messenger.sealer.sealApprovalDecision(code, answering: request,
                                                                     approvalReason: "Synthetic phone decision")
        try await transport.send(sealed.envelope)
        return sealed
    }

    @discardableResult
    package func sendReceipt(for request: VerifiedApprovalMessage) async throws -> SealedDeviceMessage {
        let sealed = try messenger.sealer.sealApprovalReceipt(answering: request)
        try await transport.send(sealed.envelope)
        return sealed
    }

    /// Types the code under the Mac's entry and sends the confirmation.
    package func confirmApprover(typing code: String, for mac: DeviceID) async throws {
        guard let entry = try await messenger.pairedDevices().first(where: { $0.deviceID == mac }),
              let typed = ApproverCode(typed: code) else { throw DeviceMessengerError.unknownDevice }
        let sealed = try await messenger.sealer.sealApproverConfirmation(typed, to: entry,
                                                                         approvalReason: "Synthetic phone confirmation")
        try await transport.send(sealed.envelope)
    }

    /// Saves an envelope to the Mac's inbox as it is, for example to re-insert one.
    package func send(_ envelope: DeviceEnvelope) async throws {
        try await transport.send(envelope)
    }
}

/// What a simulated approver keeps from the Mac's approval messages.
package final class SimulatedApproverInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedRequests: [VerifiedApprovalMessage] = []
    private var receivedClosed: [VerifiedApprovalMessage] = []

    package var requests: [VerifiedApprovalMessage] { lock.withLock { receivedRequests } }
    package var closed: [VerifiedApprovalMessage] { lock.withLock { receivedClosed } }

    func handle(_ message: VerifiedApprovalMessage) -> ApprovalMessageHandling {
        lock.withLock {
            switch message.message {
            case .request:
                receivedRequests.append(message)
                return .processed
            case .closed:
                receivedClosed.append(message)
                return .processed
            case .decision, .receipt, .confirmation:
                return .refused(.unexpectedKind)
            }
        }
    }
}
