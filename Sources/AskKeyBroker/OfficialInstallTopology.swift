import Foundation

public enum OfficialInstallDecision: Equatable, Sendable {
    case accepted(helperURL: URL)
    case developmentAccepted(helperURL: URL)
    case relocatedOrRenamed
    case helperMismatch
}

public enum OfficialInstallTopologyError: Error, Equatable, LocalizedError {
    case unavailable(OfficialInstallDecision)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let decision):
            return OfficialInstallTopology.nextStep(for: decision)
        }
    }
}

public enum OfficialInstallTopology {
    public static let canonicalAppPath = "/Applications/Ask Key.app"
    public static let helperRelativePath = "Contents/Helpers/askkey"
    public static let canonicalHelperPath = canonicalAppPath + "/" + helperRelativePath
    public static let productionBundleIdentifier = "com.sudohg.askkey.app"
    public static let developmentBundleIdentifier = "com.sudohg.askkey.app.dev"

    public static func decide(
        bundleURL: URL,
        helperURL: URL? = nil,
        isDevelopmentBuild: Bool,
        resolvedURL: (URL) -> URL = { $0.resolvingSymlinksInPath() }
    ) -> OfficialInstallDecision {
        let bundlePath = normalizedPath(bundleURL)
        let expectedHelperPath = normalizedPath(
            URL(fileURLWithPath: bundlePath, isDirectory: true)
                .appendingPathComponent(helperRelativePath)
        )
        let helperPath = normalizedPath(helperURL ?? URL(fileURLWithPath: expectedHelperPath))
        let helper = URL(fileURLWithPath: helperPath)
        if helperPath != expectedHelperPath {
            return .helperMismatch
        }
        if isDevelopmentBuild {
            return .developmentAccepted(helperURL: helper)
        }
        let canonicalPath = normalizedPath(
            URL(fileURLWithPath: canonicalAppPath, isDirectory: true)
        )
        let resolvedBundlePath = normalizedPath(resolvedURL(bundleURL))
        if bundlePath != canonicalPath
            || resolvedBundlePath != canonicalPath
            || URL(fileURLWithPath: bundlePath, isDirectory: true).lastPathComponent != "Ask Key.app" {
            return .relocatedOrRenamed
        }
        return .accepted(helperURL: helper)
    }

    public static func allowsOfficialRuntime(_ decision: OfficialInstallDecision) -> Bool {
        switch decision {
        case .accepted, .developmentAccepted:
            return true
        case .relocatedOrRenamed, .helperMismatch:
            return false
        }
    }

    public static func nextStep(for decision: OfficialInstallDecision) -> String {
        switch decision {
        case .accepted, .developmentAccepted:
            return ""
        case .relocatedOrRenamed:
            return "Ask Key must stay at /Applications/Ask Key.app. Reinstall the official package, then open that copy."
        case .helperMismatch:
            return "This Ask Key helper does not match the official app. Reinstall the official package, then try again."
        }
    }

    public static func resolvedHelperURL(
        bundleURL: URL,
        helperURL: URL? = nil,
        isDevelopmentBuild: Bool,
        resolvedURL: (URL) -> URL = { $0.resolvingSymlinksInPath() }
    ) throws -> URL {
        let decision = decide(
            bundleURL: bundleURL,
            helperURL: helperURL,
            isDevelopmentBuild: isDevelopmentBuild,
            resolvedURL: resolvedURL
        )
        switch decision {
        case .accepted(let url), .developmentAccepted(let url):
            return url
        case .relocatedOrRenamed, .helperMismatch:
            throw OfficialInstallTopologyError.unavailable(decision)
        }
    }

    private static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        if path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
