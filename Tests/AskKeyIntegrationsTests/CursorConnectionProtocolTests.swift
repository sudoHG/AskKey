import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
import AskKeyBroker
@testable import AskKeyIntegrations

final class CursorConnectionProtocolTests: CursorUserMCPAdapterTests {
    func testConnectionRequiresConfigHelperProtocolAndBrokerHealth() throws {
        let harness = try makeHarness()
        XCTAssertFalse(try harness.adapter.verify().connected)

        _ = try harness.adapter.apply()
        let withoutBroker = try harness.adapter.verify()
        XCTAssertTrue(withoutBroker.configReady)
        XCTAssertTrue(withoutBroker.helperReady)
        XCTAssertTrue(withoutBroker.protocolReady)
        XCTAssertFalse(withoutBroker.brokerHealthy)
        XCTAssertFalse(withoutBroker.connected)

        let missingHelper = CursorUserMCPAdapter(
            homeDirectory: harness.home,
            backupDirectory: harness.backupDirectory,
            helperURL: harness.root.appendingPathComponent("missing-helper"),
            brokerSocketPath: harness.socketPath
        )
        let helperMissing = try missingHelper.verify()
        XCTAssertFalse(helperMissing.helperReady)
        XCTAssertFalse(helperMissing.protocolReady)
        XCTAssertFalse(helperMissing.connected)
    }
    func testConnectionRejectsAnExecutableHelperThatFailsSignatureTrust() throws {
        let harness = try makeHarness()
        _ = try harness.adapter.apply()
        let untrusted = CursorUserMCPAdapter(
            homeDirectory: harness.home,
            backupDirectory: harness.backupDirectory,
            helperURL: harness.helperURL,
            brokerSocketPath: harness.socketPath,
            signing: CodexHelperSigning { _ in false }
        )

        let status = try untrusted.status()

        XCTAssertTrue(status.configReady)
        XCTAssertFalse(status.helperReady)
        XCTAssertFalse(status.protocolReady)
        XCTAssertFalse(status.connected)
    }
    func testProtocolRequiresJSONRPCVersionIdAndAbsenceOfError() throws {
        let harness = try makeHarness(helperURL: try fakeHelper(
            lines: [
                #"{"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"askkey"}}}"#,
                #"{"result":{"tools":[{"name":"list_credentials"},{"name":"run"}]}}"#,
            ]
        ))
        _ = try harness.adapter.apply()
        try harness.withBroker { _ in
            let status = try harness.adapter.verify()
            XCTAssertTrue(status.configReady)
            XCTAssertTrue(status.brokerHealthy)
            XCTAssertFalse(status.protocolReady)
            XCTAssertFalse(status.connected)
        }
    }
    func testConnectionRejectsAMismatchedHelperVersion() throws {
        let harness = try makeHarness(helperURL: try fakeHelper(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"askkey","version":"9.9.9"}}}"#,
                #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"list_credentials"},{"name":"run"}]}}"#,
            ]
        ))
        _ = try harness.adapter.apply()
        try harness.withBroker { _ in
            let status = try harness.adapter.status()
            XCTAssertTrue(status.helperReady)
            XCTAssertFalse(status.protocolReady)
            XCTAssertFalse(status.connected)
        }
    }
    func testProtocolRejectsBooleanAndFractionalResponseIDs() throws {
        let initialize = #"{"protocolVersion":"2024-11-05","serverInfo":{"name":"askkey"}}"#
        let tools = #"{"tools":[{"name":"list_credentials"},{"name":"run"}]}"#
        for lines in [
            [
                #"{"jsonrpc":"2.0","id":true,"result":\#(initialize)}"#,
                #"{"jsonrpc":"2.0","id":2,"result":\#(tools)}"#,
            ],
            [
                #"{"jsonrpc":"2.0","id":1.5,"result":\#(initialize)}"#,
                #"{"jsonrpc":"2.0","id":2.9,"result":\#(tools)}"#,
            ],
        ] {
            let harness = try makeHarness(helperURL: try fakeHelper(lines: lines))
            _ = try harness.adapter.apply()
            try harness.withBroker { _ in
                let status = try harness.adapter.verify()
                XCTAssertTrue(status.configReady)
                XCTAssertTrue(status.brokerHealthy)
                XCTAssertFalse(status.protocolReady)
                XCTAssertFalse(status.connected)
            }
        }
    }
    func testVerifyReturnsWhenHelperIgnoresTermination() throws {
        let helper = try termIgnoringHelper()
        let harness = try makeHarness(helperURL: helper)
        defer {
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-9", "-f", helper.path]
            try? pkill.run()
            pkill.waitUntilExit()
        }
        _ = try harness.adapter.apply()
        let finished = expectation(description: "verify returned")
        var status: CursorMCPConnectionStatus?
        DispatchQueue.global(qos: .userInitiated).async {
            status = try? harness.adapter.verify()
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(status?.connected, false)
        XCTAssertEqual(status?.protocolReady, false)
    }
}
