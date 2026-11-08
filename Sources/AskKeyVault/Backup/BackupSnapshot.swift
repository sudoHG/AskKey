import Foundation
import AskKeyBroker

/// Why a backup that opened with its recovery key was still refused.
public enum BackupContentsIssue: Error, Equatable, Sendable {
    /// The document does not have the documented structure.
    case malformedDocument
    /// A credential or component has a payload kind this reader does not know.
    case unknownPayloadKind
    /// Two credentials have the same name after normalization.
    case duplicateCredentialName
    /// A credential fails the validation that normal creation applies.
    case invalidCredential
    /// A credential has more than 64 components or more than 5 MiB of material.
    case limitExceeded
    /// A group name is invalid or repeated, or a credential names an unlisted group.
    case invalidGroup
}

/// What a backup contains, independent of the SQLite schema (ADR 0012). The
/// whole library is held in memory: values in the clear, none of the
/// library's ciphertext, record tags or App key.
struct BackupSnapshot: Equatable {
    struct Credential: Equatable {
        var name: String
        var payloadKind: CredentialPayloadKind
        var components: [CredentialComponentInput]
        var usageInstructions: String
        var privateNotes: String
        var groupName: String?
        var permission: CredentialPermission
        var expiresAt: Date?
        var createdAt: Date
        var updatedAt: Date
        var deletedAt: Date?
    }

    var createdAt: Date
    var appVersion: String
    /// Every group, including empty ones and those only recycled credentials name.
    var groups: [String]
    /// Every credential, active or in the Recycle Bin, including Hidden ones.
    var credentials: [Credential]

    var summary: BackupSummary {
        let recycled = credentials.filter { $0.deletedAt != nil }.count
        return BackupSummary(createdAt: createdAt, credentialCount: credentials.count - recycled,
                             recycledCount: recycled, groupCount: groups.count)
    }

    /// Applies the creation validators to the whole snapshot. Every value must
    /// already be in the canonical form creation would store, so a snapshot an
    /// export writes always passes and anything else is refused.
    func validate() throws {
        guard appVersion.utf8.count <= BrokerLimits.maximumFieldBytes else {
            throw BackupContentsIssue.malformedDocument
        }
        var groupNames = Set<String>()
        for group in groups {
            guard (try? CredentialName.displayName(from: group)) == group,
                  groupNames.insert(group).inserted else { throw BackupContentsIssue.invalidGroup }
        }
        var credentialNames = Set<String>()
        for credential in credentials {
            try credential.validate(groups: groupNames)
            guard credentialNames.insert(CredentialName.normalized(credential.name)).inserted else {
                throw BackupContentsIssue.duplicateCredentialName
            }
        }
    }
}

extension BackupSnapshot.Credential {
    fileprivate func validate(groups: Set<String>) throws {
        guard (try? CredentialName.displayName(from: name)) == name else {
            throw BackupContentsIssue.invalidCredential
        }
        try checkLimits()
        guard let validated = try? CredentialBundleValidator.validatedComponents(components),
              validated == components else { throw BackupContentsIssue.invalidCredential }
        try checkPayloadShape()
        guard (try? CredentialFieldValidation.usageInstructions(usageInstructions)) != nil else {
            throw BackupContentsIssue.invalidCredential
        }
        if let groupName, !groups.contains(groupName) { throw BackupContentsIssue.invalidGroup }
    }

    private func checkLimits() throws {
        guard !components.isEmpty else { throw BackupContentsIssue.invalidCredential }
        guard components.count <= CredentialBundleValidator.maximumComponents else {
            throw BackupContentsIssue.limitExceeded
        }
        var materialBytes = 0
        for component in components {
            switch component.value {
            case .text(let text): materialBytes += text.utf8.count
            case .file(_, let bytes): materialBytes += bytes.count
            }
            guard materialBytes <= CredentialBundleValidator.maximumMaterialBytes else {
                throw BackupContentsIssue.limitExceeded
            }
        }
    }

    /// Text and file credentials hold one component, shaped exactly as
    /// `Vault.credentialComponents(from:key:)` derives it from a stored record.
    private func checkPayloadShape() throws {
        guard payloadKind != .bundle else { return }
        guard components.count == 1, let component = components.first, component.masked else {
            throw BackupContentsIssue.invalidCredential
        }
        let mapping: String?
        switch (payloadKind, component.value, component.delivery) {
        case (.text, .text, .environmentVariable(let name)), (.file, .file, .temporaryFile(let name)):
            mapping = name
        case (.text, .text, .none), (.file, .file, .none):
            mapping = nil
        default:
            throw BackupContentsIssue.invalidCredential
        }
        let fallback = payloadKind == .text ? "VALUE" : "FILE"
        let expectedName = mapping.flatMap { try? CredentialName.displayName(from: $0) } ?? fallback
        guard component.name == expectedName else { throw BackupContentsIssue.invalidCredential }
    }
}
