import Foundation
import AskKeyIntegrations
import AskKeySystem

/// Product setup includes both the MCP connection and native discovery hook.
/// Hook availability is guidance readiness; it never grants credential access.
enum CodexOnboardingSetup {
    static var reviewedHookDescription: String {
        appLocalized("Before the first direct SSH command in each turn, ask Codex to check the credential catalog. Credential access still requires its existing approval. If this check is unavailable or takes over three seconds, Codex may continue without it.")
    }

    static func readiness(_ state: CodexNativeHookStatus) -> CredentialDiscoveryReadiness {
        switch state {
        case .enabled: return .enabled
        case .missing: return .missing
        case .disabled: return .disabled
        case .untrusted: return .untrusted
        case .unsupported: return .unavailable
        }
    }

    static func check(
        mcp: CodexUserMCPAdapter,
        hook: CodexDiscoveryHookConfiguration,
        native: CodexNativeHookClient,
        plan: AgentOnboardingPlan
    ) throws -> AgentCheckReport {
        let present = try mcp.hasConfiguration()
        let connected = present && mcp.status() == .connected
        // No CLI whitelist guess: native capability and user configuration
        // authority must be confirmed before offering a write.
        let state: CodexNativeHookStatus
        do {
            state = try native.status()
        } catch {
            if RestrictedProcessCancellation.current?() == true { throw AgentOnboardingFailure.cancelled }
            return AgentCheckReport(
                outcome: connected ? .configuredUnverified : (present ? .existingConfigUnverified : .notConfigured),
                targetSummary: "Codex", plan: nil, failure: .from(error),
                discovery: .unavailable
            )
        }
        if connected && state == .enabled {
            return AgentCheckReport(outcome: .verifiedConnected, targetSummary: "Codex", plan: nil,
                                    failure: nil, discovery: .enabled)
        }
        guard state != .unsupported else {
            return AgentCheckReport(outcome: connected ? .configuredUnverified : .notConfigured,
                                    targetSummary: "Codex", plan: nil, failure: .unsupportedVersion,
                                    discovery: .unavailable)
        }
        // An existing but unhealthy MCP configuration is not overwritten by
        // discovery repair. Its helper/Broker problem must be fixed first.
        if present && !connected {
            return AgentCheckReport(outcome: .existingConfigUnverified, targetSummary: "Codex", plan: nil,
                                    failure: .verificationFailed, discovery: readiness(state))
        }
        if !present { _ = try mcp.preview() }
        var proposed = plan
        proposed.configurationPresent = present
        proposed.codexHookPlan = try hook.preview()
        proposed.scopeSummary = appLocalized("Connect Ask Key to Codex and enable credential discovery before SSH. Only this Ask Key hook will be trusted.")
        proposed.preconditionSummary = appLocalized("Each configuration file is backed up before changes. A verified MCP connection is kept if hook setup needs another check. Start a new Codex task after setup.")
        return AgentCheckReport(outcome: connected ? .configuredUnverified : .notConfigured,
                                targetSummary: "Codex", plan: proposed, failure: nil,
                                discovery: readiness(state))
    }

    static func apply(
        mcp: CodexUserMCPAdapter,
        hook: CodexDiscoveryHookConfiguration,
        native: CodexNativeHookClient,
        plan: AgentOnboardingPlan
    ) throws -> AgentApplyReport {
        guard let frozen = plan.codexHookPlan,
              try hook.preview() == frozen,
              try mcp.hasConfiguration() == plan.configurationPresent else {
            throw AgentOnboardingFailure.planChanged
        }
        guard try native.status() != .unsupported else { throw AgentOnboardingFailure.unsupportedVersion }
        if plan.configurationPresent {
            guard mcp.status() == .connected else { throw AgentOnboardingFailure.verificationFailed }
        } else {
            _ = try mcp.apply()
        }
        do {
            try hook.apply(plan: frozen)
            try native.enableReviewedHook(backupDirectory: mcp.backupDirectory.deletingLastPathComponent()
                .appendingPathComponent("codex-trust"))
            guard try native.status() == .enabled, mcp.status() == .connected else {
                throw AgentOnboardingFailure.discoverySetupFailed
            }
            return AgentApplyReport(outcome: .verifiedConnected, changeStatus: .verifiedAndKept,
                                    failure: nil, targetSummary: "Codex", discovery: .enabled)
        } catch {
            // Native writes can succeed before a lost response. Do not undo
            // whole config files or silently repeat an uncertain trust write.
            if let fileError = error as? CodexDiscoveryHookConfigurationError,
               fileError == .rollbackFailed || fileError == .restoreConflict {
                return AgentApplyReport(outcome: .configuredUnverified, changeStatus: .restoreFailed,
                                        failure: .restoreFailed, targetSummary: "Codex",
                                        discovery: .unavailable)
            }
            let cancelled = (error as? CodexNativeHookClientError) == .cancelled
            return AgentApplyReport(outcome: .configuredUnverified, changeStatus: .verifiedAndKept,
                                    failure: cancelled ? .discoverySetupCancelled : .discoverySetupFailed,
                                    targetSummary: "Codex",
                                    discovery: .unavailable)
        }
    }
}
