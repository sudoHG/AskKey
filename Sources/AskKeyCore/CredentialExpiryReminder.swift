import Foundation

public struct CredentialExpirySnapshot: Equatable, Sendable {
    public let id: String
    public let expiresAt: Date?

    public init(id: String, expiresAt: Date?) {
        self.id = id
        self.expiresAt = expiresAt
    }
}

public struct ExpiryReminderLedgerEntry: Equatable, Codable, Sendable {
    public var expiresAt: Date
    public var delivered: Bool

    public init(expiresAt: Date, delivered: Bool) {
        self.expiresAt = expiresAt
        self.delivered = delivered
    }
}

public enum ExpiryReminderWork: Equatable, Sendable {
    case cancel(id: String)
    case deliver(id: String)
    case schedule(id: String, at: Date)
}

public enum CredentialExpiryReminderCopy {
    public static let authorizationDeniedKey =
        "Ask Key could not schedule expiry reminders because notifications are turned off."
    public static let deliveryFailedKey =
        "Ask Key could not deliver an expiry reminder. The reminder will be retried."
}

public enum CredentialExpiryReminderPolicy {
    public static let leadTime: TimeInterval = 7 * 24 * 60 * 60

    public static func remindAt(expiresAt: Date) -> Date {
        expiresAt.addingTimeInterval(-leadTime)
    }

    public static func work(
        snapshot: CredentialExpirySnapshot,
        ledger: ExpiryReminderLedgerEntry?,
        now: Date
    ) -> ExpiryReminderWork? {
        guard let expiresAt = snapshot.expiresAt, expiresAt > now else {
            return ledger == nil ? nil : .cancel(id: snapshot.id)
        }
        if let ledger, ledger.expiresAt == expiresAt {
            return nil
        }
        let remindAt = remindAt(expiresAt: expiresAt)
        if now >= remindAt {
            return .deliver(id: snapshot.id)
        }
        return .schedule(id: snapshot.id, at: remindAt)
    }
}

public final class CredentialExpiryReminderScheduler: @unchecked Sendable {
    public struct Delivery: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case immediate
            case scheduled(Date)
        }

        public let id: String
        public let kind: Kind

        public init(id: String, kind: Kind) {
            self.id = id
            self.kind = kind
        }
    }

    public enum Authorization: Equatable, Sendable {
        case authorized
        case denied
    }

    public typealias Authorize = () throws -> Authorization
    public typealias Deliver = (Delivery, @escaping (Error?) -> Void) -> Void
    public typealias Cancel = (String) -> Void

    private let lock = NSLock()
    private var authorize: Authorize
    private let deliver: Deliver
    private let cancel: Cancel
    private let loadLedger: () -> [String: ExpiryReminderLedgerEntry]
    private let persistLedger: ([String: ExpiryReminderLedgerEntry]) -> Void
    public private(set) var lastAuthorizationFailure: String?
    public private(set) var lastDeliveryFailure: String?

    public init(
        authorize: @escaping Authorize,
        deliver: @escaping Deliver,
        cancel: @escaping Cancel,
        loadLedger: @escaping () -> [String: ExpiryReminderLedgerEntry],
        persistLedger: @escaping ([String: ExpiryReminderLedgerEntry]) -> Void
    ) {
        self.authorize = authorize
        self.deliver = deliver
        self.cancel = cancel
        self.loadLedger = loadLedger
        self.persistLedger = persistLedger
    }

    public func replaceAuthorize(_ authorize: @escaping Authorize) {
        lock.lock()
        self.authorize = authorize
        lock.unlock()
    }

    public func reconcile(snapshots: [CredentialExpirySnapshot], now: Date) {
        var ledger = loadLedger()
        var pending: [ExpiryReminderWork] = []
        var seen = Set<String>()

        for snapshot in snapshots {
            seen.insert(snapshot.id)
            if let work = CredentialExpiryReminderPolicy.work(
                snapshot: snapshot,
                ledger: ledger[snapshot.id],
                now: now
            ) {
                pending.append(work)
            }
        }
        for leftover in ledger.keys where !seen.contains(leftover) {
            pending.append(.cancel(id: leftover))
        }

        let needsNotification = pending.contains { work in
            switch work {
            case .deliver, .schedule: return true
            case .cancel: return false
            }
        }
        if needsNotification {
            do {
                switch try authorize() {
                case .authorized:
                    lastAuthorizationFailure = nil
                case .denied:
                    lastAuthorizationFailure = CredentialExpiryReminderCopy.authorizationDeniedKey
                    for work in pending {
                        if case let .cancel(id) = work {
                            cancel(id)
                            ledger.removeValue(forKey: id)
                        }
                    }
                    persistLedger(ledger)
                    return
                }
            } catch {
                lastAuthorizationFailure = CredentialExpiryReminderCopy.authorizationDeniedKey
                persistLedger(ledger)
                return
            }
        } else {
            lastAuthorizationFailure = nil
        }

        lastDeliveryFailure = nil
        for work in pending {
            if case let .cancel(id) = work {
                cancel(id)
                ledger.removeValue(forKey: id)
            }
        }
        persistLedger(ledger)
        for work in pending {
            switch work {
            case .cancel:
                continue
            case let .deliver(id):
                let expiresAt = snapshots.first(where: { $0.id == id })?.expiresAt
                deliver(.init(id: id, kind: .immediate)) { [weak self] error in
                    self?.finishDelivery(id: id, expiresAt: expiresAt, delivered: true, error: error)
                }
            case let .schedule(id, at):
                let expiresAt = snapshots.first(where: { $0.id == id })?.expiresAt
                deliver(.init(id: id, kind: .scheduled(at))) { [weak self] error in
                    self?.finishDelivery(id: id, expiresAt: expiresAt, delivered: false, error: error)
                }
            }
        }
    }

    private func finishDelivery(id: String, expiresAt: Date?, delivered: Bool, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        if error != nil {
            lastDeliveryFailure = CredentialExpiryReminderCopy.deliveryFailedKey
            return
        }
        lastDeliveryFailure = nil
        var ledger = loadLedger()
        if let expiresAt {
            ledger[id] = ExpiryReminderLedgerEntry(expiresAt: expiresAt, delivered: delivered)
        }
        persistLedger(ledger)
    }
}

extension Notification.Name {
    public static let askKeyCredentialSnapshotDidChange = Notification.Name(
        "askKeyCredentialSnapshotDidChange"
    )
}
