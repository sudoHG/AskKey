import Foundation
import AskKeyBroker

/// Errors raised before a credential field can be encrypted or written.
///
/// The field names are deliberately fixed strings. They are safe to surface
/// in the UI and do not include the rejected value.
public enum CredentialFieldValidationError: Error, Equatable, LocalizedError, Sendable {
    case usageInstructionsTooLong
    case environmentVariableTooLong

    public var localizationKey: String {
        switch self {
        case .usageInstructionsTooLong:
            return "credential.field.usageInstructionsTooLong"
        case .environmentVariableTooLong:
            return "credential.field.environmentVariableTooLong"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .usageInstructionsTooLong:
            return "Usage instructions must be at most \(BrokerLimits.maximumFieldBytes) bytes."
        case .environmentVariableTooLong:
            return "Environment variable mappings must be at most \(BrokerLimits.maximumFieldBytes) bytes."
        }
    }
}

enum CredentialFieldValidation {
    static func usageInstructions(_ value: String) throws {
        guard value.utf8.count <= BrokerLimits.maximumFieldBytes else {
            throw CredentialFieldValidationError.usageInstructionsTooLong
        }
    }

    static func environmentVariable(_ value: String) throws {
        guard value.utf8.count <= BrokerLimits.maximumFieldBytes else {
            throw CredentialFieldValidationError.environmentVariableTooLong
        }
        try Vault.validateSecretName(value)
    }

    static func optionalEnvironmentVariable(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        try environmentVariable(trimmed)
        return trimmed
    }

    static func backupDeletionDate(from timestamp: String) -> Date? {
        // Historical imports may retain an ISO 8601 offset rather than UTC Z.
        // Require a complete, bounded timestamp; Foundation also accepts prefixes
        // and normalizes some impossible calendar dates.
        guard (20...25).contains(timestamp.utf8.count),
              timestamp.range(
                of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([Zz]|[+-][0-9]{2}(:?[0-9]{2})?)\z"#,
                options: .regularExpression
              ) != nil,
              let date = sharedDateFormatter.date(from: timestamp) else { return nil }
        let zone = timestamp.dropFirst(19)
        var offsetSeconds = 0
        if zone.uppercased() != "Z" {
            let digits = zone.dropFirst().filter { $0 != ":" }
            guard let hours = Int(digits.prefix(2)),
                  let minutes = Int(digits.count == 2 ? "00" : String(digits.suffix(2))),
                  hours < 24, minutes < 60 else { return nil }
            offsetSeconds = (hours * 3_600 + minutes * 60) * (zone.first == "-" ? -1 : 1)
        }
        let localDate = date.addingTimeInterval(TimeInterval(offsetSeconds))
        guard sharedDateFormatter.string(from: localDate).prefix(19) == timestamp.prefix(19) else { return nil }
        return date
    }

    static func backupCredential(_ credential: ICloudBackupCredential) throws {
        _ = try CredentialName.displayName(from: credential.displayName)
        try usageInstructions(credential.usageInstructions)
        if let mapping = credential.environmentVariable {
            try environmentVariable(mapping)
        }
        if let deletedAt = credential.deletedAt {
            let seconds = deletedAt.timeIntervalSince1970
            // The database stores whole seconds with a four-digit ISO 8601 year.
            // Bound the date before passing untrusted values to the formatter.
            guard seconds.isFinite,
                  seconds >= -62_135_596_800, seconds < 253_402_300_800 else {
                throw ICloudBackupError.invalidSnapshot
            }
            let timestamp = sharedDateFormatter.string(from: deletedAt)
            guard timestamp.utf8.count == 20,
                  sharedDateFormatter.date(from: timestamp) == deletedAt else {
                throw ICloudBackupError.invalidSnapshot
            }
        }
        if case .bundle(let bytes) = credential.payload {
            let components = try JSONDecoder().decode([CredentialComponentInput].self, from: bytes)
            _ = try CredentialBundleValidator.validatedComponents(components)
        }
    }
}
