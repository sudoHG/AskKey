import AskKeyDevices
import Foundation

/// Face ID or Touch ID, as the welcome screen checks it.
public enum BiometryKind: Hashable, Sendable {
    case faceID
    case touchID
}

public enum BiometryStatus: Hashable, Sendable {
    case enrolled(BiometryKind)
    case notEnrolled(BiometryKind)
    /// The iPhone has no passcode, so Face ID or Touch ID cannot be set up.
    case passcodeNotSet
    /// The person turned Face ID or Touch ID off for Ask Key in Settings.
    case deniedForApp(BiometryKind)
    /// This iPhone has neither Face ID nor Touch ID.
    case unavailable
}

public protocol BiometryChecking: Sendable {
    func status() -> BiometryStatus
}

public enum CameraAccess: Hashable, Sendable {
    case authorized
    case notDetermined
    case denied
    case restricted
    /// No camera, as in the iOS Simulator.
    case unavailable
}

public protocol CameraAccessChecking: Sendable {
    func access() -> CameraAccess
    /// Shows the system's camera prompt once; returns whether access was granted.
    func requestAccess() async -> Bool
}

/// The system notification center as the app uses it. A push is only a
/// hint to fetch the inbox: nothing here acts on a notification's text,
/// category or action.
public protocol NotificationCenterAccess: Sendable {
    /// Asks for alert and sound permission and registers for remote notifications.
    func requestAuthorizationAndRegister() async
    /// At a later launch: registers again, and asks only if the person was never asked.
    func registerAtLaunch() async
    /// The pushes for this device's own inbox that are still in Notification Center.
    func deliveredPushHints(for device: DeviceID) async -> [PushHint]
    func removeDeliveredNotifications(identifiers: [String])
}

/// Creates and restores the device identity with the iPhone's key protection.
public protocol DeviceIdentityFactory: Sendable {
    var isSecureEnclaveAvailable: Bool { get }
    /// Creates three new keys and returns them with their blobs. Throws `DeviceIdentityError`.
    func create() throws -> (identity: any DeviceIdentity, blobs: DeviceIdentityKeyBlobs)
    /// Throws `DeviceIdentityError`.
    func restore(_ blobs: DeviceIdentityKeyBlobs) throws -> any DeviceIdentity
}

/// The inbox transport with the account and inbox calls of the CloudKit transport.
public protocol InboxTransport: DeviceTransport {
    func accountState(storedUserRecordName: String?) async -> CloudKitAccountState
    func prepareInbox() async throws -> InboxPreparation
    func removeInbox() async throws
}

extension CloudKitDeviceTransport: InboxTransport {}

/// Creates the transport. Creating a CloudKit container terminates an app
/// whose signed entitlements lack it, so the app asks for a transport only
/// after the welcome checks passed (or an identity created after them
/// exists) and only when `isConfigured` is true.
public protocol InboxTransportFactory: Sendable {
    /// Whether this build names a CloudKit container in its Info.plist. Only
    /// the Ad Hoc export of `scripts/build-ios.sh` does, together with the
    /// iCloud entitlement.
    var isConfigured: Bool { get }
    /// Nil when the build is not configured.
    func makeTransport(for device: DeviceID) -> (any InboxTransport)?
    /// Yields whenever the system reports an iCloud account change.
    func accountChanges() -> AsyncStream<Void>
}

/// Everything the app reaches outside its own memory. `live()` is the only
/// production wiring; tests pass fakes.
public struct AppEnvironment {
    public var identities: any DeviceIdentityFactory
    public var keychain: any SecureItemStore
    public var localState: any LocalStateStore
    public var biometry: any BiometryChecking
    public var camera: any CameraAccessChecking
    public var notifications: any NotificationCenterAccess
    public var cloud: any InboxTransportFactory
    public var clock: any DeviceClock
    /// The name proposed to the Mac, which can rename the device.
    public var deviceName: @MainActor () -> String

    public init(identities: any DeviceIdentityFactory, keychain: any SecureItemStore, localState: any LocalStateStore,
                biometry: any BiometryChecking, camera: any CameraAccessChecking,
                notifications: any NotificationCenterAccess, cloud: any InboxTransportFactory,
                clock: any DeviceClock, deviceName: @escaping @MainActor () -> String) {
        self.identities = identities
        self.keychain = keychain
        self.localState = localState
        self.biometry = biometry
        self.camera = camera
        self.notifications = notifications
        self.cloud = cloud
        self.clock = clock
        self.deviceName = deviceName
    }
}
