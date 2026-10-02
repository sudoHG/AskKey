import AppKit
import SwiftUI
import XCTest
@testable import AskKeyApp

@MainActor
final class AgentOnboardingIsolationUITests: XCTestCase {
    func testIsolatedStatesRenderOrdinaryUIWithoutPrototypeChrome() throws {
        let directory = repoRoot().appendingPathComponent("331-404-ui-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var log: [String] = []
        for scenario in IsolatedOnboardingScenario.all {
            let vault = VaultViewModel(runtimeFileCleanupFailures: { false })
            vault.onboarding = AgentOnboardingCoordinator(
                operations: .inactive,
                clock: { Date(timeIntervalSince1970: 1_700_000_000) },
                initialSessions: scenario.sessions
            )
            if let expanded = scenario.expanded {
                vault.onboarding.explain(expanded)
            }
            let view = AgentOnboardingView()
                .environment(vault)
                .frame(width: 720, height: 860)
            let image = try render(view, size: CGSize(width: 720, height: 860))
            let url = directory.appendingPathComponent("\(scenario.id).png")
            try image.pngData.write(to: url)
            log.append("\(scenario.id): \(scenario.title)")
            XCTAssertGreaterThan(image.pngData.count, 1_000)
        }
        let logURL = directory.appendingPathComponent("actions.txt")
        try (["331-404 isolated UI states", ""] + log)
            .joined(separator: "\n")
            .write(to: logURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("prototype-bar").path))
    }

    private func render<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw XCTSkip("host could not cache the onboarding view")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private extension NSBitmapImageRep {
    var pngData: Data {
        representation(using: .png, properties: [:]) ?? Data()
    }
}

private struct IsolatedOnboardingScenario {
    var id: String
    var title: String
    var expanded: AgentClient?
    var sessions: [AgentClient: AgentClientOnboardingSession]

    static let all: [IsolatedOnboardingScenario] = [
        .init(id: "01-first-visit", title: "首次进入，尚未检查", expanded: nil, sessions: [:]),
        .init(
            id: "03-ready-to-confirm",
            title: "本机 Codex 待确认范围",
            expanded: .codex,
            sessions: [
                .codex: AgentClientOnboardingSession(
                    lastKnownResult: AgentLastKnownResult(
                        outcome: .notConfigured,
                        checkedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        targetSummary: "Codex"
                    ),
                    attempt: .init(phase: .readyToConfirm, failure: nil, changeStatus: .notWritten, message: ""),
                    operationID: nil,
                    plan: AgentOnboardingPlan(
                        client: .codex,
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                        targetIdentity: "Codex",
                        scopeSummary: "Add Ask Key for the current user of Codex. Other connections stay as they are. A backup is created first.",
                        configurationPresent: false,
                        verifiesOnly: false,
                        preconditionSummary: "If verification fails, Ask Key restores the original settings."
                    )
                )
            ]
        ),
        .init(
            id: "04-success",
            title: "已验证连接",
            expanded: nil,
            sessions: [
                .codex: AgentClientOnboardingSession(
                    lastKnownResult: AgentLastKnownResult(
                        outcome: .verifiedConnected,
                        checkedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        targetSummary: "Codex"
                    ),
                    attempt: .init(phase: .completed, failure: nil, changeStatus: .verifiedAndKept, message: ""),
                    operationID: nil,
                    plan: nil
                )
            ]
        ),
        .init(
            id: "06-restore-failed",
            title: "恢复失败，保留备份并阻止普通重试",
            expanded: .cursor,
            sessions: [
                .cursor: AgentClientOnboardingSession(
                    lastKnownResult: AgentLastKnownResult(
                        outcome: .notConfigured,
                        checkedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        targetSummary: "Cursor"
                    ),
                    attempt: .init(phase: .recoveryRequired, failure: .restoreFailed, changeStatus: .restoreFailed, message: ""),
                    operationID: nil,
                    plan: nil
                )
            ]
        )
    ]
}
