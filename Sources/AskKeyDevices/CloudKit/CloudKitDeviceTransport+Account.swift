import CloudKit
import Foundation

/// The iCloud account as the device services see it. In every state but
/// `available` the caller shows every paired device as unreachable and keeps
/// the list (ADR 0013 → Removal and account changes).
public enum CloudKitAccountState: Hashable, Sendable {
    /// Signed in to the account whose user record name the caller stored, or
    /// signed in with no stored account yet.
    case available(userRecordName: String)
    /// Signed in to another account than the stored one, including a change
    /// while the App was not running. The caller's change token and inbox
    /// belong to the old account; a device with an identity prepares its
    /// inbox again in the new one.
    case accountChanged(userRecordName: String)
    case noAccount
    case restricted
    /// iCloud cannot answer now, or the account needs the person's attention.
    case temporarilyUnavailable
}

extension CloudKitDeviceTransport {
    /// The account state, compared with `storedUserRecordName`: the account
    /// the caller's stored change token belongs to, or nil when it has none.
    /// Call it at launch and whenever `accountChanges` yields. When the
    /// signed-in account differs from the one this transport last saw, or
    /// none is available, the next `prepareInbox()` prepares the inbox again.
    public func accountState(storedUserRecordName: String?) async -> CloudKitAccountState {
        let state = await currentAccountState(storedUserRecordName: storedUserRecordName)
        switch state {
        case .available(let userRecordName), .accountChanged(let userRecordName):
            accountDidChange(to: userRecordName)
        case .noAccount, .restricted, .temporarilyUnavailable:
            accountDidChange(to: nil)
        }
        return state
    }

    private nonisolated func currentAccountState(storedUserRecordName: String?) async -> CloudKitAccountState {
        let status: CKAccountStatus
        do {
            status = try await service.accountStatus()
        } catch {
            return Self.unavailableState(for: error)
        }
        switch status {
        case .available:
            let current: String
            do {
                current = try await service.userRecordName()
            } catch {
                return Self.unavailableState(for: error)
            }
            if let storedUserRecordName, storedUserRecordName != current {
                return .accountChanged(userRecordName: current)
            }
            return .available(userRecordName: current)
        case .noAccount:
            return .noAccount
        case .restricted:
            return .restricted
        case .couldNotDetermine, .temporarilyUnavailable:
            return .temporarilyUnavailable
        @unknown default:
            return .temporarilyUnavailable
        }
    }

    /// Yields whenever the system reports that the iCloud account changed
    /// (`CKAccountChanged`); the caller then asks for `accountState` again.
    public nonisolated static func accountChanges(notificationCenter: NotificationCenter = .default) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observer = notificationCenter.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { _ in
                continuation.yield()
            }
            continuation.onTermination = { _ in notificationCenter.removeObserver(observer) }
        }
    }

    private static func unavailableState(for error: Error) -> CloudKitAccountState {
        CloudKitErrorMapping.cloudKitError(error)?.code == .notAuthenticated ? .noAccount : .temporarilyUnavailable
    }
}
