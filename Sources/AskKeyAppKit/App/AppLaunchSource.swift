import AppKit
import AskKeyBroker
import CoreServices
import os

/// Who started this process. A login launch and an `askkey open` launch keep
/// Ask Key in the menu bar; every other launch is one the person asked for.
enum AppLaunchSource: Equatable {
    case active
    case loginItem
    case helper

    /// Read the open-application event inside `applicationDidFinishLaunching`:
    /// it is not current yet in `applicationWillFinishLaunching` and is gone a
    /// run-loop turn later. `loginItemEnabled` is asked only when the launch
    /// carried no event at all.
    init(
        event: NSAppleEventDescriptor?,
        arguments: [String] = [],
        loginItemEnabled: () -> Bool = { false }
    ) {
        if Self.isLoginItemLaunch(event) || (event == nil && loginItemEnabled()) {
            self = .loginItem
        } else if arguments.dropFirst().contains(HelperHostApplication.backgroundLaunchArgument) {
            self = .helper
        } else {
            self = .active
        }
    }

    /// loginwindow sends `kAEOpenApplication` whose `keyAEPropData` parameter
    /// is the enumerated code `keyAELaunchedAsLogInItem`. Finder, the Dock,
    /// Spotlight, Launchpad and `open` send the same event without it. A
    /// parameter keyed by that code is accepted too, matching the header text.
    static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        if event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem) {
            return true
        }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
    }
}

extension AppLaunchSource {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "AskKeyAppKit",
        category: "Launch"
    )

    var logName: String {
        switch self {
        case .active: "active"
        case .loginItem: "loginItem"
        case .helper: "helper"
        }
    }

    /// The event's class, ID and parameter keywords. The only value included
    /// is `keyAEPropData`, reduced to `lgit`, `svit`, `other` or `none`.
    static func eventSummary(_ event: NSAppleEventDescriptor?) -> String {
        guard let event else { return "none" }
        var keys: [String] = []
        if event.numberOfItems > 0 {
            for index in 1...event.numberOfItems {
                keys.append(fourCharacterCode(event.keywordForDescriptor(at: index)))
            }
        }
        let propData: String
        switch event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue {
        case nil: propData = "none"
        case OSType(keyAELaunchedAsLogInItem): propData = "lgit"
        case OSType(keyAELaunchedAsServiceItem): propData = "svit"
        default: propData = "other"
        }
        let name = "\(fourCharacterCode(event.eventClass))/\(fourCharacterCode(event.eventID))"
        return "\(name) keys=[\(keys.joined(separator: ","))] propData=\(propData)"
    }

    func log(event: NSAppleEventDescriptor?) {
        let summary = Self.eventSummary(event)
        Self.logger.notice(
            "launch source=\(logName, privacy: .public) event=\(summary, privacy: .public)"
        )
    }

    private static func fourCharacterCode(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else {
            return String(format: "0x%08X", code)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
