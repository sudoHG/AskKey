import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

public enum HelperCodeSignatureTrust {
    public static func matchesHost(helper: URL, host: URL) -> Bool {
        guard host.isFileURL, helper.isFileURL,
              host == host.standardizedFileURL,
              helper == helper.standardizedFileURL else { return false }
        let bundleURL = host.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        // Only the real host bundle's fixed helper is eligible, never PATH or aliases.
        guard host == host.resolvingSymlinksInPath(),
              helper == helper.resolvingSymlinksInPath(),
              bundleURL.pathExtension == "app",
              host.deletingLastPathComponent() == bundleURL.appendingPathComponent("Contents/MacOS"),
              helper == bundleURL.appendingPathComponent("Contents/Helpers/askkey"),
              Bundle(url: bundleURL)?.executableURL?.standardizedFileURL == host,
              (try? helper.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isExecutableFile(atPath: helper.path),
              let hostInfo = validSigningInformation(at: bundleURL),
              let helperInfo = validSigningInformation(at: helper) else { return false }
        let hostTeam = hostInfo[kSecCodeInfoTeamIdentifier as String] as? String
        let helperTeam = helperInfo[kSecCodeInfoTeamIdentifier as String] as? String
        if let hostTeam, !hostTeam.isEmpty {
            return helperTeam == hostTeam
        }
        // No Team ID is not itself trust. Both signatures must be explicitly ad-hoc,
        // and validating the entire host bundle above binds the helper to its seal.
        guard helperTeam == nil || helperTeam?.isEmpty == true,
              let hostFlags = hostInfo[kSecCodeInfoFlags as String] as? NSNumber,
              let helperFlags = helperInfo[kSecCodeInfoFlags as String] as? NSNumber else { return false }
        return hostFlags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0
            && helperFlags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0
    }

    private static func validSigningInformation(at url: URL) -> [String: Any]? {
        var code: SecStaticCode?
        let validation = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, validation, nil) == errSecSuccess else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
              let values = information as? [String: Any] else { return nil }
        return values
    }
}
