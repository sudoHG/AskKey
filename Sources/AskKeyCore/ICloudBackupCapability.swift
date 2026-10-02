import Foundation
import Security

public struct ICloudSigningMetadata: Equatable, Sendable {
    public var teamIdentifier: String?
    public var identityKind: ICloudSigningIdentityKind
    public var codesignEntitlementContainers: [String]
    public var isFixture: Bool

    public init(
        teamIdentifier: String?,
        identityKind: ICloudSigningIdentityKind,
        codesignEntitlementContainers: [String],
        isFixture: Bool
    ) {
        self.teamIdentifier = teamIdentifier
        self.identityKind = identityKind
        self.codesignEntitlementContainers = codesignEntitlementContainers
        self.isFixture = isFixture
    }
}

public enum ICloudSigningIdentityKind: String, Equatable, Sendable {
    case developerID
    case adHoc
    case unknown
}

public struct ICloudBackupCapabilityRequest: Equatable, Sendable {
    public var bundleIdentifier: String
    public var infoPlistContainerIdentifier: String?
    public var entitlementContainerIdentifiers: [String]
    public var signing: ICloudSigningMetadata

    public init(
        bundleIdentifier: String,
        infoPlistContainerIdentifier: String?,
        entitlementContainerIdentifiers: [String],
        signing: ICloudSigningMetadata
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.infoPlistContainerIdentifier = infoPlistContainerIdentifier
        self.entitlementContainerIdentifiers = entitlementContainerIdentifiers
        self.signing = signing
    }
}

public enum ICloudBackupCapabilityDecision: Equatable, Sendable {
    case ready(containerIdentifier: String)
    case developmentUnavailable
    case releaseMaterialsMissing
    case forbiddenContainer
    case fixtureUnproven
}

public enum ICloudBackupCapabilityInspection {
    public static let productionBundleIdentifier = "com.sudohg.askkey.app"

    public static func classifySigningIdentity(
        teamIdentifier: String?,
        certificateSummaries: [String]
    ) -> ICloudSigningIdentityKind {
        let team = teamIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if team.isEmpty {
            return .adHoc
        }
        let hasDeveloperID = certificateSummaries.contains { summary in
            summary.hasPrefix("Developer ID Application:")
        }
        return hasDeveloperID ? .developerID : .unknown
    }

    public static func validateReleaseContainerIdentifier(_ identifier: String) throws {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ICloudBackupError.capabilityUnavailable
        }
        guard trimmed.range(of: #"^iCloud\.[A-Za-z0-9][A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else {
            throw ICloudBackupError.capabilityUnavailable
        }
        guard !trimmed.lowercased().contains("lokalite") else {
            throw ICloudBackupError.capabilityUnavailable
        }
    }

    public static func decide(_ request: ICloudBackupCapabilityRequest) -> ICloudBackupCapabilityDecision {
        let containers = collectedContainers(request)
        if containers.contains(where: { $0.lowercased().contains("lokalite") }) {
            return .forbiddenContainer
        }
        if request.signing.isFixture {
            return materialsPresent(request) ? .fixtureUnproven : .developmentUnavailable
        }
        if request.signing.identityKind == .adHoc || request.signing.identityKind == .unknown {
            return .developmentUnavailable
        }
        if request.bundleIdentifier == productionBundleIdentifier, !materialsPresent(request) {
            return .releaseMaterialsMissing
        }
        if !materialsPresent(request) {
            return .developmentUnavailable
        }
        guard let identifier = request.infoPlistContainerIdentifier,
              identifier == request.entitlementContainerIdentifiers.first,
              identifier == request.signing.codesignEntitlementContainers.first,
              request.signing.identityKind == .developerID,
              request.signing.teamIdentifier?.isEmpty == false else {
            return request.bundleIdentifier == productionBundleIdentifier
                ? .releaseMaterialsMissing
                : .developmentUnavailable
        }
        do {
            try validateReleaseContainerIdentifier(identifier)
        } catch {
            return .forbiddenContainer
        }
        return .ready(containerIdentifier: identifier)
    }

    public static func nextStep(for decision: ICloudBackupCapabilityDecision) -> String {
        switch decision {
        case .ready:
            return ""
        case .developmentUnavailable:
            return "Use an official Ask Key release that includes Ask Key's own iCloud container, entitlement, and Developer ID signing."
        case .releaseMaterialsMissing:
            return "Refuse this release. Inject Ask Key's own iCloud container identifier, entitlement, and matching signed metadata before packaging."
        case .forbiddenContainer:
            return "Refuse this identifier. Ask Key must use its own iCloud container, never a Lokalite or invented production ID."
        case .fixtureUnproven:
            return "Fixture signing metadata cannot prove production iCloud capability."
        }
    }

    public static func liveRequest(bundle: Bundle = .main) -> ICloudBackupCapabilityRequest {
        let info = bundle.object(forInfoDictionaryKey: "AskKeyICloudContainerIdentifier") as? String
        let signing = liveSigningMetadata()
        return ICloudBackupCapabilityRequest(
            bundleIdentifier: bundle.bundleIdentifier ?? "",
            infoPlistContainerIdentifier: info?.isEmpty == true ? nil : info,
            entitlementContainerIdentifiers: signing.codesignEntitlementContainers,
            signing: signing
        )
    }

    private static func collectedContainers(_ request: ICloudBackupCapabilityRequest) -> [String] {
        var values = request.entitlementContainerIdentifiers + request.signing.codesignEntitlementContainers
        if let info = request.infoPlistContainerIdentifier {
            values.append(info)
        }
        return values
    }

    private static func materialsPresent(_ request: ICloudBackupCapabilityRequest) -> Bool {
        guard let identifier = request.infoPlistContainerIdentifier, !identifier.isEmpty else {
            return false
        }
        return request.entitlementContainerIdentifiers.contains(identifier)
            && request.signing.codesignEntitlementContainers.contains(identifier)
    }

    private static func liveSigningMetadata() -> ICloudSigningMetadata {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            return ICloudSigningMetadata(
                teamIdentifier: nil,
                identityKind: .unknown,
                codesignEntitlementContainers: [],
                isFixture: false
            )
        }
        var information: CFDictionary?
        let copyStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard copyStatus == errSecSuccess, let information = information as? [String: Any] else {
            return ICloudSigningMetadata(
                teamIdentifier: nil,
                identityKind: .unknown,
                codesignEntitlementContainers: [],
                isFixture: false
            )
        }
        let team = information[kSecCodeInfoTeamIdentifier as String] as? String
        let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let containers = entitlementContainers(from: entitlements)
        let summaries = certificateSummaries(from: information)
        return ICloudSigningMetadata(
            teamIdentifier: team,
            identityKind: classifySigningIdentity(
                teamIdentifier: team,
                certificateSummaries: summaries
            ),
            codesignEntitlementContainers: containers,
            isFixture: false
        )
    }

    private static func certificateSummaries(from information: [String: Any]) -> [String] {
        guard let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate] else {
            return []
        }
        return certificates.compactMap { certificate in
            SecCertificateCopySubjectSummary(certificate) as String?
        }
    }

    private static func entitlementContainers(from entitlements: [String: Any]?) -> [String] {
        guard let entitlements else { return [] }
        let keys = [
            "com.apple.developer.icloud-container-identifiers",
            "com.apple.developer.ubiquity-container-identifiers",
        ]
        return keys.flatMap { key in
            entitlements[key] as? [String] ?? []
        }
    }
}
