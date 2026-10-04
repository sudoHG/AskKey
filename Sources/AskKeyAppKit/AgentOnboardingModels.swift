import Foundation
import AskKeyIntegrations

enum AgentOnboardingPhase: String, Equatable, Sendable {
    case idle
    case explanation
    case checking
    case readyToConfirm
    case completed
    case needsAction
    case authenticating
    case applying
    case verifying
    case rolledBack
    case recoveryRequired

    var isReadonlyInFlight: Bool { self == .checking }
    var isWriteInFlight: Bool {
        self == .authenticating || self == .applying || self == .verifying
    }
    var isInFlight: Bool { isReadonlyInFlight || isWriteInFlight }
}

enum AgentChangeStatus: String, Equatable, Sendable {
    case notWritten
    case verifiedAndKept
    case restored
    case restoreFailed
}

package enum AgentKnownOutcome: String, Equatable, Sendable {
    case notConfigured
    case configuredUnverified
    case verifiedConnected
    case existingConfigUnverified
}

struct AgentLastKnownResult: Equatable, Sendable {
    var outcome: AgentKnownOutcome
    var checkedAt: Date
    var targetSummary: String
    var discovery: CredentialDiscoveryReadiness? = nil
}

package enum CredentialDiscoveryReadiness: Equatable, Sendable {
    case enabled, configured, missing, disabled, untrusted, unavailable
}

package enum AgentOnboardingFailure: Error, Equatable, Sendable {
    case cancelled
    case permissionDenied
    case unsupportedVersion
    case nameConflict
    case unsafeConfig
    case illegalConfig
    case helperMismatch
    case brokerUnavailable
    case verificationFailed
    case restoreFailed
    case cliMissing
    case timedOut
    case communicationFailed
    case planChanged
    case discoverySetupFailed
    case discoverySetupCancelled
}

package enum AgentAuthenticationOutcome: Equatable, Sendable {
    case confirmed
    case cancelled
    case failed
}

final class AgentCheckCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }
}

package struct AgentOnboardingPlan: Equatable, Sendable {
    var client: AgentClient
    var createdAt: Date
    var targetIdentity: String
    var scopeSummary: String
    var configurationPresent: Bool
    var verifiesOnly: Bool
    var preconditionSummary: String
    var codexHookPlan: CodexDiscoveryHookPlan? = nil
    var commandHookPlan: CommandDiscoveryHookPlan? = nil
}

package struct AgentCheckReport: Equatable, Sendable {
    var outcome: AgentKnownOutcome
    var targetSummary: String
    var plan: AgentOnboardingPlan?
    var failure: AgentOnboardingFailure?
    var discovery: CredentialDiscoveryReadiness? = nil

    package init(outcome: AgentKnownOutcome, targetSummary: String,
                 plan: AgentOnboardingPlan?, failure: AgentOnboardingFailure?,
                 discovery: CredentialDiscoveryReadiness? = nil) {
        self.outcome = outcome
        self.targetSummary = targetSummary
        self.plan = plan
        self.failure = failure
        self.discovery = discovery
    }
}

package struct AgentApplyReport: Equatable, Sendable {
    var outcome: AgentKnownOutcome
    var changeStatus: AgentChangeStatus
    var failure: AgentOnboardingFailure?
    var targetSummary: String
    var discovery: CredentialDiscoveryReadiness? = nil
}

struct AgentOnboardingAttempt: Equatable, Sendable {
    var phase: AgentOnboardingPhase
    var failure: AgentOnboardingFailure?
    var changeStatus: AgentChangeStatus
    var message: String

    static let idle = AgentOnboardingAttempt(
        phase: .idle,
        failure: nil,
        changeStatus: .notWritten,
        message: ""
    )
}

struct AgentClientOnboardingSession: Equatable, Sendable {
    var lastKnownResult: AgentLastKnownResult?
    var attempt: AgentOnboardingAttempt
    var operationID: UUID?
    var plan: AgentOnboardingPlan?

    static let idle = AgentClientOnboardingSession(
        lastKnownResult: nil,
        attempt: .idle,
        operationID: nil,
        plan: nil
    )
}

package struct AgentOnboardingOperations: Sendable {
    var check: @Sendable (AgentClient, AgentCheckCancellation) async throws -> AgentCheckReport
    var apply: @Sendable (AgentClient, AgentOnboardingPlan, AgentCheckCancellation) async throws -> AgentApplyReport
    var authenticate: @MainActor @Sendable () async -> AgentAuthenticationOutcome
    var revalidateWriteSession: @MainActor @Sendable () async -> Bool

    init(
        check: @escaping @Sendable (AgentClient, AgentCheckCancellation) async throws -> AgentCheckReport,
        apply: @escaping @Sendable (AgentClient, AgentOnboardingPlan, AgentCheckCancellation) async throws -> AgentApplyReport,
        authenticate: @escaping @MainActor @Sendable () async -> AgentAuthenticationOutcome,
        revalidateWriteSession: @escaping @MainActor @Sendable () async -> Bool = { true }
    ) {
        self.check = check
        self.apply = apply
        self.authenticate = authenticate
        self.revalidateWriteSession = revalidateWriteSession
    }

    static let inactive = AgentOnboardingOperations(
        check: { _, _ in
            AgentCheckReport(outcome: .notConfigured, targetSummary: "", plan: nil, failure: nil)
        },
        apply: { _, _, _ in
            AgentApplyReport(
                outcome: .notConfigured,
                changeStatus: .notWritten,
                failure: .cancelled,
                targetSummary: ""
            )
        },
        authenticate: { .cancelled }
    )
}

extension AgentOnboardingFailure {
    static func from(_ error: Error) -> AgentOnboardingFailure {
        if let failure = error as? AgentOnboardingFailure { return failure }
        if let error = error as? ClaudeCodeMCPError {
            switch error {
            case .missingExecutable: return .cliMissing
            case .unsupportedVersion, .unsupportedCLI: return .unsupportedVersion
            case .unreadableConfiguration: return .illegalConfig
            case .conflictingEntry, .conflictingScope: return .nameConflict
            case .configurationChanged: return .planChanged
            case .rollbackFailed: return .restoreFailed
            case .cancelled: return .cancelled
            case .timeout: return .timedOut
            case .outputTooLarge, .processFailed: return .communicationFailed
            case .addFailed: return .verificationFailed
            case .verificationFailed(let reason):
                if reason.hasPrefix("helper_") { return .helperMismatch }
                if reason.hasPrefix("broker_") { return .brokerUnavailable }
                return .verificationFailed
            }
        }
        if let error = error as? CodexNativeHookClientError {
            switch error {
            case .cliMissing: return .cliMissing
            case .userHomeMismatch, .unsafeConfiguration: return .unsafeConfig
            case .unsupported: return .unsupportedVersion
            case .configurationChanged: return .planChanged
            case .verificationFailed: return .verificationFailed
            case .writeOutcomeUnknown: return .discoverySetupFailed
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            case .invalidResponse, .communicationFailed: return .communicationFailed
            }
        }
        if let error = error as? CodexDiscoveryHookConfigurationError {
            switch error {
            case .unsafeHooksFile, .unsafeBackupDirectory: return .unsafeConfig
            case .invalidHooksFile, .fileTooLarge: return .illegalConfig
            case .multipleExpectedHooks, .customHookMismatch: return .nameConflict
            case .concurrentModification: return .planChanged
            case .rollbackFailed, .restoreConflict: return .restoreFailed
            case .backupFailed, .writeFailed: return .verificationFailed
            }
        }
        if let error = error as? CodexUserMCPError {
            switch error {
            case .unsafeConfigFile: return .unsafeConfig
            case .illegalConfig: return .illegalConfig
            case .unknownCodexVersion: return .unsupportedVersion
            case .rollbackFailed: return .restoreFailed
            case .connectionFailed(let reason):
                if reason == "helper" || reason == "version" { return .helperMismatch }
                if reason == "broker" { return .brokerUnavailable }
                return .verificationFailed
            }
        }
        if let error = error as? CommandDiscoveryIntegrationError {
            switch error {
            case .helperUnsupported: return .helperMismatch
            }
        }
        if let error = error as? CommandDiscoveryHookConfigurationError {
            switch error {
            case .unsafeHooksFile, .unsafeBackupDirectory: return .unsafeConfig
            case .invalidHooksFile, .invalidExpectedHooks, .fileTooLarge: return .illegalConfig
            case .multipleExpectedHooks, .customHookMismatch, .ownedFileConflict: return .nameConflict
            case .concurrentModification: return .planChanged
            case .rollbackFailed: return .restoreFailed
            case .backupFailed, .writeFailed: return .verificationFailed
            }
        }
        if let error = error as? CursorMCPError {
            switch error {
            case .unsafeFile: return .unsafeConfig
            case .invalidJSON: return .illegalConfig
            case .rollbackFailed: return .restoreFailed
            case .replaceFailed, .readbackFailed, .backupCleanupFailed: return .verificationFailed
            }
        }
        if let error = error as? GrokCLIAdapterError {
            switch error {
            case .unsafeConfig: return .unsafeConfig
            case .invalidConfig: return .illegalConfig
            case .unsupportedClient: return .unsupportedVersion
            case .rollbackFailed: return .restoreFailed
            case .verificationFailed(let reason):
                if reason.contains("helper") { return .helperMismatch }
                if reason.contains("broker") { return .brokerUnavailable }
                return .verificationFailed
            case .backupCleanupFailed, .diagnosticsCleanupFailed: return .verificationFailed
            }
        }
        return .verificationFailed
    }
}
