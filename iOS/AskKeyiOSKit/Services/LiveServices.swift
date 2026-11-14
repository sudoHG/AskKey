import AskKeyDevices
import AVFoundation
import CloudKit
import Foundation
import LocalAuthentication
import UIKit
import UserNotifications

/// The iPhone's key protection (ADR 0013 → Key access control): the message
/// and key-agreement keys work after first unlock without a prompt, so a
/// delivery reply or an unpair notice never asks for Face ID; the approval
/// key needs the device unlocked and the currently enrolled Face ID or Touch
/// ID for every signature, with no passcode fallback.
enum IPhoneKeyProtection {
    static let protections = DeviceKeyProtections(
        message: DeviceKeyProtection(accessibility: .afterFirstUnlockThisDeviceOnly, authentication: .none),
        agreement: DeviceKeyProtection(accessibility: .afterFirstUnlockThisDeviceOnly, authentication: .none),
        approval: DeviceKeyProtection(accessibility: .whenUnlockedThisDeviceOnly, authentication: .biometryCurrentSet))
}

struct SecureEnclaveIdentityFactory: DeviceIdentityFactory {
    var isSecureEnclaveAvailable: Bool { SecureEnclaveDeviceIdentity.isAvailable }

    func create() throws -> (identity: any DeviceIdentity, blobs: DeviceIdentityKeyBlobs) {
        let identity = try SecureEnclaveDeviceIdentity.create(protections: IPhoneKeyProtection.protections)
        return (identity, identity.keyBlobs)
    }

    func restore(_ blobs: DeviceIdentityKeyBlobs) throws -> any DeviceIdentity {
        try SecureEnclaveDeviceIdentity.restore(from: blobs)
    }
}

struct LocalAuthenticationBiometry: BiometryChecking {
    func status() -> BiometryStatus {
        let context = LAContext()
        defer { context.invalidate() }
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        let kind: BiometryKind = context.biometryType == .touchID ? .touchID : .faceID
        if canEvaluate { return .enrolled(kind) }
        switch error.flatMap({ LAError.Code(rawValue: $0.code) }) {
        case .biometryNotEnrolled: return .notEnrolled(kind)
        case .passcodeNotSet: return .passcodeNotSet
        // Locked out after failed attempts: still enrolled; the prompt unlocks it.
        case .biometryLockout: return .enrolled(kind)
        case .biometryNotAvailable: return context.biometryType == .none ? .unavailable : .deniedForApp(kind)
        default: return .unavailable
        }
    }
}

struct AVCameraAccess: CameraAccessChecking {
    func access() -> CameraAccess {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        default: return .denied
        }
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }
}

struct UserNotificationCenterAccess: NotificationCenterAccess {
    func requestAuthorizationAndRegister() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            AppLog.failure("Notification authorization", error)
        }
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }

    func registerAtLaunch() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            await requestAuthorizationAndRegister()
        } else {
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func deliveredPushHints(for device: DeviceID) async -> [PushHint] {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        return delivered.compactMap { notification in
            PushHintReader.hint(userInfo: notification.request.content.userInfo, arrivedAt: notification.date,
                                notificationIdentifier: notification.request.identifier, for: device)
        }
    }

    func removeDeliveredNotifications(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Reads the container from the Info.plist key `CloudKitContainerIdentifier`
/// (ADR 0013 → Identifiers). Only the Ad Hoc export sets it, and only that
/// build carries the iCloud entitlement; every other build has it empty and
/// never creates a container.
public struct CloudKitTransportFactory: InboxTransportFactory {
    let containerIdentifier: String?

    public init(bundle: Bundle = .main) {
        containerIdentifier = (bundle.object(forInfoDictionaryKey: "CloudKitContainerIdentifier") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    public var isConfigured: Bool { containerIdentifier != nil }

    public func makeTransport(for device: DeviceID) -> (any InboxTransport)? {
        guard let containerIdentifier else { return nil }
        return CloudKitDeviceTransport(containerIdentifier: containerIdentifier, deviceID: device, platform: .iOS)
    }

    public func accountChanges() -> AsyncStream<Void> {
        CloudKitDeviceTransport.accountChanges()
    }
}

/// Turns a received notification into a hint, only when it is a CloudKit
/// query notification for this device's own inbox (ADR 0013 → CloudKit
/// layout); subscriptions belong to the account, so other devices' pushes
/// arrive here too. The notification extension replaces the user info with
/// only the record name under `extensionRecordNameKey` (ADR 0014); such a
/// name is a hint too when it is a message ID, and a name from another
/// device's inbox is simply not found in this one.
enum PushHintReader {
    static let extensionRecordNameKey = "askkey.recordName"

    static func hint(userInfo: [AnyHashable: Any], arrivedAt: Date, notificationIdentifier: String?,
                     for device: DeviceID) -> PushHint? {
        if let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) {
            guard CloudKitInboxLayout.isPush(notification, for: device),
                  let recordName = (notification as? CKQueryNotification)?.recordID?.recordName else { return nil }
            return PushHint(recordName: recordName, arrivedAt: arrivedAt, notificationIdentifier: notificationIdentifier)
        }
        guard let recordName = userInfo[extensionRecordNameKey] as? String, MessageID(text: recordName) != nil else {
            return nil
        }
        return PushHint(recordName: recordName, arrivedAt: arrivedAt, notificationIdentifier: notificationIdentifier)
    }
}

extension AppEnvironment {
    /// The production wiring. Nothing here creates a CloudKit container.
    public static func live() -> AppEnvironment {
        AppEnvironment(identities: SecureEnclaveIdentityFactory(), keychain: DataProtectionKeychain(),
                       localState: UserDefaultsLocalState(), biometry: LocalAuthenticationBiometry(),
                       camera: AVCameraAccess(), notifications: UserNotificationCenterAccess(),
                       cloud: CloudKitTransportFactory(), clock: SystemDeviceClock(),
                       approvals: FileApprovalStateStore(), deviceName: { UIDevice.current.name })
    }
}
