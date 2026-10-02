import Foundation
#if canImport(Security)
import Security
#endif

public struct HelperHostSigningFacts: Equatable, Sendable {
    public var teamIdentifier: String?
    public var certificateSummaries: [String]
    public var flags: UInt32
    public var isValid: Bool
    public var meetsAppleDeveloperIDRequirement: Bool

    public init(
        teamIdentifier: String? = nil,
        certificateSummaries: [String] = [],
        flags: UInt32 = 0,
        isValid: Bool = false,
        meetsAppleDeveloperIDRequirement: Bool = false
    ) {
        self.teamIdentifier = teamIdentifier
        self.certificateSummaries = certificateSummaries
        self.flags = flags
        self.isValid = isValid
        self.meetsAppleDeveloperIDRequirement = meetsAppleDeveloperIDRequirement
    }
}

public enum HelperHostSignatureKind: Equatable, Sendable {
    case developerID
    case adHoc
    case unknown
    case unsigned
}

public enum HelperHostSignatureTrust {
    /// Apple Developer ID Application under Apple's generic anchor.
    /// OIDs: 1.2.840.113635.100.6.2.6 (Developer ID CA) and
    /// 1.2.840.113635.100.6.1.13 (Developer ID Application).
    public static let appleDeveloperIDRequirementText =
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    public static func classify(_ facts: HelperHostSigningFacts) -> HelperHostSignatureKind {
        guard facts.isValid else { return .unsigned }
        let team = facts.teamIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let adhoc = facts.flags & adHocFlag != 0
        if team.isEmpty {
            return adhoc ? .adHoc : .unsigned
        }
        return facts.meetsAppleDeveloperIDRequirement ? .developerID : .unknown
    }

    public static func allows(
        helper: HelperHostSigningFacts,
        host: HelperHostSigningFacts,
        isDevelopmentBuild: Bool
    ) -> Bool {
        let helperKind = classify(helper)
        let hostKind = classify(host)
        if helperKind == .developerID, hostKind == .developerID {
            let helperTeam = helper.teamIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hostTeam = host.teamIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !helperTeam.isEmpty && helperTeam == hostTeam
        }
        guard isDevelopmentBuild else { return false }
        return helperKind == .adHoc && hostKind == .adHoc
    }

    public static var appleDeveloperIDRequirementIsAvailable: Bool {
#if canImport(Security)
        HelperHostApplication.appleDeveloperIDRequirement() != nil
#else
        false
#endif
    }

    public static let adHocFlag: UInt32 = {
#if canImport(Security)
        SecCodeSignatureFlags.adhoc.rawValue
#else
        2
#endif
    }()
}

public enum HelperHostApplicationError: Error, LocalizedError {
    case unavailable
    case failed
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable, .failed:
            return "Ask Key could not open the host application."
        case .rejected(let message):
            return message
        }
    }
}

/// Resolves the host `.app` that sealed this helper, then opens it only after
/// the install-topology, identity, and signature gates pass.
public enum HelperHostApplication {
    public static func bundleURL(fromHelperExecutable url: URL) -> URL? {
        structuralBundleURL(from: url.standardizedFileURL.resolvingSymlinksInPath())
    }

    public static func openableBundleURL(fromHelperExecutable url: URL) -> URL? {
        guard let bundle = bundleURL(fromHelperExecutable: url),
              bundleIdentifier(ofHost: bundle) != nil else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bundle.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return bundle
    }

    public static func openHost(
        helperURL: URL,
        isDevelopmentBuild: Bool,
        opener: ((URL) throws -> Void)? = nil,
        signingFacts: ((URL) -> HelperHostSigningFacts)? = nil,
        bundleIdentifier: ((URL) -> String?)? = nil,
        resolvedURL: ((URL) -> URL)? = nil
    ) throws {
        let opener = opener ?? { try open($0) }
        let signingFacts = signingFacts ?? Self.signingFacts(at:)
        let bundleIdentifier = bundleIdentifier ?? Self.bundleIdentifier(ofHost:)
        let resolvedURL = resolvedURL ?? { $0.resolvingSymlinksInPath() }

        guard let bundle = structuralBundleURL(from: helperURL.standardizedFileURL) else {
            throw HelperHostApplicationError.unavailable
        }

        let decision = OfficialInstallTopology.decide(
            bundleURL: bundle,
            helperURL: helperURL,
            isDevelopmentBuild: isDevelopmentBuild,
            resolvedURL: resolvedURL
        )
        guard OfficialInstallTopology.allowsOfficialRuntime(decision) else {
            throw HelperHostApplicationError.rejected(OfficialInstallTopology.nextStep(for: decision))
        }

        let expectedIdentifier = isDevelopmentBuild
            ? OfficialInstallTopology.developmentBundleIdentifier
            : OfficialInstallTopology.productionBundleIdentifier
        guard bundleIdentifier(bundle) == expectedIdentifier else {
            throw HelperHostApplicationError.rejected(
                OfficialInstallTopology.nextStep(for: .helperMismatch)
            )
        }
        guard HelperHostSignatureTrust.allows(
            helper: signingFacts(helperURL),
            host: signingFacts(bundle),
            isDevelopmentBuild: isDevelopmentBuild
        ) else {
            throw HelperHostApplicationError.rejected(
                OfficialInstallTopology.nextStep(for: .helperMismatch)
            )
        }
        try opener(bundle)
    }

    private static func open(_ bundleURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [bundleURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw HelperHostApplicationError.failed }
    }

    public static func bundleIdentifier(ofHost bundleURL: URL) -> String? {
        let info = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              !identifier.isEmpty
        else {
            return nil
        }
        return identifier
    }

    public static func signingFacts(at url: URL) -> HelperHostSigningFacts {
#if canImport(Security)
        var code: SecStaticCode?
        let validation = SecCSFlags(rawValue: kSecCSStrictValidate)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, validation, nil) == errSecSuccess else {
            return HelperHostSigningFacts(isValid: false)
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess else {
            return HelperHostSigningFacts(isValid: false)
        }
        let info = information as? [String: Any] ?? [:]
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let summaries: [String]
        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] {
            summaries = certificates.compactMap { SecCertificateCopySubjectSummary($0) as String? }
        } else {
            summaries = []
        }
        return HelperHostSigningFacts(
            teamIdentifier: team,
            certificateSummaries: summaries,
            flags: flags,
            isValid: true,
            meetsAppleDeveloperIDRequirement: meetsAppleDeveloperIDRequirement(code, flags: validation)
        )
#else
        return HelperHostSigningFacts(isValid: false)
#endif
    }

    private static func structuralBundleURL(from helper: URL) -> URL? {
        let helpers = helper.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers" else { return nil }
        let contents = helpers.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return nil }
        let bundle = contents.deletingLastPathComponent()
        guard bundle.pathExtension == "app" else { return nil }
        return bundle
    }

#if canImport(Security)
    public static func appleDeveloperIDRequirement() -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            HelperHostSignatureTrust.appleDeveloperIDRequirementText as CFString,
            [],
            &requirement
        ) == errSecSuccess else {
            return nil
        }
        return requirement
    }

    private static func meetsAppleDeveloperIDRequirement(
        _ code: SecStaticCode,
        flags: SecCSFlags
    ) -> Bool {
        guard let requirement = appleDeveloperIDRequirement() else { return false }
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
#endif
}
