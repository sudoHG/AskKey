import AskKeyDevices
import Foundation
import Observation

/// The app's state: the welcome checks and identity creation, the paired
/// Macs, the pairing flow, inbox processing, the approver (ADR 0014 →
/// iPhone app) and the identity reset. Only this model, in the app
/// process, writes the paired-device list and the stored requests.
@MainActor
@Observable
public final class AppModel {
    public internal(set) var stage: AppStage = .starting
    public internal(set) var welcomeStep: WelcomeStep = .intro
    public internal(set) var pairedMacs: [PairedMacRow] = []
    public internal(set) var accountNotice: AccountNotice?
    public var listNotice: ListNotice?
    public internal(set) var deliveryRecords: [DeliveryRecord] = []
    public internal(set) var isResetting = false
    public internal(set) var resetFailed = false
    /// The pairing flow while its sheet is open.
    public var pairing: PairingFlowModel?
    /// Request cards: pending ones first, by time left, then finished ones.
    public internal(set) var requests: [RequestCard] = []
    /// The request whose decision is being built, with its Face ID prompt.
    public internal(set) var decidingRequest: String?
    public internal(set) var decisionProblems: [String: DecisionProblem] = [:]
    /// A Face ID or Touch ID prompt for the approval key is open; the
    /// privacy cover stays off while the app is inactive for it.
    public internal(set) var isAuthenticating = false
    /// The request a tapped notification opened.
    public var openedRequest: OpenedRequest?
    /// The approver confirmation while its sheet is open.
    public var approverConfirmation: ApproverConfirmationFlow?
    /// A newly paired Mac got a numbered name; the person may rename it.
    public var renamePrompt: RenamePrompt?

    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored var services: DeviceServices?
    @ObservationIgnored var pendingSetup: PendingSetup?
    @ObservationIgnored var accountChecked = false
    @ObservationIgnored var pushHints: [String: PushHint] = [:]
    /// Pushes that arrived before the identity was restored at launch.
    @ObservationIgnored var earlyPushes: [EarlyPush] = []
    /// Macs removed on this iPhone, so their disappearance is not reported
    /// as a removal by the Mac.
    @ObservationIgnored var locallyRemoved: Set<DeviceID> = []
    @ObservationIgnored var inboxWork: Task<Void, Never>?
    @ObservationIgnored var pollAgain = false
    /// The stored requests, decisions and markers, as last saved.
    @ObservationIgnored var approvals = StoredApprovals()
    /// Opened requests by record name, in memory only.
    @ObservationIgnored var openedContent: [String: VerifiedApprovalMessage] = [:]
    /// Pairings whose approval ended in this process: turned off here, or
    /// the Mac removed. Their requests are refused even before the list
    /// write that clears the flag commits.
    @ObservationIgnored var revokedPairings: Set<PairingID> = []
    /// Messages sealed once and sent until saved: receipts and approver
    /// confirmations, by record name.
    @ObservationIgnored var outbox: [String: OutgoingMessage] = [:]
    /// When a failed send may be tried again, by record name.
    @ObservationIgnored var nextAttempts: [String: Date] = [:]
    @ObservationIgnored var sendWork: Task<Void, Never>?
    @ObservationIgnored var sendAgain = false
    /// The record a tapped notification named, until the next fetch shows it.
    @ObservationIgnored var pendingOpen: String?
    /// Push hints already fetched by name.
    @ObservationIgnored var namedFetched: Set<String> = []
    /// The pairings on the list when Mac names were last made unique;
    /// nil until the first time.
    @ObservationIgnored var seenPairings: Set<PairingID>?
    /// The list as last read, for the Macs' names on the cards.
    @ObservationIgnored var knownList: PairedDeviceList?
    @ObservationIgnored private var accountWatch: Task<Void, Never>?
    @ObservationIgnored private var started = false

    public init(environment: AppEnvironment) {
        self.environment = environment
        deliveryRecords = environment.localState.deliveryRecords
    }

    var keychain: IdentityKeychain { IdentityKeychain(store: environment.keychain) }
    var listStore: PairedDeviceListKeychainStore { PairedDeviceListKeychainStore(store: environment.keychain) }

    // MARK: Launch

    /// Restores a stored identity, or shows the welcome screen. Nothing here
    /// creates a CloudKit container unless an identity exists, which only
    /// the welcome checks create.
    public func start() async {
        guard !started else { return }
        started = true
        let blobs: DeviceIdentityKeyBlobs?
        do {
            blobs = try keychain.loadBlobs()
        } catch {
            AppLog.failure("Reading the keys", error)
            stage = error is StoredIdentityError ? .unusableIdentity : .welcome
            if stage == .welcome { welcomeStep = .failed(.keychainFailed) }
            return
        }
        guard let blobs else {
            stage = .welcome
            return
        }
        let identity: any DeviceIdentity
        do {
            identity = try environment.identities.restore(blobs)
            _ = try listStore.loadPairedDeviceList()
        } catch let error as KeychainError {
            // Reading failed; nothing says the stored items are bad.
            AppLog.failure("Reading the paired-device list", error)
            stage = .welcome
            welcomeStep = .failed(.keychainFailed)
            return
        } catch {
            AppLog.failure("Restoring the identity", error)
            stage = .unusableIdentity
            return
        }
        let deviceID = DeviceID(messagePublicKey: identity.messagePublicKey)
        guard let transport = environment.cloud.makeTransport(for: deviceID) else {
            stage = .welcome
            welcomeStep = .failed(.cloudNotConfigured)
            return
        }
        environment.localState.deviceID = deviceID.text
        let token = environment.localState.inboxPosition?.token.map(InboxChangeToken.init(data:))
        await activate(makeServices(identity: identity, transport: transport, inboxToken: token))
        await environment.notifications.registerAtLaunch()
    }

    /// The services with this model as the approver: the handler of
    /// verified approval messages and the hook that runs before a Mac's
    /// removal commits.
    func makeServices(identity: any DeviceIdentity, transport: any InboxTransport,
                      inboxToken: InboxChangeToken?) -> DeviceServices {
        DeviceServices(identity: identity, transport: transport, listStore: listStore, clock: environment.clock,
                       inboxToken: inboxToken,
                       approvalHandler: { [weak self] message in
                           guard let self else { return .failed }
                           return await self.handleApproval(message)
                       },
                       removalHook: { [weak self] entry in
                           await self?.macWillBeRemoved(entry)
                       })
    }

    func activate(_ services: DeviceServices) async {
        self.services = services
        // Loaded before anything can suspend, so a request handled while
        // the stored ones are opened again is added to them, not lost.
        approvals = environment.approvals.load()
        adoptEarlyPushes(for: services.deviceID)
        stage = .ready
        watchAccount()
        await refreshList()
        await restoreApprovals(services)
    }

    // MARK: Welcome

    /// Runs the welcome checks in order, then creates the three keys, stores
    /// them and an empty list, and creates the inbox and subscriptions. The
    /// first failed check stops it with its own explanation.
    public func runWelcomeChecks() async {
        guard stage == .welcome, welcomeStep != .checking else { return }
        welcomeStep = .checking
        // A keychain that could not be read at launch may hold an identity:
        // restore it instead of ever replacing it.
        if pendingSetup == nil {
            do {
                if try keychain.loadBlobs() != nil {
                    welcomeStep = .intro
                    started = false
                    await start()
                    return
                }
            } catch {
                AppLog.failure("Reading the keys", error)
                welcomeStep = error is StoredIdentityError ? .intro : .failed(.keychainFailed)
                if error is StoredIdentityError { stage = .unusableIdentity }
                return
            }
        }
        if let failure = await setUp() {
            welcomeStep = .failed(failure)
        } else {
            welcomeStep = .intro
        }
    }

    struct EarlyPush {
        let userInfo: [AnyHashable: Any]
        let arrivedAt: Date
        let identifier: String?
        /// The person tapped it.
        let opened: Bool
    }

    final class PendingSetup {
        let identity: any DeviceIdentity
        let blobs: DeviceIdentityKeyBlobs
        let transport: any InboxTransport
        var stored = false

        init(identity: any DeviceIdentity, blobs: DeviceIdentityKeyBlobs, transport: any InboxTransport) {
            self.identity = identity
            self.blobs = blobs
            self.transport = transport
        }
    }

    private func setUp() async -> WelcomeFailure? {
        guard environment.identities.isSecureEnclaveAvailable else { return .noSecureEnclave }
        switch environment.biometry.status() {
        case .enrolled: break
        case .notEnrolled(let kind): return .biometryNotEnrolled(kind)
        case .passcodeNotSet: return .passcodeNotSet
        case .deniedForApp(let kind): return .biometryDenied(kind)
        case .unavailable: return .noBiometry
        }
        guard environment.cloud.isConfigured else { return .cloudNotConfigured }
        let setup: PendingSetup
        if let pendingSetup {
            setup = pendingSetup
        } else {
            // The keys exist only in memory until every check passed; a
            // failed check discards them.
            let created: (identity: any DeviceIdentity, blobs: DeviceIdentityKeyBlobs)
            do {
                created = try environment.identities.create()
            } catch DeviceIdentityError.secureEnclaveUnavailable {
                return .noSecureEnclave
            } catch {
                AppLog.failure("Creating the keys", error)
                return .keyCreationFailed
            }
            let deviceID = DeviceID(messagePublicKey: created.identity.messagePublicKey)
            guard let transport = environment.cloud.makeTransport(for: deviceID) else { return .cloudNotConfigured }
            setup = PendingSetup(identity: created.identity, blobs: created.blobs, transport: transport)
        }
        let userRecordName: String
        switch await setup.transport.accountState(storedUserRecordName: nil) {
        case .available(let name), .accountChanged(let name): userRecordName = name
        case .noAccount: return .iCloudSignedOut
        case .restricted: return .iCloudRestricted
        case .temporarilyUnavailable: return .iCloudUnavailable
        }
        await environment.notifications.requestAuthorizationAndRegister()
        let deviceID = DeviceID(messagePublicKey: setup.identity.messagePublicKey)
        if !setup.stored {
            do {
                try keychain.save(setup.blobs)
                try listStore.savePairedDeviceList(PairedDeviceList())
            } catch {
                AppLog.failure("Storing the keys", error)
                try? keychain.deleteEverything()
                return .keychainFailed
            }
            setup.stored = true
            pendingSetup = setup
            environment.localState.deviceID = deviceID.text
        }
        environment.localState.inboxPosition = InboxPosition(userRecordName: userRecordName, token: nil)
        do {
            guard try await setup.transport.prepareInbox().isComplete else { return .iCloudFailed }
        } catch DeviceTransportError.networkUnavailable {
            return .networkUnavailable
        } catch {
            AppLog.failure("Creating the inbox", error)
            return .iCloudFailed
        }
        pendingSetup = nil
        accountChecked = true
        await activate(makeServices(identity: setup.identity, transport: setup.transport, inboxToken: nil))
        return nil
    }

    // MARK: Account

    private func watchAccount() {
        accountWatch?.cancel()
        let changes = environment.cloud.accountChanges()
        accountWatch = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                await self.refreshAccount()
            }
        }
    }

    /// Compares the signed-in account with the stored one. After a change
    /// the old token and any pairing session are dropped and the inbox is
    /// created in the new account; the list is kept. Without an account,
    /// every paired Mac is unreachable until the person signs back in. A
    /// change, a sign-out or a restriction drops the stored requests,
    /// decisions and markers; the approval flags stay (ADR 0014 → Revocation).
    func refreshAccount() async {
        guard let services else { return }
        let stored = environment.localState.inboxPosition?.userRecordName
        let state = await services.transport.accountState(storedUserRecordName: stored)
        guard self.services === services else { return }
        accountChecked = true
        switch state {
        case .available(let name):
            accountNotice = nil
            if stored == nil { environment.localState.inboxPosition = InboxPosition(userRecordName: name, token: nil) }
        case .accountChanged(let name):
            accountNotice = nil
            dropAllApprovals()
            environment.localState.inboxPosition = InboxPosition(userRecordName: name, token: nil)
            closePairing()
            services.restartMessenger()
        case .noAccount:
            accountNotice = .signedOut
            dropAllApprovals()
            return
        case .restricted:
            accountNotice = .restricted
            dropAllApprovals()
            return
        case .temporarilyUnavailable:
            accountNotice = .unavailable
            return
        }
        do {
            _ = try await services.transport.prepareInbox()
        } catch {
            AppLog.failure("Preparing the inbox", error)
        }
    }

    // MARK: Pairing

    public func startPairing() {
        guard stage == .ready, let services, pairing == nil else { return }
        pairing = PairingFlowModel(messenger: services.messenger, camera: environment.camera,
                                   deviceName: environment.deviceName(), host: self)
    }

    /// Closes the pairing sheet. An open session is cancelled, and the Mac told.
    public func closePairing() {
        Task { await closePairingAndWait() }
    }

    func closePairingAndWait() async {
        guard let flow = pairing else { return }
        pairing = nil
        await flow.cancelIfOpen()
        await refreshList()
    }

    func pairingSucceeded(with peer: DeviceID) {
        locallyRemoved.remove(peer)
        Task { await refreshList() }
    }

    func identityBecameUnusable() {
        pairing = nil
        stage = .unusableIdentity
    }

    // MARK: Paired Macs

    /// Removes the Mac at once, then sends it an unpair notice.
    public func removeMac(id: String) async {
        guard let services, let deviceID = DeviceID(text: id),
              let row = pairedMacs.first(where: { $0.id == id }) else { return }
        locallyRemoved.insert(deviceID)
        do {
            let told = try await services.messenger.removeDevice(deviceID)
            listNotice = .removed(name: row.name, macWasTold: told)
        } catch DeviceMessengerError.unknownDevice {
            // Already gone, for example because the Mac removed this iPhone first.
        } catch {
            AppLog.failure("Removing a paired Mac", error)
            listNotice = .removalFailed
        }
        await refreshList()
    }

    /// Reloads the list. Entries that disappeared since `previous` and were
    /// not removed here were removed by their Mac's unpair notice. Mac
    /// names are kept unique first.
    func refreshList(previous: PairedDeviceList? = nil) async {
        guard let services else { return }
        do {
            var list = try await services.registry.list()
            guard self.services === services else { return }
            if await makeNamesUnique(in: list, services: services) {
                list = try await services.registry.list()
                guard self.services === services else { return }
            }
            for device in previous?.devices ?? []
            where list.device(device.deviceID) == nil && !locallyRemoved.contains(device.deviceID) {
                listNotice = .removedByMac(name: device.displayName)
            }
            pairedMacs = list.devices.map(PairedMacRow.init)
            rebuildRequests(list: list)
        } catch PairedDeviceListError.malformed {
            identityBecameUnusable()
        } catch {
            AppLog.failure("Reading the paired-device list", error)
        }
    }
}
