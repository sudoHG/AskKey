import Foundation

/// Notification metadata is an allow-listed destination, never display or request data.
enum NotificationRoute: Equatable {
    case main
    case pendingRequests
    case credential(String)
    /// A gentle reminder for an update a scheduled check found (ADR 0011).
    case softwareUpdate

    init(userInfo: [AnyHashable: Any]) {
        switch userInfo["route"] as? String {
        case "pendingRequests" where userInfo.count == 1:
            self = .pendingRequests
        case "softwareUpdate" where userInfo.count == 1:
            self = .softwareUpdate
        case "credential" where userInfo.count == 2:
            guard let id = userInfo["credentialID"] as? String,
                  UUID(uuidString: id) != nil else {
                self = .main
                return
            }
            self = .credential(id)
        default:
            self = .main
        }
    }

    var userInfo: [AnyHashable: Any] {
        switch self {
        case .main: return [:]
        case .pendingRequests: return ["route": "pendingRequests"]
        case .credential(let id): return ["route": "credential", "credentialID": id]
        case .softwareUpdate: return ["route": "softwareUpdate"]
        }
    }
}
