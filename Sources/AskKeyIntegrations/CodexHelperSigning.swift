import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

public struct CodexHelperSigning: Sendable {
    public var isTrusted: @Sendable (URL) -> Bool

    public init(_ isTrusted: @escaping @Sendable (URL) -> Bool) {
        self.isTrusted = isTrusted
    }

    public static let executable = CodexHelperSigning { url in
        guard FileManager.default.isExecutableFile(atPath: url.path), !isSymlink(url) else {
            return false
        }
        guard let host = Bundle.main.executableURL else { return false }
        return HelperCodeSignatureTrust.matchesHost(helper: url, host: host)
    }

    public static let development = CodexHelperSigning { url in
        FileManager.default.isExecutableFile(atPath: url.path) && !isSymlink(url)
    }
}
func isSymlink(_ url: URL) -> Bool {
    var st = stat()
    guard url.path.withCString({ lstat($0, &st) }) == 0 else { return false }
    return (st.st_mode & S_IFMT) == S_IFLNK
}
