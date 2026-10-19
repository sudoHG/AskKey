import Foundation
import AskKeySystem
import Security

enum KeychainQuery {
    static var systemKeychainAllowed: Bool {
        RuntimeOperationEvents.publish(.keychain)
        #if DEBUG
        if ProcessInfo.processInfo.environment["ASKKEY_DEBUG_RUN_DIRECTORY"] != nil { return false }
        #endif
        return !(ProcessInfo.processInfo.arguments.first?.contains(".xctest") ?? false)
            && NSClassFromString("XCTestCase") == nil
    }

    static func forbidAuthenticationUI(_ query: [String: Any]) -> [String: Any] {
        var query = query
        // This deprecated flag still forbids interactive Keychain prompts.
        // User presence is enforced at the App layer with LocalAuthentication.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return query
    }
}
