import Foundation
import Security

enum AppKeychainAccess {
    static func make(application: URL) throws -> SecAccess {
        let trusted = try trustedApplication(application)
        var access: SecAccess?
        let status = SecAccessCreate("Ask Key App-only vault key" as CFString, [trusted] as CFArray, &access)
        guard status == errSecSuccess, let access else { throw AppKeyStoreError.securityFailure(status) }
        return access
    }

    private static func trustedApplication(_ url: URL) throws -> SecTrustedApplication {
        var application: SecTrustedApplication?
        let status = url.path.withCString { SecTrustedApplicationCreateFromPath($0, &application) }
        guard status == errSecSuccess, let application else { throw AppKeyStoreError.securityFailure(status) }
        return application
    }
}
