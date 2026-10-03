import AppKit
import CoreServices

enum AppLaunchSource: Equatable {
    case active
    case loginItem

    init(event: NSAppleEventDescriptor?) {
        guard event?.eventID == AEEventID(kAEOpenApplication),
              event?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil else {
            self = .active
            return
        }
        self = .loginItem
    }
}
