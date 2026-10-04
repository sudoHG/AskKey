import Foundation
import AskKeyIntegrations
import AskKeySystem

struct CommandDiscoverySetupContext {
    let client: CommandDiscoveryClient
    let helper: URL
    let hook: CommandDiscoveryHookConfiguration
    let verifyHelper: () throws -> Void
}

/// Product setup for the command-hook discovery integrations used by Cursor,
/// Claude Code and Grok. The command hook is independent from MCP: a healthy
/// existing connection is kept while discovery is repaired, and an unhealthy existing
/// MCP configuration is never overwritten by this flow.
enum CommandHookOnboardingSetup {
    static var reviewedHookDescription: String {
        appLocalized("Before the first direct SSH connection in a turn, ask the agent to check the credential catalog. Credential access still needs approval. If the catalog is unavailable or its callback is lost, the reminder stops blocking after 30 seconds without progress.")
    }

    typealias VerifyHelper = () throws -> Void
    typealias HasMCPConfiguration = () throws -> Bool
    typealias IsMCPConnected = () throws -> Bool
    typealias PreviewMCP = () throws -> Void
    typealias ApplyMCP = () throws -> Void
    typealias RollbackMCP = () throws -> Void

    static func readiness(for plan: CommandDiscoveryHookPlan) -> CredentialDiscoveryReadiness {
        plan.changed ? .missing : .configured
    }

    static func check(
        client: AgentClient,
        hook: CommandDiscoveryHookConfiguration,
        plan: AgentOnboardingPlan,
        verifyHelper: @escaping VerifyHelper,
        hasMCPConfiguration: @escaping HasMCPConfiguration,
        isMCPConnected: @escaping IsMCPConnected,
        previewMCP: @escaping PreviewMCP
    ) throws -> AgentCheckReport {
        let configurationPresent: Bool
        do {
            configurationPresent = try hasMCPConfiguration()
        } catch {
            return try checkFailure(client: client, outcome: .notConfigured, error: error)
        }

        do {
            try verifyHelper()
        } catch {
            return try checkFailure(
                client: client,
                outcome: configurationPresent ? .existingConfigUnverified : .notConfigured,
                error: error
            )
        }

        let connected: Bool
        do {
            connected = configurationPresent ? try isMCPConnected() : false
        } catch {
            return try checkFailure(
                client: client,
                outcome: configurationPresent ? .existingConfigUnverified : .notConfigured,
                error: error
            )
        }

        let hookPlan: CommandDiscoveryHookPlan
        do {
            hookPlan = try hook.preview()
        } catch {
            return try checkFailure(
                client: client,
                outcome: connected ? .configuredUnverified
                    : (configurationPresent ? .existingConfigUnverified : .notConfigured),
                error: error
            )
        }
        let discovery = readiness(for: hookPlan)

        // A broken existing MCP setup is a separate repair problem. Do not
        // offer a plan that would write either the MCP or command-hook file.
        if configurationPresent && !connected {
            return AgentCheckReport(
                outcome: .existingConfigUnverified,
                targetSummary: client.rawValue,
                plan: nil,
                failure: .verificationFailed,
                discovery: discovery
            )
        }

        if !configurationPresent {
            do {
                try previewMCP()
            } catch {
                return try checkFailure(
                    client: client,
                    outcome: .notConfigured,
                    error: error,
                    discovery: discovery
                )
            }
        }

        if connected && !hookPlan.changed {
            return AgentCheckReport(
                outcome: .verifiedConnected,
                targetSummary: client.rawValue,
                plan: nil,
                failure: nil,
                discovery: .configured
            )
        }

        var proposed = plan
        proposed.configurationPresent = configurationPresent
        proposed.commandHookPlan = hookPlan
        proposed.scopeSummary = appLocalizedFormat(
            "Connect Ask Key to %@ and configure credential discovery before SSH.", client.rawValue
        )
        proposed.preconditionSummary = appLocalized("Configuration files are backed up before changes. If discovery setup fails, the verified MCP connection is kept. Start a new task after setup.")
        return AgentCheckReport(
            outcome: connected ? .configuredUnverified : .notConfigured,
            targetSummary: client.rawValue,
            plan: proposed,
            failure: nil,
            discovery: discovery
        )
    }

    static func apply(
        client: AgentClient,
        hook: CommandDiscoveryHookConfiguration,
        plan: AgentOnboardingPlan,
        verifyHelper: @escaping VerifyHelper,
        hasMCPConfiguration: @escaping HasMCPConfiguration,
        isMCPConnected: @escaping IsMCPConnected,
        applyMCP: @escaping ApplyMCP,
        rollbackMCP: @escaping RollbackMCP = {},
        applyVerifiesMCP: Bool = false
    ) throws -> AgentApplyReport {
        guard let frozen = plan.commandHookPlan else {
            throw AgentOnboardingFailure.planChanged
        }

        // Capability is checked at the write boundary too. A helper can be
        // replaced between review and confirmation, so the reviewed plan is
        // never enough on its own.
        do {
            try verifyHelper()
        } catch {
            return try applyFailure(
                client: client,
                error: error,
                changeStatus: .notWritten,
                discovery: .unavailable,
                outcome: plan.configurationPresent ? .existingConfigUnverified : .notConfigured
            )
        }

        let currentHookPlan: CommandDiscoveryHookPlan
        do {
            currentHookPlan = try hook.preview()
        } catch {
            return try applyFailure(
                client: client,
                error: error,
                changeStatus: .notWritten,
                discovery: .unavailable,
                outcome: plan.configurationPresent ? .existingConfigUnverified : .notConfigured
            )
        }
        guard currentHookPlan == frozen else {
            return AgentApplyReport(
                outcome: plan.configurationPresent ? .existingConfigUnverified : .notConfigured,
                changeStatus: .notWritten,
                failure: .planChanged,
                targetSummary: client.rawValue,
                discovery: .unavailable
            )
        }

        let configurationPresent: Bool
        do {
            configurationPresent = try hasMCPConfiguration()
        } catch {
            return try applyFailure(
                client: client,
                error: error,
                changeStatus: .notWritten,
                discovery: .unavailable,
                outcome: plan.configurationPresent ? .existingConfigUnverified : .notConfigured
            )
        }
        guard configurationPresent == plan.configurationPresent else {
            return AgentApplyReport(
                outcome: plan.configurationPresent ? .existingConfigUnverified : .notConfigured,
                changeStatus: .notWritten,
                failure: .planChanged,
                targetSummary: client.rawValue,
                discovery: .unavailable
            )
        }

        if plan.configurationPresent {
            do {
                guard try isMCPConnected() else {
                    throw AgentOnboardingFailure.verificationFailed
                }
            } catch {
                return try applyFailure(
                    client: client,
                    error: error,
                    changeStatus: .notWritten,
                    discovery: readiness(for: frozen),
                    outcome: .existingConfigUnverified
                )
            }
        } else {
            try applyMCP()
            do {
                // CLI adapters can own verification and rollback as one
                // transaction. Do not run a second check outside that rollback.
                if !applyVerifiesMCP, try !isMCPConnected() {
                    throw AgentOnboardingFailure.verificationFailed
                }
            } catch {
                do {
                    try rollbackMCP()
                } catch {
                    return AgentApplyReport(
                        outcome: .notConfigured,
                        changeStatus: .restoreFailed,
                        failure: .restoreFailed,
                        targetSummary: client.rawValue,
                        discovery: .unavailable
                    )
                }
                if RestrictedProcessCancellation.current?() == true {
                    throw AgentOnboardingFailure.cancelled
                }
                return AgentApplyReport(
                    outcome: .notConfigured,
                    changeStatus: .restored,
                    failure: .from(error),
                    targetSummary: client.rawValue,
                    discovery: .unavailable
                )
            }
        }

        do {
            try hook.apply(plan: frozen)
            let hookIsPresent = try hook.hasExpectedHook()
            guard hookIsPresent else {
                throw AgentOnboardingFailure.discoverySetupFailed
            }
            let mcpConnectedAfterHook: Bool
            do {
                mcpConnectedAfterHook = try isMCPConnected()
            } catch {
                if RestrictedProcessCancellation.current?() == true {
                    return AgentApplyReport(
                        outcome: .configuredUnverified,
                        changeStatus: .verifiedAndKept,
                        failure: .discoverySetupCancelled,
                        targetSummary: client.rawValue,
                        discovery: .unavailable
                    )
                }
                return AgentApplyReport(
                    outcome: .configuredUnverified,
                    changeStatus: .verifiedAndKept,
                    failure: .verificationFailed,
                    targetSummary: client.rawValue,
                    discovery: .configured
                )
            }
            guard mcpConnectedAfterHook else {
                return AgentApplyReport(
                    outcome: .configuredUnverified,
                    changeStatus: .verifiedAndKept,
                    failure: .verificationFailed,
                    targetSummary: client.rawValue,
                    discovery: .configured
                )
            }
            return AgentApplyReport(
                outcome: .verifiedConnected,
                changeStatus: .verifiedAndKept,
                failure: nil,
                targetSummary: client.rawValue,
                discovery: .configured
            )
        } catch {
            if RestrictedProcessCancellation.current?() == true
                || (error as? AgentOnboardingFailure) == .cancelled {
                return AgentApplyReport(
                    outcome: .configuredUnverified,
                    changeStatus: .verifiedAndKept,
                    failure: .discoverySetupCancelled,
                    targetSummary: client.rawValue,
                    discovery: .unavailable
                )
            }
            if let fileError = error as? CommandDiscoveryHookConfigurationError,
               fileError == .rollbackFailed {
                return AgentApplyReport(
                    outcome: .configuredUnverified,
                    changeStatus: .restoreFailed,
                    failure: .restoreFailed,
                    targetSummary: client.rawValue,
                    discovery: .unavailable
                )
            }
            return AgentApplyReport(
                outcome: .configuredUnverified,
                changeStatus: .verifiedAndKept,
                failure: .discoverySetupFailed,
                targetSummary: client.rawValue,
                discovery: .unavailable
            )
        }
    }
}

private extension CommandHookOnboardingSetup {
    static func applyFailure(
        client: AgentClient,
        error: Error,
        changeStatus: AgentChangeStatus,
        discovery: CredentialDiscoveryReadiness?,
        outcome: AgentKnownOutcome
    ) throws -> AgentApplyReport {
        if RestrictedProcessCancellation.current?() == true {
            throw AgentOnboardingFailure.cancelled
        }
        return AgentApplyReport(
            outcome: outcome,
            changeStatus: changeStatus,
            failure: .from(error),
            targetSummary: client.rawValue,
            discovery: discovery
        )
    }

    static func checkFailure(
        client: AgentClient,
        outcome: AgentKnownOutcome,
        error: Error,
        discovery: CredentialDiscoveryReadiness = .unavailable
    ) throws -> AgentCheckReport {
        if RestrictedProcessCancellation.current?() == true {
            throw AgentOnboardingFailure.cancelled
        }
        return AgentCheckReport(
            outcome: outcome,
            targetSummary: client.rawValue,
            plan: nil,
            failure: .from(error),
            discovery: discovery
        )
    }
}
