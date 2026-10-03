import Darwin
import Foundation
import XCTest
@testable import AskKeyAppKit
import AskKeyBroker
@testable import AskKeyIntegrations
@testable import AskKeyVault
@testable import AskKeyTestSupport

@MainActor
final class AgentClientConnectorTests: AgentClientConnectorTestSupport {
#if DEBUG
    func testDebugClientE2ERequestRequiresAnIsolatedHome() throws {
        let actualHome = URL(fileURLWithPath: "/synthetic-home", isDirectory: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-e2e-\(UUID().uuidString)", isDirectory: true)
        let isolatedHome = root.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: isolatedHome.path
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let output = isolatedHome.appendingPathComponent("result.json")
        let environment = [
            "ASKKEY_CLIENT_E2E": "codex",
            "ASKKEY_CLIENT_E2E_HOME": isolatedHome.path,
            "ASKKEY_CLIENT_E2E_OUTPUT": output.path,
        ]

        let request = DebugClientE2ERequest.parse(
            environment: environment,
            actualHome: actualHome
        )
        XCTAssertEqual(request?.client, .codex)
        XCTAssertEqual(request?.home, isolatedHome)
        XCTAssertEqual(request?.output, output)

        var unsafe = environment
        unsafe["ASKKEY_CLIENT_E2E_HOME"] = actualHome.path
        XCTAssertNil(DebugClientE2ERequest.parse(
            environment: unsafe,
            actualHome: actualHome
        ))

        let linkedHome = root.appendingPathComponent("linked-home", isDirectory: true)
        try? FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: actualHome)
        unsafe["ASKKEY_CLIENT_E2E_HOME"] = linkedHome.path
        unsafe["ASKKEY_CLIENT_E2E_OUTPUT"] = linkedHome.appendingPathComponent("result.json").path
        XCTAssertNil(DebugClientE2ERequest.parse(
            environment: unsafe,
            actualHome: actualHome
        ))

        unsafe["ASKKEY_CLIENT_E2E_HOME"] = isolatedHome.path
        unsafe["ASKKEY_CLIENT_E2E_OUTPUT"] = isolatedHome
            .appendingPathComponent("missing/result.json").path
        XCTAssertNil(DebugClientE2ERequest.parse(
            environment: unsafe,
            actualHome: actualHome
        ))
    }

    func testDebugClientE2EFalseResultRecordsFailureAndRollback() {
        let result = DebugClientE2EResult.completed(client: .cursor, connected: false)

        XCTAssertFalse(result.connected)
        XCTAssertEqual(result.rollback, "completed")
        XCTAssertNotNil(result.error)
    }
#endif
}
