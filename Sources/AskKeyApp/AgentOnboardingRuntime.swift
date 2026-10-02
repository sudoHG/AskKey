import Foundation
import AskKeyCore

enum AgentOnboardingRuntime {
    static func liveOperations(
        connector: AgentClientConnector = AgentClientConnector(),
        authenticate: @escaping @MainActor @Sendable () async -> AgentAuthenticationOutcome,
        revalidateWriteSession: @escaping @MainActor @Sendable () async -> Bool = { true }
    ) -> AgentOnboardingOperations {
        boundOperations(
            runCheck: { try connector.check($0) },
            runApply: { try connector.apply($0, plan: $1) },
            authenticate: authenticate,
            revalidateWriteSession: revalidateWriteSession
        )
    }

    static func boundOperations(
        runCheck: @escaping @Sendable (AgentClient) throws -> AgentCheckReport,
        runApply: @escaping @Sendable (AgentClient, AgentOnboardingPlan) throws -> AgentApplyReport,
        authenticate: @escaping @MainActor @Sendable () async -> AgentAuthenticationOutcome,
        revalidateWriteSession: @escaping @MainActor @Sendable () async -> Bool = { true }
    ) -> AgentOnboardingOperations {
        AgentOnboardingOperations(
            check: { client, cancellation in
                try await Task.detached {
                    try RestrictedProcessCancellation.withValue({ cancellation.isCancelled }) {
                        try withBoundaryActive {
                            if cancellation.isCancelled { throw AgentOnboardingFailure.cancelled }
                            do {
                                return try runCheck(client)
                            } catch {
                                throw mappedCheckError(error, cancelled: cancellation.isCancelled)
                            }
                        }
                    }
                }.value
            },
            apply: { client, plan, cancellation in
                try await Task.detached {
                    try RestrictedProcessCancellation.withValue({ cancellation.isCancelled }) {
                        try withBoundaryActive {
                            if cancellation.isCancelled { throw AgentOnboardingFailure.cancelled }
                            return try runApply(client, plan)
                        }
                    }
                }.value
            },
            authenticate: authenticate,
            revalidateWriteSession: revalidateWriteSession
        )
    }

    private static func withBoundaryActive<T>(_ body: () throws -> T) rethrows -> T {
#if DEBUG
        try OnboardingBoundaryObserver.$active.withValue(true) {
            try body()
        }
#else
        try body()
#endif
    }

    private static func mappedCheckError(_ error: Error, cancelled: Bool) -> Error {
        if cancelled { return AgentOnboardingFailure.cancelled }
        return error
    }

}

extension AgentClientConnector {
    func check(_ client: AgentClient) throws -> AgentCheckReport {
        try throwIfCheckCancelled()
        let report: AgentCheckReport
        switch client {
        case .codex:
            report = try checkCodex()
        case .cursor:
            report = try checkCursor()
        case .grok:
            report = try checkGrok()
        }
        try throwIfCheckCancelled()
        return report
    }

    private func throwIfCheckCancelled() throws {
        if RestrictedProcessCancellation.current?() == true {
            throw AgentOnboardingFailure.cancelled
        }
    }

    func apply(_ client: AgentClient, plan: AgentOnboardingPlan) throws -> AgentApplyReport {
        if !plan.verifiesOnly, !plan.configurationPresent, try hasAskKeyConfiguration(client) {
            throw AgentOnboardingFailure.planChanged
        }
        if plan.verifiesOnly {
            let report = try check(client)
            return AgentApplyReport(
                outcome: report.outcome,
                changeStatus: .notWritten,
                failure: report.failure ?? (report.outcome == .verifiedConnected
                    ? nil : .verificationFailed),
                targetSummary: report.targetSummary,
                discovery: report.discovery
            )
        }
        switch client {
        case .codex:
            return try applyCodex(plan: plan)
        case .cursor:
            return try applyCursor(plan: plan)
        case .grok:
            return try applyGrok(plan: plan)
        }
    }

    private func hasAskKeyConfiguration(_ client: AgentClient) throws -> Bool {
        switch client {
        case .codex:
            return try codexAdapter().hasConfiguration()
        case .cursor:
            return try cursorAdapter().hasConfiguration()
        case .grok:
            return try grokAdapter().hasConfiguration()
        }
    }

    private func checkCodex() throws -> AgentCheckReport {
        try CodexOnboardingSetup.check(
            mcp: codexAdapter(useNativeConfiguration: true),
            hook: codexDiscoveryConfiguration(),
            native: codexNativeHooks(),
            plan: localPlan(for: .codex)
        )
    }

    private func checkCursor() throws -> AgentCheckReport {
        let adapter = try cursorAdapter()
        let context = try commandDiscoveryContext(for: .cursor)
        return try CommandHookOnboardingSetup.check(
            client: .cursor,
            hook: context.hook,
            plan: localPlan(for: .cursor),
            verifyHelper: context.verifyHelper,
            hasMCPConfiguration: { try adapter.hasConfiguration() },
            isMCPConnected: { try adapter.status().connected },
            previewMCP: { _ = try adapter.preview() }
        )
    }

    private func checkGrok() throws -> AgentCheckReport {
        let adapter = try grokAdapter()
        let context = try commandDiscoveryContext(for: .grok)
        return try CommandHookOnboardingSetup.check(
            client: .grok,
            hook: context.hook,
            plan: localPlan(for: .grok),
            verifyHelper: context.verifyHelper,
            hasMCPConfiguration: { try adapter.hasConfiguration() },
            isMCPConnected: { try adapter.status().connected },
            previewMCP: { _ = try adapter.preview() }
        )
    }

    private func applyCodex(plan: AgentOnboardingPlan) throws -> AgentApplyReport {
        try Self.performExclusive(client: .codex) {
            do {
                return try CodexOnboardingSetup.apply(
                    mcp: codexAdapter(useNativeConfiguration: true),
                    hook: codexDiscoveryConfiguration(),
                    native: codexNativeHooks(), plan: plan
                )
            } catch let error as CodexUserMCPError {
                return applyFailure(error, plan: plan)
            }
        }
    }

    private func applyCursor(plan: AgentOnboardingPlan) throws -> AgentApplyReport {
        try Self.performExclusive(client: .cursor) {
            do {
                let adapter = try cursorAdapter()
                let context = try commandDiscoveryContext(for: .cursor)
                return try CommandHookOnboardingSetup.apply(
                    client: .cursor,
                    hook: context.hook,
                    plan: plan,
                    verifyHelper: context.verifyHelper,
                    hasMCPConfiguration: { try adapter.hasConfiguration() },
                    isMCPConnected: { try adapter.status().connected },
                    applyMCP: { _ = try adapter.apply() },
                    rollbackMCP: { try adapter.rollback() }
                )
            } catch let error as CursorMCPError {
                return applyFailure(error, plan: plan)
            }
        }
    }

    private func applyGrok(plan: AgentOnboardingPlan) throws -> AgentApplyReport {
        try Self.performExclusive(client: .grok) {
            do {
                let adapter = try grokAdapter()
                let context = try commandDiscoveryContext(for: .grok)
                return try CommandHookOnboardingSetup.apply(
                    client: .grok,
                    hook: context.hook,
                    plan: plan,
                    verifyHelper: context.verifyHelper,
                    hasMCPConfiguration: { try adapter.hasConfiguration() },
                    isMCPConnected: { try adapter.status().connected },
                    applyMCP: { _ = try adapter.connect() }
                )
            } catch let error as GrokCLIAdapterError {
                return applyFailure(error, plan: plan)
            }
        }
    }

    private func applyFailure(_ error: Error, plan: AgentOnboardingPlan) -> AgentApplyReport {
        let failure = AgentOnboardingFailure.from(error)
        let change: AgentChangeStatus
        switch failure {
        case .restoreFailed: change = .restoreFailed
        default: change = failure == .verificationFailed ? .restored : .notWritten
        }
        return AgentApplyReport(
            outcome: .notConfigured,
            changeStatus: change,
            failure: failure,
            targetSummary: plan.targetIdentity
        )
    }

    private func localPlan(for client: AgentClient) -> AgentOnboardingPlan {
        AgentOnboardingPlan(
            client: client,
            createdAt: Date(),
            targetIdentity: client.rawValue,
            scopeSummary: appLocalizedFormat(
                "Add Ask Key for the current user of %@. Other connections stay as they are. A backup is created first.",
                client.rawValue
            ),
            configurationPresent: false,
            verifiesOnly: false,
            preconditionSummary: appLocalized("If verification fails, Ask Key restores the original settings.")
        )
    }
}
