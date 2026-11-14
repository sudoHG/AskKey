import AskKeyDevices
import AskKeyVault
import Foundation
import SystemConfiguration

/// What the device services depend on, so tests and the E2E App can supply
/// their own.
@MainActor
package struct DeviceCoordinatorEnvironment {
    package var vault: Vault
    /// Nil when this build has no CloudKit configured.
    package var backend: (any DeviceServicesBackend)?
    package var inboxState: any DeviceInboxStateStore
    /// System authentication for one pairing confirmation.
    package var authenticate: @MainActor (String) async -> ManagementAuthenticationResult
    /// Whether the person's management session is open in the App.
    package var isManagementSessionActive: @MainActor () -> Bool
    /// The name this Mac proposes to the iPhone.
    package var displayName: @MainActor () -> String
    package var log: @Sendable (DeviceServicesEvent) -> Void
    /// Runs the polling schedules; tests turn it off and poll explicitly.
    package var automaticPolling: Bool
    package var sleep: @Sendable (TimeInterval) async throws -> Void
    /// Whether the Mac's screen is unlocked; locked or unknown is false. It
    /// decides when a request goes to the approvers (ADR 0014).
    package var isScreenUnlocked: @MainActor () -> Bool
    /// When this App process started; nil uses the clock when the
    /// coordinator is created.
    package var launchTime: Date?
    /// Registers for remote notifications once this Mac has an identity.
    package var registerForRemoteNotifications: @MainActor () -> Void
    package var processActivity: DeviceProcessActivity

    package init(
        vault: Vault,
        backend: (any DeviceServicesBackend)?,
        inboxState: any DeviceInboxStateStore,
        authenticate: @escaping @MainActor (String) async -> ManagementAuthenticationResult,
        isManagementSessionActive: @escaping @MainActor () -> Bool,
        displayName: @escaping @MainActor () -> String = DeviceCoordinatorEnvironment.computerName,
        log: @escaping @Sendable (DeviceServicesEvent) -> Void = DeviceServicesEvent.systemLog,
        automaticPolling: Bool = true,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        isScreenUnlocked: @escaping @MainActor () -> Bool = DeviceCoordinatorEnvironment.screenIsUnlocked,
        launchTime: Date? = nil,
        registerForRemoteNotifications: @escaping @MainActor () -> Void = {},
        processActivity: DeviceProcessActivity = .system
    ) {
        self.vault = vault
        self.backend = backend
        self.inboxState = inboxState
        self.authenticate = authenticate
        self.isManagementSessionActive = isManagementSessionActive
        self.displayName = displayName
        self.log = log
        self.automaticPolling = automaticPolling
        self.sleep = sleep
        self.isScreenUnlocked = isScreenUnlocked
        self.launchTime = launchTime
        self.registerForRemoteNotifications = registerForRemoteNotifications
        self.processActivity = processActivity
    }

    package static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    package static func screenIsUnlocked() -> Bool {
        AgentApprovalScreenSession.current() == .unlocked
    }
}

/// One identity's open services. Confined to the main actor with the coordinator.
@MainActor
final class DeviceServices {
    let deviceID: DeviceID
    let identity: PairingAuthorizingIdentity
    let inbox: any DeviceInbox
    let registry: PairedDeviceRegistry
    var messenger: DeviceMessenger
    /// The account whose inbox token `messenger` started from; nil until the
    /// first account check.
    var messengerAccount: String?

    init(identity: PairingAuthorizingIdentity, inbox: any DeviceInbox, registry: PairedDeviceRegistry,
         messenger: DeviceMessenger) {
        deviceID = identity.deviceID
        self.identity = identity
        self.inbox = inbox
        self.registry = registry
        self.messenger = messenger
    }
}

/// The Mac's device services (ADR 0013): it creates and restores the device
/// identity, runs pairing as the initiator, processes incoming messages at
/// launch, after a push hint and when Devices opens, runs delivery checks,
/// removes devices, follows the iCloud account, and publishes the state the
/// Devices section reads. It never exposes the pairing code.
@Observable
@MainActor
package final class DeviceCoordinator {
    static let pairingPollInterval: TimeInterval = 1
    static let deliveryPollInterval: TimeInterval = 2
    static let deliveryPollDuration: TimeInterval = 60
    /// ADR 0013 → Pairing, step 1: the session expires 5 minutes after the QR code.
    static let sessionExtension: TimeInterval = 5 * 60

    package internal(set) var availability: DeviceServicesAvailability
    /// Whether this Mac has its device identity and its services are open.
    package internal(set) var hasIdentity = false
    package internal(set) var account: DeviceAccountStatus = .unknown
    package internal(set) var devices: [PairedDeviceRow] = []
    package internal(set) var pairing: PairingSheetState?
    /// When the open pairing session ends whether or not it succeeded.
    package internal(set) var pairingExpiresAt: Date?
    package internal(set) var pairingFeedback: PairingFeedback?
    package internal(set) var isAuthenticatingPairing = false
    package internal(set) var lastIssue: DeviceActionIssue?
    package internal(set) var storageFailureMessage: String?

    @ObservationIgnored let environment: DeviceCoordinatorEnvironment
    @ObservationIgnored var services: DeviceServices?
    /// Changes whenever the services stop or are replaced, so work that
    /// awaited can tell.
    @ObservationIgnored var lifecycle = 0
    /// Changes whenever a pairing session starts or is left.
    @ObservationIgnored var pairingGeneration = 0
    @ObservationIgnored var expiryHold: SessionExpiryHold?
    @ObservationIgnored var pollTask: Task<Void, Never>?
    @ObservationIgnored var pollRequested = false
    @ObservationIgnored var pairingPollTask: Task<Void, Never>?
    @ObservationIgnored var deliveryPollTask: Task<Void, Never>?
    @ObservationIgnored var deliveryPollDeadline: Date?
    @ObservationIgnored var accountTask: Task<Void, Never>?
    @ObservationIgnored var launchTask: Task<Void, Never>?
    /// Devices whose inbox a send found missing, until they are reached again.
    @ObservationIgnored var unreachableDevices: Set<DeviceID> = []
    @ObservationIgnored var listedDevices: [PairedDevice] = []
    /// The device a pairing just added, which gets a delivery check.
    @ObservationIgnored var deliveryCheckAfterPairing: DeviceID?
    /// The open system authentication prompt for the pairing confirmation;
    /// it is cancelled when the session ends or is left.
    @ObservationIgnored var pairingAuthentication: Task<ManagementAuthenticationResult, Never>?
    /// Changes with every account check, so only the latest one applies.
    @ObservationIgnored var accountCheck = 0

    // MARK: Remote approval (ADR 0014)

    /// Requests that went to approvers, by Broker request ID, with when each
    /// was sent and delivered; nothing else about them.
    package internal(set) var remoteApprovals: [String: RemoteApprovalStatus] = [:]
    /// The last decision from an approver that moved a request out of pending.
    package internal(set) var lastRemoteDecision: RemoteAppliedDecision?
    /// The open "Approve agent requests" sheet's state; nil when none is open.
    package internal(set) var approverConfirmation: ApproverConfirmationState?
    /// The code the open sheet shows while it waits for the iPhone. Its
    /// description is redacted; only the sheet shows `formatted`.
    package internal(set) var approverCode: ApproverCode?
    @ObservationIgnored let launchTime: Date
    @ObservationIgnored var remoteRequests: [String: RemoteRequestTrack] = [:]
    @ObservationIgnored var closedMessages: [MessageID: PendingClosedMessage] = [:]
    @ObservationIgnored var remoteLoopTask: Task<Void, Never>?
    @ObservationIgnored var remoteLoopGeneration = 0
    /// Changes whenever the outstanding requests are dropped or forgotten.
    @ObservationIgnored var remoteStateGeneration = 0
    /// The state generation whose named fetch is out, if any.
    @ObservationIgnored var knownRecordFetchGeneration: Int?
    @ObservationIgnored var nextKnownRecordFetch: Date?
    /// CloudKit's retry-after, counted from its answer; push hints, unlocks
    /// and wakes never fetch before it.
    @ObservationIgnored var knownRecordBackoffUntil: Date?
    @ObservationIgnored var remoteActivity: AnyObject?
    /// Whether the Broker's active-approver set was loaded from the list for
    /// the current services and account.
    @ObservationIgnored var approversLoaded = false
    /// Approvers whose flag was written but whose activation failed.
    @ObservationIgnored var approversAwaitingActivation: Set<PairingID> = []
    @ObservationIgnored var approverAttempt: ApproverAttempt?
    /// Changes whenever an approver confirmation starts or is left.
    @ObservationIgnored var approverGeneration = 0
    @ObservationIgnored var approverAuthentication: Task<ManagementAuthenticationResult, Never>?
    @ObservationIgnored var approverPollTask: Task<Void, Never>?
    @ObservationIgnored var approverExpiryHold: SessionExpiryHold?
    @ObservationIgnored var registeredForRemoteNotifications = false

    package init(environment: DeviceCoordinatorEnvironment) {
        self.environment = environment
        availability = environment.backend == nil ? .notConfigured : .loading
        launchTime = environment.launchTime ?? environment.backend?.clock.now() ?? Date()
    }

    var vault: Vault { environment.vault }
    var now: Date { environment.backend?.clock.now() ?? Date() }

    // MARK: Lifecycle

    /// At launch: restores a stored identity, checks the account, prepares
    /// the inbox and processes incoming messages. A Mac without an identity
    /// makes no CloudKit request.
    package func start() {
        guard let backend = environment.backend, launchTask == nil else { return }
        let changes = backend.accountChanges()
        accountTask = Task { [weak self] in
            for await _ in changes {
                await self?.accountMayHaveChanged()
            }
        }
        launchTask = Task { [weak self] in
            await self?.launch()
        }
    }

    func launch() async {
        guard openStoredServices() else { return }
        await refreshAccount()
        await refresh()
    }

    /// App termination: stops every schedule.
    package func stop() {
        accountTask?.cancel()
        accountTask = nil
        stopServices()
    }

    /// A local erase is starting (ADR 0013 → Local erase): stops sessions,
    /// polling, delivery checks and pending callbacks, and drops the keys and
    /// the list held in memory. The Vault already refuses every later write
    /// of these services. The inbox is deleted on a best-effort basis,
    /// without waiting for the network.
    package func stopForLocalErase() {
        let inbox = services?.inbox
        stopServices()
        if let inbox {
            Task.detached { try? await inbox.removeInbox() }
        }
        availability = environment.backend == nil ? .notConfigured : .ready
    }

    /// Ends the open services: every task, the pairing session's hold and
    /// authorization, and the identity and list in memory.
    func stopServices() {
        lifecycle += 1
        pairingGeneration += 1
        launchTask?.cancel()
        pollTask?.cancel()
        pollTask = nil
        pairingPollTask?.cancel()
        pairingPollTask = nil
        deliveryPollTask?.cancel()
        deliveryPollTask = nil
        deliveryPollDeadline = nil
        pairingAuthentication?.cancel()
        pairingAuthentication = nil
        releaseExpiryHold()
        vault.endDevicePairingAuthorization()
        stopRemoteApproval()
        services = nil
        hasIdentity = false
        pairing = nil
        pairingExpiresAt = nil
        pairingFeedback = nil
        isAuthenticatingPairing = false
        account = .unknown
        listedDevices = []
        unreachableDevices = []
        deliveryCheckAfterPairing = nil
        devices = []
    }

    /// The Devices section opened: re-reads the identity if it could not be
    /// opened before, checks the account and processes incoming messages.
    package func devicesOpened() async {
        guard environment.backend != nil else { return }
        if services == nil, availability != .identityUnusable { _ = openStoredServices() }
        guard services != nil else { return }
        await refreshAccount()
        await refresh()
    }

    /// A remote notification arrived. A hint for this Mac's inbox only makes
    /// it fetch; nothing in the notification is trusted or shown.
    package func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) {
        guard let backend = environment.backend, let services,
              backend.isPushHint(userInfo, for: services.deviceID) else { return }
        nextKnownRecordFetch = nil
        Task { [weak self] in
            await self?.refresh()
            await self?.remoteApprovalTick()
        }
    }

    // MARK: Services

    /// Restores the stored identity and opens its services. Returns whether
    /// they are open; otherwise `availability` says why.
    func openStoredServices() -> Bool {
        if services != nil { return true }
        guard let backend = environment.backend else { return false }
        let blobs: DeviceIdentityKeyBlobs?
        do {
            blobs = try vault.storedDeviceIdentityKeyBlobs()
        } catch DeviceStorageError.incompleteIdentity, DeviceStorageError.identityRefused {
            identityBecameUnusable()
            return false
        } catch {
            storageUnavailable(error)
            return false
        }
        guard let blobs else {
            availability = .ready
            return false
        }
        let identity: any DeviceIdentity
        do {
            identity = try backend.restoreIdentity(from: blobs)
        } catch {
            // A blob that no longer restores, also on a Mac without a Secure
            // Enclave, leaves an identity that has to be reset.
            identityBecameUnusable()
            return false
        }
        return openServices(identity: identity, inbox: backend.makeInbox(for: DeviceID(messagePublicKey: identity.messagePublicKey)))
    }

    func openServices(identity base: any DeviceIdentity, inbox: any DeviceInbox) -> Bool {
        guard let backend = environment.backend else { return false }
        let registry: PairedDeviceRegistry
        do {
            registry = try vault.pairedDeviceRegistry()
        } catch {
            storageUnavailable(error)
            return false
        }
        let identity = PairingAuthorizingIdentity(base: base) { [weak self] reason in
            guard let self else { throw DeviceIdentityError.authenticationCancelled }
            try await self.authorizePairingSignature(reason: reason)
        }
        let messenger = makeMessenger(identity: identity, registry: registry, inbox: inbox, clock: backend.clock)
        services = DeviceServices(identity: identity, inbox: inbox, registry: registry, messenger: messenger)
        lifecycle += 1
        hasIdentity = true
        availability = .ready
        storageFailureMessage = nil
        registerForRemoteNotificationsOnce()
        return true
    }

    func storageUnavailable(_ error: Error) {
        availability = .storageUnavailable
        storageFailureMessage = UserFacingCopy.message(for: error)
    }

    /// A stored key no longer works: stop polling and pairing, keep the
    /// services' inbox for the reset, and offer the reset.
    func identityBecameUnusable() {
        environment.log(.identityUnusable)
        if pairing?.isActive == true { pairing = .ended(.identityUnusable) }
        finishPairingSession()
        deliveryPollTask?.cancel()
        deliveryPollTask = nil
        // Nothing can be sealed or opened any more; sealed closing messages
        // still go out.
        forgetOutstandingRemoteRequests(keepingClosed: true)
        if approverConfirmation?.isActive == true { endApproverAttempt(.unavailable) }
        availability = .identityUnusable
    }

    // MARK: Account

    func accountMayHaveChanged() async {
        guard services != nil else { return }
        await refreshAccount()
        await refresh()
    }

    /// Asks CloudKit for the account and compares it with the one the list
    /// belongs to.
    func refreshAccount() async {
        guard let services, availability == .ready else { return }
        accountCheck += 1
        let check = accountCheck
        let lifecycle = self.lifecycle
        let stored = (try? environment.inboxState.load()) ?? DeviceInboxState()
        let answer = await services.inbox.accountState(storedUserRecordName: stored.listAccount)
        // A check that started earlier and answered later describes an older account.
        guard lifecycle == self.lifecycle, check == accountCheck else { return }
        await apply(answer, stored: stored, check: check)
    }

    func apply(_ answer: CloudKitAccountState, stored: DeviceInboxState, check: Int) async {
        var state = stored
        let previous = account
        switch answer {
        case .available(let name), .accountChanged(let name):
            var isListAccount = true
            if case .accountChanged = answer {
                isListAccount = false
                // Every approver's authority ends, and nothing can restore it
                // or seal for it, before anything awaits.
                account = .accountChanged
                suspendRemoteApproval()
            }
            if state.listAccount == nil || !isListAccount {
                // No account recorded, or another one: this account becomes the
                // list's only while nothing is paired.
                let lifecycle = self.lifecycle
                let list = try? await services?.registry.list()
                guard check == accountCheck, lifecycle == self.lifecycle else { return }
                isListAccount = list?.devices.isEmpty == true
                if isListAccount {
                    state.listAccount = name
                    try? environment.inboxState.save(state)
                }
            }
            if isListAccount {
                account = .available
            } else {
                if previous != .accountChanged { environment.log(.accountChanged) }
                account = .accountChanged
            }
            await use(account: name, state: state, check: check)
        case .noAccount:
            account = .noAccount
        case .restricted:
            account = .restricted
        case .temporarilyUnavailable:
            account = .temporarilyUnavailable
        }
        if account == .available {
            activateApproversIfNeeded()
        } else {
            suspendRemoteApproval()
        }
        publishRows()
    }

    /// Points the messenger at `name`'s inbox with that account's stored
    /// token, and prepares the inbox there. A pairing session started under
    /// another account ends: its messages are in the other account.
    func use(account name: String, state: DeviceInboxState, check: Int? = nil) async {
        guard let services, services.messengerAccount != name, let backend = environment.backend else { return }
        if services.messengerAccount != nil, pairing?.isActive == true {
            let lifecycle = self.lifecycle
            await cancelPairing()
            // A newer account check may have switched the messenger, and a new
            // session started on it, while the cancellation was sent.
            guard lifecycle == self.lifecycle, check.map({ $0 == accountCheck }) ?? true,
                  self.services === services, services.messengerAccount != name else { return }
        }
        let token = state.tokenAccount == name ? state.inboxToken.map(InboxChangeToken.init(data:)) : nil
        services.messenger = makeMessenger(identity: services.identity, registry: services.registry, inbox: services.inbox,
                                           clock: backend.clock, inboxToken: token)
        services.messengerAccount = name
        let lifecycle = self.lifecycle
        do {
            _ = try await services.inbox.prepareInbox()
        } catch {
            guard lifecycle == self.lifecycle else { return }
            environment.log(.inboxPreparationFailed)
        }
    }

    // MARK: Polling

    /// Processes the inbox now, or joins the poll already running and makes
    /// it poll once more.
    package func refresh() async {
        if let running = pollTask {
            pollRequested = true
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.pollRequested = false
                await self.pollOnce()
            } while self.pollRequested && !Task.isCancelled
        }
        pollTask = task
        await task.value
        if pollTask == task { pollTask = nil }
    }

    func pollOnce() async {
        guard let services, availability == .ready, account.isSignedIn, let account = services.messengerAccount else {
            await publish()
            return
        }
        let messenger = services.messenger
        let lifecycle = self.lifecycle
        do {
            let report = try await messenger.poll()
            let token = await messenger.inboxToken
            guard lifecycle == self.lifecycle else { return }
            for refusal in report.refusals { environment.log(.messageRefused(refusal)) }
            if services.messenger === messenger, let token { saveToken(token, account: account) }
        } catch DeviceIdentityError.unusable {
            guard lifecycle == self.lifecycle else { return }
            identityBecameUnusable()
        } catch DeviceTransportError.notAuthenticated {
            guard lifecycle == self.lifecycle else { return }
            await refreshAccount()
        } catch {
            guard lifecycle == self.lifecycle else { return }
            environment.log(.pollFailed)
        }
        await publish()
    }

    /// Keeps the token after a fully processed poll, with its account.
    func saveToken(_ token: InboxChangeToken, account: String) {
        var state = (try? environment.inboxState.load()) ?? DeviceInboxState()
        guard state.inboxToken != token.data || state.tokenAccount != account else { return }
        state.inboxToken = token.data
        state.tokenAccount = account
        try? environment.inboxState.save(state)
    }

    // MARK: Publishing

    /// Reads the list and the pairing phase from the messenger and publishes them.
    func publish() async {
        guard let services else { return }
        let lifecycle = self.lifecycle
        let messenger = services.messenger
        let list: PairedDeviceList?
        do {
            list = try await services.registry.list()
        } catch DeviceStorageError.listRefused {
            guard lifecycle == self.lifecycle else { return }
            availability = .listRefused
            list = nil
        } catch {
            list = nil
        }
        let phase = await messenger.pairingPhase
        guard lifecycle == self.lifecycle else { return }
        if let list {
            listedDevices = list.devices
            unreachableDevices = unreachableDevices.filter { id in list.device(id) != nil }
            publishRows()
        }
        if services.messenger === messenger { applyPairingPhase(phase) }
        if let paired = deliveryCheckAfterPairing {
            deliveryCheckAfterPairing = nil
            await sendDeliveryCheck(to: paired)
        }
    }

    func publishRows() {
        let reachable = account == .available
        devices = listedDevices.map { device in
            let reachability: DeviceReachability
            if !reachable || unreachableDevices.contains(device.deviceID) {
                reachability = .unreachable
            } else if let reached = device.lastReachedAt {
                reachability = .reached(at: reached)
            } else {
                reachability = .notReachedYet
            }
            return PairedDeviceRow(id: device.deviceID, pairingID: device.pairingID, displayName: device.displayName,
                                   platform: device.platform, pairedAt: device.pairedAt,
                                   lastDeliveryCheck: device.lastDeliveryCheck, reachability: reachability,
                                   isApprover: device.isApprover)
        }
    }
}

/// The App's one coordinator, which the Devices section reads. The App
/// installs it at launch; it is nil in processes without device services.
@MainActor
package enum DeviceServicesHost {
    package private(set) static var coordinator: DeviceCoordinator?

    static func install(_ coordinator: DeviceCoordinator) {
        self.coordinator = coordinator
    }
}
