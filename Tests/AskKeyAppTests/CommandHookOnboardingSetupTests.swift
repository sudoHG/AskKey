import Foundation
import Darwin
import XCTest
import AskKeyBroker
import AskKeyCore
@testable import AskKeyAppKit

final class CommandHookOnboardingSetupTests: AskKeyAppTestCase {
#if DEBUG
    func testCursorConnectorCheckPreviewAndApplyConfigureMCPAndDiscoveryHook() throws {
        let fixture = try CursorCommandFixture()
        defer { fixture.close() }

        let checked = try fixture.connector.check(.cursor)
        XCTAssertEqual(checked.outcome, .notConfigured)
        XCTAssertEqual(checked.discovery, .missing)
        let plan = try XCTUnwrap(checked.plan)
        XCTAssertTrue(plan.scopeSummary.contains("SSH"))
        XCTAssertTrue(plan.preconditionSummary.contains("MCP"))
        XCTAssertTrue(try XCTUnwrap(plan.commandHookPlan).changed)

        let preview = try fixture.connector.preview(.cursor)
        XCTAssertFalse(preview.connected)
        XCTAssertEqual(preview.discovery, .missing)
        XCTAssertFalse(preview.configurationPresent)

        let applied = try fixture.connector.apply(.cursor, plan: plan)
        XCTAssertEqual(applied.outcome, .verifiedConnected)
        XCTAssertEqual(applied.changeStatus, .verifiedAndKept)
        XCTAssertNil(applied.failure)
        XCTAssertEqual(applied.discovery, .configured)

        let checkedAgain = try fixture.connector.check(.cursor)
        XCTAssertEqual(checkedAgain.outcome, .verifiedConnected)
        XCTAssertEqual(checkedAgain.discovery, .configured)
        XCTAssertNil(checkedAgain.plan)
        XCTAssertNil(checkedAgain.failure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mcpURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.hooksURL.path))
    }
#endif

    func testUnhealthyExistingMCPDoesNotOfferCommandHookWritePlan() throws {
        let fixture = try CursorCommandFixture()
        defer { fixture.close() }
        try FileManager.default.createDirectory(
            at: fixture.mcpURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let original = Data(#"{"mcpServers":{"askkey":{"command":"/missing/askkey","args":["mcp"]}}}"#.utf8)
        try original.write(to: fixture.mcpURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fixture.mcpURL.path
        )

        let report = try fixture.connector.check(.cursor)

        XCTAssertEqual(report.outcome, .existingConfigUnverified)
        XCTAssertEqual(report.failure, .verificationFailed)
        XCTAssertEqual(report.discovery, .missing)
        XCTAssertNil(report.plan)
        XCTAssertEqual(try Data(contentsOf: fixture.mcpURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.hooksURL.path))
    }

    func testHookFailureKeepsVerifiedMCPAndClearsDiscoveryReadiness() throws {
        let fixture = try CursorCommandFixture()
        defer { fixture.close() }
        let context = try fixture.connector.commandDiscoveryContext(for: .cursor)
        let reviewedHookPlan = try context.hook.preview()
        var plan = makePlan(configurationPresent: false)
        plan.commandHookPlan = reviewedHookPlan

        var mcpPresent = false
        let applied = try CommandHookOnboardingSetup.apply(
            client: .cursor,
            hook: context.hook,
            plan: plan,
            verifyHelper: context.verifyHelper,
            hasMCPConfiguration: { mcpPresent },
            isMCPConnected: { mcpPresent },
            applyMCP: {
                mcpPresent = true
                // Simulate another writer changing the reviewed hook file
                // after MCP verification and before the hook transaction.
                try FileManager.default.createDirectory(
                    at: fixture.hooksURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
                try Data(#"{"version":1,"hooks":{}}"#.utf8).write(to: fixture.hooksURL)
            },
            rollbackMCP: { mcpPresent = false }
        )

        XCTAssertEqual(applied.outcome, .configuredUnverified)
        XCTAssertEqual(applied.changeStatus, .verifiedAndKept)
        XCTAssertEqual(applied.failure, .discoverySetupFailed)
        XCTAssertEqual(applied.discovery, .unavailable)
        XCTAssertTrue(mcpPresent)
        XCTAssertEqual(
            try Data(contentsOf: fixture.hooksURL),
            Data(#"{"version":1,"hooks":{}}"#.utf8)
        )
    }

    func testMCPReadbackAfterHookIsReportedAsVerificationFailure() throws {
        let fixture = try CursorCommandFixture()
        defer { fixture.close() }
        let context = try fixture.connector.commandDiscoveryContext(for: .cursor)
        let reviewedHookPlan = try context.hook.preview()
        var plan = makePlan(configurationPresent: true)
        plan.commandHookPlan = reviewedHookPlan
        var statusReads = 0

        let applied = try CommandHookOnboardingSetup.apply(
            client: .cursor,
            hook: context.hook,
            plan: plan,
            verifyHelper: context.verifyHelper,
            hasMCPConfiguration: { true },
            isMCPConnected: {
                statusReads += 1
                return statusReads == 1
            },
            applyMCP: {}
        )

        XCTAssertEqual(applied.outcome, .configuredUnverified)
        XCTAssertEqual(applied.changeStatus, .verifiedAndKept)
        XCTAssertEqual(applied.failure, .verificationFailed)
        XCTAssertEqual(applied.discovery, .configured)
        XCTAssertTrue(try context.hook.hasExpectedHook())
    }
}

private func makePlan(configurationPresent: Bool) -> AgentOnboardingPlan {
    AgentOnboardingPlan(
        client: .cursor,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        targetIdentity: AgentClient.cursor.rawValue,
        scopeSummary: "Cursor",
        configurationPresent: configurationPresent,
        verifiesOnly: false,
        preconditionSummary: ""
    )
}

private final class CursorCommandFixture {
    let root: URL
    let home: URL
    let support: URL
    let helper: URL
    let mcpURL: URL
    let hooksURL: URL
    let broker: BrokerSocketServer
    private var environment: AskKeyTestEnvironment?

    init() throws {
        root = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true)).appendingPathComponent(
            "ak-ch-\(String(UUID().uuidString.prefix(8)))",
            isDirectory: true
        )
        home = root.appendingPathComponent("home", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        mcpURL = home.appendingPathComponent(".cursor/mcp.json")
        hooksURL = home.appendingPathComponent(".cursor/hooks.json")
        helper = Bundle(for: CommandHookOnboardingSetupTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("askkey")
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: home.path
        )
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw NSError(
                domain: "CommandHookOnboardingSetupTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The Ask Key helper executable is not present in the test bundle."]
            )
        }
        let socket = root.appendingPathComponent("broker.sock").path
        environment = AskKeyTestEnvironment(overrides: ["ASKKEY_BROKER_SOCKET": socket])
        broker = BrokerSocketServer(
            socketPath: socket,
            handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil })
        )
        do {
            try broker.start()
        } catch {
            environment = nil
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    var connector: AgentClientConnector {
#if DEBUG
        AgentClientConnector(
            home: home,
            supportDirectory: support,
            helperURL: helper
        )
#else
        AgentClientConnector(home: home, supportDirectory: support)
#endif
    }

    func close() {
        broker.stop()
        environment = nil
        try? FileManager.default.removeItem(at: root)
    }

}
