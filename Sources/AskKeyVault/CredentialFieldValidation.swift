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

}
