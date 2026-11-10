import CloudKit
import Foundation

/// Maps CloudKit's errors to `DeviceTransportError`. Nothing here retries:
/// a failed send is retried only by the caller.
enum CloudKitErrorMapping {
    /// The CloudKit error itself, or the single item's error inside a
    /// partial failure; nil for anything that is not a CloudKit error.
    static func cloudKitError(_ error: Error) -> CKError? {
        guard let error = error as? CKError else { return nil }
        if error.code == .partialFailure, let items = error.partialErrorsByItemID, items.count == 1,
           let item = items.values.first as? CKError {
            return item
        }
        return error
    }

    /// The zone does not exist, or the person deleted it.
    static func isZoneMissing(_ error: Error) -> Bool {
        let code = cloudKitError(error)?.code
        return code == .zoneNotFound || code == .userDeletedZone
    }

    /// The item does not exist.
    static func isUnknownItem(_ error: Error) -> Bool {
        cloudKitError(error)?.code == .unknownItem
    }

    static func transportError(for error: Error) -> Error {
        if error is DeviceTransportError { return error }
        guard let ckError = cloudKitError(error) else {
            return (error as NSError).domain == NSURLErrorDomain ? DeviceTransportError.networkUnavailable
                : DeviceTransportError.serviceUnavailable
        }
        switch ckError.code {
        case .networkUnavailable, .networkFailure, .serverResponseLost:
            return DeviceTransportError.networkUnavailable
        case .requestRateLimited, .zoneBusy:
            return DeviceTransportError.rateLimited(retryAfter: ckError.retryAfterSeconds)
        case .quotaExceeded:
            return DeviceTransportError.quotaExceeded
        case .notAuthenticated, .accountTemporarilyUnavailable:
            return DeviceTransportError.notAuthenticated
        case .zoneNotFound, .userDeletedZone:
            return DeviceTransportError.recipientUnreachable
        case .changeTokenExpired:
            return DeviceTransportError.changeTokenExpired
        default:
            return DeviceTransportError.serviceUnavailable
        }
    }
}
