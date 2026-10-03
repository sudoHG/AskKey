import Foundation
import UserNotifications
import AskKeyVault

enum ExpiryReminderNotificationCopy {
    static func title(language: String = AppLanguage.current) -> String {
        AppLanguage.localized("Ask Key has a credential expiring soon", language: language)
    }

    static func body(language: String = AppLanguage.current) -> String {
        AppLanguage.localized("Open Ask Key to review the expiry date.", language: language)
    }

    static func identifier(for credentialID: String) -> String {
        "askkey-expiry-\(credentialID)"
    }
}

struct ExpiryReminderNotificationCenter {
    var loadAuthorizationStatus: (@escaping (UNAuthorizationStatus) -> Void) -> Void
    var requestAuthorization: (@escaping (Bool) -> Void) -> Void
    var add: (UNNotificationRequest, @escaping (Error?) -> Void) -> Void
    var remove: (String) -> Void

    static let live = ExpiryReminderNotificationCenter(
        loadAuthorizationStatus: { completion in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                completion(settings.authorizationStatus)
            }
        },
        requestAuthorization: { completion in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                completion(granted)
            }
        },
        add: { request, completion in
            UNUserNotificationCenter.current().add(request, withCompletionHandler: completion)
        },
        remove: { id in
            UserNotificationExpiryReminderDelivery.remove(id)
        }
    )
}

@MainActor
final class CredentialExpiryReminderController {
    static let shared = CredentialExpiryReminderController()

    private let vault: () -> Vault
    private let now: () -> Date
    private let notificationCenter: ExpiryReminderNotificationCenter
    private let defaults: UserDefaults
    private let ledgerKey: String
    private var scheduler: CredentialExpiryReminderScheduler?
    private var snapshotObserver: NSObjectProtocol?
    private var revision: UInt64 = 0
    private var latestDeliveryRevision: [String: UInt64] = [:]
    var onAuthorizationFailure: ((String) -> Void)?

    init(
        vault: @escaping () -> Vault = { .shared },
        now: @escaping () -> Date = Date.init,
        defaults: UserDefaults = .standard,
        ledgerKey: String = "askkey.expiryReminderLedger",
        notificationCenter: ExpiryReminderNotificationCenter = .live
    ) {
        self.vault = vault
        self.now = now
        self.defaults = defaults
        self.ledgerKey = ledgerKey
        self.notificationCenter = notificationCenter
    }

    func start() {
        if snapshotObserver == nil {
            snapshotObserver = NotificationCenter.default.addObserver(
                forName: .askKeyCredentialSnapshotDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        }
        reconcile()
    }

    func reconcile() {
        revision += 1
        let captured = revision
        notificationCenter.loadAuthorizationStatus { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, self.revision == captured else { return }
                self.handleAuthorizationStatus(status, revision: captured)
            }
        }
    }

    private func currentSnapshots() -> [CredentialExpirySnapshot]? {
        do {
            return try vault().listCredentialExpirySnapshots()
        } catch {
            return nil
        }
    }

    private func handleAuthorizationStatus(_ status: UNAuthorizationStatus, revision: UInt64) {
        guard self.revision == revision, let snapshots = currentSnapshots() else { return }
        switch status {
        case .notDetermined:
            if needsNotification(snapshots: snapshots) {
                notificationCenter.requestAuthorization { [weak self] granted in
                    Task { @MainActor [weak self] in
                        guard let self, self.revision == revision else { return }
                        self.run(authorized: granted, revision: revision)
                    }
                }
            } else {
                run(authorized: true, revision: revision)
            }
        case .authorized, .provisional, .ephemeral:
            run(authorized: true, revision: revision)
        default:
            run(authorized: false, revision: revision)
        }
    }

    private func needsNotification(snapshots: [CredentialExpirySnapshot]) -> Bool {
        let ledger = loadLedger()
        let current = now()
        return snapshots.contains { snapshot in
            switch CredentialExpiryReminderPolicy.work(
                snapshot: snapshot,
                ledger: ledger[snapshot.id],
                now: current
            ) {
            case .deliver, .schedule:
                return true
            case .cancel, nil:
                return false
            }
        }
    }

    private func run(authorized: Bool, revision: UInt64) {
        guard self.revision == revision, let snapshots = currentSnapshots() else { return }
        let scheduler = CredentialExpiryReminderScheduler(
            authorize: { authorized ? .authorized : .denied },
            deliver: { [weak self] delivery, completion in
                guard let self else { return }
                self.deliver(delivery, revision: revision, completion: completion)
            },
            cancel: { [weak self] id in
                self?.notificationCenter.remove(id)
            },
            loadLedger: { [weak self] in self?.loadLedger() ?? [:] },
            persistLedger: { [weak self] in self?.persistLedger($0) }
        )
        self.scheduler = scheduler
        scheduler.reconcile(snapshots: snapshots, now: now())
        if let failure = scheduler.lastAuthorizationFailure {
            onAuthorizationFailure?(failure)
        }
    }

    private func deliver(
        _ delivery: CredentialExpiryReminderScheduler.Delivery,
        revision: UInt64,
        completion: @escaping (Error?) -> Void
    ) {
        latestDeliveryRevision[delivery.id] = revision
        UserNotificationExpiryReminderDelivery.post(
            delivery,
            now: now(),
            add: notificationCenter.add
        ) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard revision == self.latestDeliveryRevision[delivery.id] else { return }
                guard self.revision == revision else {
                    self.notificationCenter.remove(delivery.id)
                    return
                }
                completion(error)
                if error != nil {
                    self.onAuthorizationFailure?(CredentialExpiryReminderCopy.deliveryFailedKey)
                }
            }
        }
    }

    private func loadLedger() -> [String: ExpiryReminderLedgerEntry] {
        guard let data = defaults.data(forKey: ledgerKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ExpiryReminderLedgerEntry].self, from: data)) ?? [:]
    }

    private func persistLedger(_ ledger: [String: ExpiryReminderLedgerEntry]) {
        defaults.set(try? JSONEncoder().encode(ledger), forKey: ledgerKey)
    }
}

enum UserNotificationExpiryReminderDelivery {
    static func post(
        _ delivery: CredentialExpiryReminderScheduler.Delivery,
        now: Date,
        add: @escaping (UNNotificationRequest, @escaping (Error?) -> Void) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        let content = UNMutableNotificationContent()
        content.title = ExpiryReminderNotificationCopy.title()
        content.body = ExpiryReminderNotificationCopy.body()
        let trigger: UNNotificationTrigger?
        switch delivery.kind {
        case .immediate:
            trigger = nil
        case let .scheduled(date):
            let interval = max(1, date.timeIntervalSince(now))
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        }
        let request = UNNotificationRequest(
            identifier: ExpiryReminderNotificationCopy.identifier(for: delivery.id),
            content: content,
            trigger: trigger
        )
        add(request, completion)
    }

    static func remove(_ credentialID: String) {
        let identifier = ExpiryReminderNotificationCopy.identifier(for: credentialID)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
