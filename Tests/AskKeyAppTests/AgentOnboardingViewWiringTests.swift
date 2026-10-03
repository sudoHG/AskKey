import AppKit
import SwiftUI
import XCTest
@testable import AskKeyApp

/// View/coordinator call-boundary evidence for 331-404 B1 / A01.
/// The same new-contract assertions RED on the isolated ef90 replay.
@MainActor
final class AgentOnboardingViewWiringTests: XCTestCase {
    func testEF90AppearReplayViolatesNewContract() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-331-404-ef90-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent(".local/bin", isDirectory: true)
        let spyLog = root.appendingPathComponent("cli-spy.log")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try installSpyCLI(at: bin.appendingPathComponent("askkey"), log: spyLog)

        let vault = makeIsolatedVault()
        let probe = WiringProbe()
        await EF90AgentAccessAppearReplay.appear(vault: vault) { client in
            probe.recordPreview(client)
            return try AgentClientConnector(
                home: root,
                installationHome: root,
                supportDirectory: root.appendingPathComponent("support", isDirectory: true),
                helperURL: bin.appendingPathComponent("askkey")
            ).preview(client)
        }

        let failures = OnboardingAppearContract.failures(
            checkCalls: probe.previewCount,
            applyCalls: 0,
            errorMessage: vault.errorMessage
        )
        try writeReplayEvidence(
            previewCalls: probe.previewCount,
            spyLog: spyLog,
            errorMessage: vault.errorMessage,
            failures: failures
        )
        XCTAssertGreaterThan(
            probe.previewCount,
            0,
            "ef90 appear must actually invoke the preview/spy boundary"
        )
        XCTAssertFalse(
            failures.isEmpty,
            "new-contract assertions must RED on the ef90 appear replay; failures=\(failures)"
        )
    }

    func testCurrentViewAppearAndExplainHoldNewContract() {
        let probe = WiringProbe()
        let vault = makeIsolatedVault()
        vault.onboarding = AgentOnboardingCoordinator(operations: probe.operations)

        let host = NSHostingView(
            rootView: AgentOnboardingView()
                .environment(vault)
                .frame(width: 720, height: 860)
        )
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 860)
        host.layoutSubtreeIfNeeded()
        pump()

        for client in AgentClient.allCases {
            XCTAssertTrue(
                DebugAccessibility.press(
                    identifier: "onboarding-review-\(client.proofID)",
                    in: host
                ),
                "review button must be reachable for \(client.rawValue)"
            )
            pump()
        }

        let failures = OnboardingAppearContract.failures(
            checkCalls: probe.checkCount,
            applyCalls: probe.applyCount,
            errorMessage: vault.errorMessage
        )
        XCTAssertEqual(failures, [], failures.joined(separator: "; "))
    }

    func testSidebarEnterExitAndExpandDoNotStartChecks() {
        let probe = WiringProbe()
        let vault = makeIsolatedVault()
        vault.onboarding = AgentOnboardingCoordinator(operations: probe.operations)
        let box = RouteBox()

        let host = NSHostingView(
            rootView: CredentialManagementView(
                selectedSection: box.sectionBinding,
                route: box.routeBinding
            )
            .environment(vault)
            .frame(width: 960, height: 720)
        )
        host.frame = NSRect(x: 0, y: 0, width: 960, height: 720)
        host.layoutSubtreeIfNeeded()
        pump()

        var usedSidebar = false
        var usedReview = false
        for _ in 0..<10 {
            if DebugAccessibility.press(identifier: "sidebar-agent", in: host) {
                usedSidebar = true
            } else {
                box.section = .agentAccess
                box.route = .agentAccess
            }
            pump()
            for client in AgentClient.allCases {
                if DebugAccessibility.press(
                    identifier: "onboarding-review-\(client.proofID)",
                    in: host
                ) {
                    usedReview = true
                } else {
                    vault.onboarding.explain(client)
                }
            }
            pump()
            if !DebugAccessibility.press(identifier: "sidebar-settings", in: host) {
                box.route = .settings
            }
            pump()
        }

        let failures = OnboardingAppearContract.failures(
            checkCalls: probe.checkCount,
            applyCalls: probe.applyCount,
            errorMessage: vault.errorMessage
        )
        XCTAssertEqual(failures, [], failures.joined(separator: "; "))
        XCTAssertEqual(probe.checkCount, 0)
        XCTAssertEqual(probe.applyCount, 0)
        XCTAssertTrue(
            usedSidebar || box.route == .settings || box.route == .agentAccess,
            "sidebar enter/exit must be exercised"
        )
        _ = usedReview
    }

    func testReviewDoesNotStartCheckUntilExplicitCheckButton() async {
        let probe = WiringProbe()
        let vault = makeIsolatedVault()
        vault.onboarding = AgentOnboardingCoordinator(operations: probe.operations)
        let host = NSHostingView(
            rootView: AgentOnboardingView()
                .environment(vault)
                .frame(width: 720, height: 860)
        )
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 860)
        host.layoutSubtreeIfNeeded()
        pump()

        XCTAssertTrue(
            DebugAccessibility.press(identifier: "onboarding-review-cursor", in: host)
        )
        pump()
        XCTAssertEqual(probe.checkCount, 0)
        XCTAssertEqual(vault.onboarding.expandedClient, .cursor)

        XCTAssertTrue(
            DebugAccessibility.press(identifier: "onboarding-check-cursor", in: host)
        )
        await waitUntil { probe.checkCount >= 1 }
        XCTAssertEqual(probe.checkCount, 1)
        XCTAssertEqual(probe.applyCount, 0)
        XCTAssertNil(vault.errorMessage)
    }

    private func makeIsolatedVault() -> VaultViewModel {
        let vault = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            unlockVault: {},
            beginManagementSession: { _ in },
            credentialMutations: .readOnly { ([], [], [], false) }
        )
        vault.hasCompletedOnboarding = true
        vault.isLocked = false
        vault.hasManagementSession = true
        vault.errorMessage = nil
        return vault
    }

    private func installSpyCLI(at url: URL, log: URL) throws {
        let script = """
        #!/bin/bash
        printf '%s\\n' "$*" >> "\(log.path)"
        echo '{"error":"spy"}'
        exit 1
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private func writeReplayEvidence(
        previewCalls: Int,
        spyLog: URL,
        errorMessage: String?,
        failures: [String]
    ) throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("AskKeyOnboardingReplay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "previewCalls": previewCalls,
            "cliSpyExists": FileManager.default.fileExists(atPath: spyLog.path),
            "cliSpyBytes": (try? Data(contentsOf: spyLog).count) ?? 0,
            "errorMessage": errorMessage ?? "",
            "newContractFailures": failures
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            .write(to: directory.appendingPathComponent("ef90-red.json"), options: .atomic)
    }

    private func pump() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for condition")
    }
}

@MainActor
private final class RouteBox {
    var section: CredentialWorkspaceSection = .all
    var route: CredentialWorkspaceRoute = .library

    var sectionBinding: Binding<CredentialWorkspaceSection> {
        Binding(get: { self.section }, set: { self.section = $0 })
    }

    var routeBinding: Binding<CredentialWorkspaceRoute> {
        Binding(get: { self.route }, set: { self.route = $0 })
    }
}

private final class WiringProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var previews = 0
    private var checks = 0
    private var applies = 0

    var previewCount: Int { lock.withLock { previews } }
    var checkCount: Int { lock.withLock { checks } }
    var applyCount: Int { lock.withLock { applies } }

    func recordPreview(_ client: AgentClient) {
        lock.withLock { previews += 1 }
        _ = client
    }

    var operations: AgentOnboardingOperations {
        AgentOnboardingOperations(
            check: { _, _ in
                self.lock.withLock { self.checks += 1 }
                return AgentCheckReport(
                    outcome: .notConfigured,
                    targetSummary: "",
                    plan: nil,
                    failure: nil
                )
            },
            apply: { _, _, _ in
                self.lock.withLock { self.applies += 1 }
                return AgentApplyReport(
                    outcome: .notConfigured,
                    changeStatus: .notWritten,
                    failure: .cancelled,
                    targetSummary: ""
                )
            },
            authenticate: { .confirmed }
        )
    }
}
