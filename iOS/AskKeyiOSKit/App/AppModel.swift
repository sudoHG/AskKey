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
    public internal(set) var requests: [RequestCard] = [] {
        didSet { noteArrivals(after: oldValue) }
    }
    /// Requests that arrived after launch reopened the stored ones and whose
    /// rows the Requests tab has not shown yet; those rows are highlighted.
    public internal(set) var unseenArrivals: Set<String> = []
    /// The request whose decision is being built, with its Face ID prompt.
    public internal(set) var decidingRequest: String?
    public internal(set) var decisionProblems: [String: DecisionProblem] = [:]
    /// A Face ID or Touch ID prompt for the approval key is open; the
    /// privacy cover stays off while the app is inactive for it.
    public internal(set) var isAuthenticating = false
    /// The request a tapped notification opened; its sheet shows at once.
    public var openedRequest: OpenedRequest?
    /// The tapped record while its request has no card yet.
    public internal(set) var opening: OpeningRequest?
    /// A newly paired Mac got a numbered name; the person may rename it.
    public var renamePrompt: RenamePrompt?
    /// The home's tab. A request that arrives never changes it (ADR 0014 →
    /// iPhone app, Finished and arriving requests).
    public var selectedTab: HomeTab = .requests
    /// Whether Ask Key may show notifications, as last read: at launch,
    /// after the welcome's prompt and whenever the app becomes active; nil
    /// until the first read.
    public internal(set) var notificationAuthorization: NotificationAuthorization?
    /// Face ID or Touch ID, for the Requests tab's footnote.
    public internal(set) var biometryKind: BiometryKind = .faceID

    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored var services: DeviceServices?
    @ObservationIgnored var pendingSetup: PendingSetup?
    /// The iCloud account was checked since the identity was restored or
    /// created; observed, so This iPhone says nothing about iCloud before.
    var accountChecked = false
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
    /// False while the stored state exists but cannot be read; nothing is
    /// then accepted, decided or written, so it is never overwritten.
    @ObservationIgnored var approvalsReadable = true
    /// Requests settled in this process, so a notification found later for
    /// one of them is removed at once.
    @ObservationIgnored var settledRequests: Set<String> = []
    /// Further delivered notifications for a record name beyond its hint's.
    @ObservationIgnored var extraNotifications: [String: Set<String>] = [:]
    /// CloudKit asked to wait until then before the next fetch by name.
    @ObservationIgnored var namedFetchNotBefore: Date?
    /// Opened requests by record name, in memory only.
    @ObservationIgnored var openedContent: [String: VerifiedApprovalMessage] = [:]
    /// Pairings whose Mac was removed in this process: here, by its unpair
    /// notice or by pairing again. Their requests are refused from the
    /// moment the removal starts, even if its list write then fails.
    @ObservationIgnored var revokedPairings: Set<PairingID> = []
    /// Receipts sealed once and sent until saved, by record name.
    @ObservationIgnored var outbox: [String: OutgoingMessage] = [:]
    /// When a failed send may be tried again, by record name.
    @ObservationIgnored var nextAttempts: [String: Date] = [:]
    @ObservationIgnored var sendWork: Task<Void, Never>?
    @ObservationIgnored var sendAgain = false
    /// Tapped records' own fetches by name while they run, by record name.
    @ObservationIgnored var openingWork: [String: Task<Void, Never>] = [:]
    /// Records fetched by name for a tapped notification whose requests
    /// cannot be decided, and whose receipts wait, until a zone poll that
    /// started afterwards has run.
    @ObservationIgnored var uncheckedRequests: Set<String> = []
    /// Push hints already fetched by name.
    @ObservationIgnored var namedFetched: Set<String> = []
    /// The pairings on the list when Mac names were last made unique;
    /// nil until the first time.
    @ObservationIgnored var seenPairings: Set<PairingID>?
    /// The list as last read, for the Macs' names on the cards.
    @ObservationIgnored var knownList: PairedDeviceList?
    /// Launch reopened the stored requests; cards that appear from now on arrived.
    @ObservationIgnored var storedRequestsRestored = false
    // History (#349, `AppModel+History.swift`).
    /// Completed entries, most recently ended first, as History shows them.
    var history: [HistoryEntry] = []
    /// Completed entries whose last write succeeded.
    var savedHistory: Set<String> = []
    /// History shows only this Mac's entries, by device ID.
    var historyFilter: HistoryFilter?
    /// The History entry whose detail is open.
    var historyDetail: String?
    /// Open and completed entries, as last loaded or changed.
    @ObservationIgnored var historyState = StoredHistory()
    /// The file was read, or found missing, under the current account;
    /// until then nothing is written over it.
    @ObservationIgnored var historyReadable = false
    /// A change that is not written yet; the next save writes it.
    @ObservationIgnored var historyNeedsSave = false
    /// A deletion that has not succeeded yet: nothing is read or written first.
    @ObservationIgnored var historyDeletionPending = false
    /// The key and the file are known to be deleted, and nothing was written since.
    @ObservationIgnored var historyErased = false
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
        retryHistoryDeletion()
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
            // Also names the Macs of history entries completed at launch.
            knownList = try listStore.loadPairedDeviceList()
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
        await refreshNotificationAuthorization()
    }

    /// The services with this model as the approver: the handler of
    /// verified approval messages and the hook that runs before a Mac's
    /// removal commits.
    func makeServices(identity: any DeviceIdentity, transport: any InboxTransport,
                      inboxToken: InboxChangeToken?) -> DeviceServices {
        DeviceServices(identity: identity, transport: transport, listStore: listStore, clock: environment.clock,
                       inboxToken: inboxToken,
                       approvalHandler: { [weak self] message, generation in
                           guard let self else { return .failed }
                           return await self.handleApproval(message, generation: generation)
                       },
                       removalHook: { [weak self] entry in
                           await self?.macWillBeRemoved(entry)
                       })
    }

    func activate(_ services: DeviceServices) async {
        self.services = services
        // Loaded before anything can suspend, so a request handled while
        // the stored ones are opened again is added to them, not lost.
        loadApprovals()
        loadHistory()
        readBiometryKind()
        adoptEarlyPushes(for: services.deviceID)
        stage = .ready
        watchAccount()
        await refreshList()
        await restoreApprovals(services)
        storedRequestsRestored = true
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
        // A new identity starts without an earlier one's history (#345).
        if pendingSetup == nil { deleteHistory() }
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
        await refreshNotificationAuthorization()
        let deviceID = DeviceID(messagePublicKey: setup.identity.messagePublicKey)
        if !setup.stored {
            do {
                // The notification extension may have written its state again
                // while a reset deleted it; a new identity starts without it (#331).
                try environment.keychain.deleteData(for: DeviceKeychainAccount.notificationServiceState)
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
    /// decisions and markers and deletes the history, even when no request
    /// is stored; the approval flags stay (ADR 0014 → Revocation).
    func refreshAccount() async {
        guard let services, await checkAccount(services) else { return }
        await prepareInbox(services)
    }

    /// The account part of `refreshAccount`. Returns true when an account is
    /// signed in, so the inbox is to be prepared; an inbox pass prepares it
    /// only after the tapped record's own fetch (#337).
    func checkAccount(_ services: DeviceServices) async -> Bool {
        let stored = environment.localState.inboxPosition?.userRecordName
        let state = await services.transport.accountState(storedUserRecordName: stored)
        guard self.services === services else { return false }
        accountChecked = true
        switch state {
        case .available(let name):
            accountNotice = nil
            if stored == nil { environment.localState.inboxPosition = InboxPosition(userRecordName: name, token: nil) }
        case .accountChanged(let name):
            accountNotice = nil
            dropAllApprovals()
            deleteHistory()
            environment.localState.inboxPosition = InboxPosition(userRecordName: name, token: nil)
            closePairing()
            services.restartMessenger()
        case .noAccount:
            accountNotice = .signedOut
            dropAllApprovals()
            deleteHistory()
            return false
        case .restricted:
            accountNotice = .restricted
            dropAllApprovals()
            deleteHistory()
            return false
        case .temporarilyUnavailable:
            accountNotice = .unavailable
            return false
        }
        return true
    }

    func prepareInbox(_ services: DeviceServices) async {
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

    /// Removes the Mac: this iPhone stops approving it before anything
    /// waits, then the list write removes it and an unpair notice tells the
    /// Mac, which stops trusting this iPhone only when it processes the
    /// notice (ADR 0014 → Revocation). Returns false when the Mac could not
    /// be removed; this process keeps refusing its requests anyway.
    @discardableResult
    public func removeMac(id: String) async -> Bool {
        guard let services, let deviceID = DeviceID(text: id),
              let row = pairedMacs.first(where: { $0.id == id }) else { return false }
        locallyRemoved.insert(deviceID)
        // The removal hook does the same again before the list write commits.
        if let entry = knownList?.device(deviceID) { revoke(entry) }
        var removed = true
        do {
            let told = try await services.messenger.removeDevice(deviceID)
            listNotice = .removed(name: row.name, macWasTold: told)
        } catch DeviceMessengerError.unknownDevice {
            // Already gone, for example because the Mac removed this iPhone first.
        } catch {
            AppLog.failure("Removing a paired Mac", error)
            listNotice = .removalFailed
            // Still listed: if its unpair notice removes it later, that is reported.
            locallyRemoved.remove(deviceID)
            removed = false
        }
        await refreshList()
        return removed
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
            pairedMacs = list.devices.map { PairedMacRow($0, revoked: revokedPairings.contains($0.pairingID)) }
            rebuildRequests(list: list)
        } catch PairedDeviceListError.malformed {
            identityBecameUnusable()
        } catch {
            AppLog.failure("Reading the paired-device list", error)
        }
    }
}
