import Foundation
import CryptoKit
import AskKeyCore

final class AppPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? Self.runtimeDefaults
    }

    private static var runtimeDefaults: UserDefaults {
#if DEBUG
        if let directory = VaultConfiguration.debugRunDirectory {
            let namespace = SHA256.hash(data: Data(directory.path.utf8))
                .map { String(format: "%02x", $0) }.joined()
            guard let defaults = UserDefaults(suiteName: "com.sudohg.askkey.debug." + namespace) else {
                preconditionFailure("Isolated Debug preferences are unavailable")
            }
            return defaults
        }
#endif
        return .standard
    }

    var sessionTimeoutSeconds: Double {
        get {
            let value = defaults.double(forKey: "sessionTimeoutSeconds")
            return value > 0 ? value : 300
        }
        set {
            defaults.set(newValue, forKey: "sessionTimeoutSeconds")
        }
    }

    var clipboardClearSeconds: Double { 60 }

    var appearanceMode: String {
        get {
            defaults.string(forKey: "appearanceMode") ?? "system"
        }
        set {
            defaults.set(newValue, forKey: "appearanceMode")
        }
    }

    var languageMode: String {
        get { defaults.string(forKey: "languageMode") ?? "system" }
        set {
            defaults.set(newValue, forKey: "languageMode")
        }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: "hasCompletedOnboarding") }
        set { defaults.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    var defaultTimedAllowanceMinutes: Int {
        get {
            let value = defaults.integer(forKey: "defaultTimedAllowanceMinutes")
            return value > 0 ? value : 30
        }
        set {
            defaults.set(newValue, forKey: "defaultTimedAllowanceMinutes")
        }
    }

    var readApprovalAuthenticationEnabled: Bool {
        get { defaults.object(forKey: "readApprovalAuthenticationEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "readApprovalAuthenticationEnabled") }
    }

    var timedAllowanceEnabled: Bool {
        get { defaults.object(forKey: "timedAllowanceEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "timedAllowanceEnabled") }
    }

    var hotkeyShortcutID: String {
        get {
            defaults.string(forKey: "hotkeyShortcutID") ?? "cmdShiftSpace"
        }
        set {
            defaults.set(newValue, forKey: "hotkeyShortcutID")
            NotificationCenter.default.post(name: .hotkeyShortcutChanged, object: newValue)
        }
    }

    var recentSecretNames: [String] {
        get {
            defaults.stringArray(forKey: "recentSecretNames") ?? []
        }
        set {
            defaults.set(newValue, forKey: "recentSecretNames")
        }
    }
}
