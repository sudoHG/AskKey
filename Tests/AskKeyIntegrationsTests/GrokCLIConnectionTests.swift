import AskKeyBroker
import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
@testable import AskKeyIntegrations

final class GrokCLIConnectionTests: GrokCLIAdapterTests {
    func testStatusRequiresListDoctorHelperAndBrokerTogether() throws {
        let fixture = try Fixture()
        let grok = try fixture.writeSupportedGrok()
        try fixture.startBroker()
        XCTAssertFalse(try fixture.adapter(grokExecutable: grok).status().connected)

        let connected = try fixture.adapter(grokExecutable: grok).connect()
        XCTAssertTrue(connected.connected, connected.reason)

        fixture.stopBroker()
        let withoutBroker = try fixture.adapter(grokExecutable: grok).status()
        XCTAssertFalse(withoutBroker.connected)
        XCTAssertEqual(withoutBroker.reason, "broker_unhealthy")
    }
    func testConnectionRejectsAnExecutableHelperThatFailsSignatureTrust() throws {
        let fixture = try Fixture()
        let grok = try fixture.writeSupportedGrok()
        try fixture.startBroker()
        let adapter = fixture.adapter(
            grokExecutable: grok,
            signing: CodexHelperSigning { _ in false }
        )

        XCTAssertThrowsError(try adapter.connect()) { error in
            XCTAssertEqual(error as? GrokCLIAdapterError, .verificationFailed("helper_signature"))
        }
    }
    func testMissingHelperSpawnKeepsENOENTAndRestoresOriginalTOML() throws {
        let fixture = try Fixture()
        try fixture.startBroker()
        let original = """
        # keep this comment
        [ui]
        simple_mode = true
        """
        try Data(original.utf8).write(to: fixture.configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.configURL.path)

        let missing = fixture.directory.appendingPathComponent("no-such-helper")
        let grok = try fixture.writeExecutable(
            name: "grok-missing-helper",
            contents: """
            #!/bin/sh
            if [ "$1" = "mcp" ] && [ "$2" = "add" ] && [ "$3" = "--help" ]; then
              echo '--scope user'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
              echo '[{"command":"\(missing.path)","args":["mcp"],"enabled":true,"name":"askkey","scope":"user"}]'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "doctor" ]; then
              echo '{"servers":[{"name":"askkey","transport":"stdio","target":"askkey mcp","healthy":true}]}'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "add" ]; then
              exit 0
            fi
            exit 1
            """
        )
        var adapter = fixture.adapter(grokExecutable: grok, signing: CodexHelperSigning { _ in true })
        adapter.helperExecutable = missing

        XCTAssertThrowsError(try adapter.connect()) { error in
            guard case GrokCLIAdapterError.verificationFailed(let reason) = error else {
                return XCTFail("expected verificationFailed with POSIX ENOENT, got \(error)")
            }
            let lowered = reason.lowercased()
            XCTAssertTrue(
                lowered.contains("no such file")
                    || lowered.contains("enoent")
                    || reason.contains("无此文件")
                    || reason.contains("\(ENOENT)"),
                "spawn failure must keep the captured POSIX reason, got \(reason)"
            )
        }
        XCTAssertEqual(try String(contentsOf: fixture.configURL, encoding: .utf8), original)
        XCTAssertEqual(try fixture.posixMode(at: fixture.configURL), 0o640)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backupDataURL.path))
    }
}
