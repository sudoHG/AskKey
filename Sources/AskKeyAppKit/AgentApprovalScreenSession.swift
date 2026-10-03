import CoreGraphics
import Foundation
import Darwin

/// Normalize the WindowServer session before the privacy gate. The optional
/// lock flag is present when locked; absence alone is never enough to allow UI.
/// A logged-in console session belonging to this process is also required.
enum AgentApprovalScreenSession {
    static func current() -> AgentApprovalScreenState {
        resolve(session: CGSessionCopyCurrentDictionary() as? [String: Any], userID: getuid())
    }

    static func resolve(session: [String: Any]?, userID: uid_t) -> AgentApprovalScreenState {
        guard let session,
              let onConsole = session[kCGSessionOnConsoleKey] as? NSNumber,
              let loggedIn = session[kCGSessionLoginDoneKey] as? NSNumber,
              let owner = session[kCGSessionUserIDKey] as? NSNumber else { return .unknown }
        guard onConsole.boolValue, owner.uint32Value == userID else { return .locked }
        guard loggedIn.boolValue else { return .unknown }
        if let flag = session["CGSSessionScreenIsLocked"] {
            guard let locked = flag as? NSNumber else { return .unknown }
            return locked.boolValue ? .locked : .unlocked
        }
        return .unlocked
    }
}
