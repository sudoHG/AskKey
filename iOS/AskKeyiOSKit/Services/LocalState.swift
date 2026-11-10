import AskKeyDevices
import Foundation
import os

/// The inbox position: the change token after the last fully processed
/// fetch, stored with the iCloud account it belongs to (ADR 0013 → Push is a hint).
public struct InboxPosition: Codable, Hashable, Sendable {
    public var userRecordName: String
    public var token: Data?

    public init(userRecordName: String, token: Data?) {
        self.userRecordName = userRecordName
        self.token = token
    }
}

/// One delivery check this iPhone answered, without content: when it
/// arrived, its record name, and whether the app found it through a push
/// or by polling its inbox, so a test can tell push delivery from an opened
/// app (ADR 0013 → Pairing, step 9).
public struct DeliveryRecord: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        case push
        case polling
    }

    public let recordName: String
    /// The notification's delivery time for a push; the fetch time otherwise.
    public let arrivedAt: Date
    public let source: Source

    public init(recordName: String, arrivedAt: Date, source: Source) {
        self.recordName = recordName
        self.arrivedAt = arrivedAt
        self.source = source
    }
}

/// A push for this device's own inbox. It only says that something may be
/// waiting; the app fetches and verifies the inbox itself.
public struct PushHint: Hashable, Sendable {
    public let recordName: String
    public let arrivedAt: Date
    /// The delivered notification's request identifier, if it is in Notification Center.
    public let notificationIdentifier: String?

    public init(recordName: String, arrivedAt: Date, notificationIdentifier: String?) {
        self.recordName = recordName
        self.arrivedAt = arrivedAt
        self.notificationIdentifier = notificationIdentifier
    }
}

/// The app's local state outside the keychain. None of it is secret.
public protocol LocalStateStore: AnyObject {
    var inboxPosition: InboxPosition? { get set }
    /// This device's ID, kept so a reset can delete the inbox even when the
    /// keys no longer restore.
    var deviceID: String? { get set }
    var deliveryRecords: [DeliveryRecord] { get set }
    func removeAll()
}

public final class UserDefaultsLocalState: LocalStateStore {
    private enum Key {
        static let inboxPosition = "inboxPosition"
        static let deviceID = "deviceID"
        static let deliveryRecords = "deliveryRecords"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var inboxPosition: InboxPosition? {
        get { decode(InboxPosition.self, Key.inboxPosition) }
        set { encode(newValue, Key.inboxPosition) }
    }

    public var deviceID: String? {
        get { defaults.string(forKey: Key.deviceID) }
        set { defaults.set(newValue, forKey: Key.deviceID) }
    }

    public var deliveryRecords: [DeliveryRecord] {
        get { decode([DeliveryRecord].self, Key.deliveryRecords) ?? [] }
        set { encode(newValue, Key.deliveryRecords) }
    }

    public func removeAll() {
        for key in [Key.inboxPosition, Key.deviceID, Key.deliveryRecords] { defaults.removeObject(forKey: key) }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ key: String) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func encode<Value: Encodable>(_ value: Value?, _ key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}

/// The unified log, without content: no code, no name, no payload. Record
/// names, times and refusal reasons are not secret.
enum AppLog {
    private static let logger = Logger(subsystem: "com.sudohg.askkey.ios", category: "Devices")

    static func delivery(_ record: DeliveryRecord) {
        logger.notice("Delivery check \(record.recordName, privacy: .public) arrived at \(record.arrivedAt.ISO8601Format(), privacy: .public), found by \(record.source.rawValue, privacy: .public)")
    }

    static func refusals(_ refusals: [DeviceMessageRefusal]) {
        for refusal in refusals {
            logger.notice("Refused a message: \(String(describing: refusal), privacy: .public)")
        }
    }

    static func failure(_ operation: StaticString, _ error: Error) {
        logger.error("\(operation, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public) \(Self.code(error), privacy: .public)")
    }

    /// The error's case for the module's own errors, and the domain and
    /// code for system errors; never a message that could carry content.
    private static func code(_ error: Error) -> String {
        switch error {
        case let error as DeviceTransportError: return String(describing: error)
        case let error as DeviceIdentityError: return String(describing: error)
        case let error as DeviceMessengerError: return String(describing: error)
        case let error as KeychainError: return "status \(error.status)"
        default:
            let nsError = error as NSError
            return "\(nsError.domain) \(nsError.code)"
        }
    }
}
