import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
import AskKeyBroker
@testable import AskKeyIntegrations
@testable import AskKeySystem

final class CodexTOMLValidationTests: CodexUserMCPAdapterTests {
    func testUnclosedAndDuplicateTOMLFailClosed() throws {
        let samples = [
            "model = [\n",
            "model = \"ok\"\nmodel = \"dup\"\n",
            "[server]\nkey = 1\n[server]\nkey = 2\n",
        ]
        for text in samples {
            let harness = try makeHarness()
            try harness.writeConfig(text, mode: 0o600)
            XCTAssertThrowsError(try harness.adapter.apply()) { error in
                XCTAssertEqual(error as? CodexUserMCPError, .illegalConfig, text)
            }
            XCTAssertEqual(try harness.configText(), text)
            XCTAssertFalse(try harness.configText().contains("[mcp_servers.askkey]"))
            XCTAssertNotEqual(harness.adapter.status(), .connected)
        }
    }
    func testLegacyRawBackupFailsClosedWithoutOverwritingCurrentConfig() throws {
        let harness = try makeHarness(brokerHealth: "down")
        try harness.writeConfig("model = \"dirty\"\n", mode: 0o600)
        try FileManager.default.createDirectory(
            at: harness.backupDirectory,
            withIntermediateDirectories: true
        )
        let backup = harness.backupDirectory.appendingPathComponent("config.toml")
        try Data("model = \"original\"\n".utf8).write(to: backup)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: backup.path
        )
        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CodexUserMCPError, .rollbackFailed)
        }
        XCTAssertEqual(try harness.configText(), "model = \"dirty\"\n")
    }
    func testRedactedDiffHidesSingleQuotedBareAndOtherServerSecrets() throws {
        let harness = try makeHarness()
        try harness.writeConfig("""
        TOKEN = '\(Harness.secret)'
        BARE = \(Harness.secret)
        [mcp_servers.github]
        command = "npx"
        args = ["--token", "\(Harness.secret)"]
        """, mode: 0o600)
        let preview = try harness.adapter.preview()
        XCTAssertFalse(preview.redactedDescription.contains(Harness.secret))
        XCTAssertTrue(preview.redactedDescription.contains("***"))
    }
    func testEmptyAssignmentAndDottedKeyConflictFailClosed() throws {
        let samples = [
            "model =\n",
            "[foo]\nbar = 1\n[foo.bar]\nx = 2\n",
        ]
        for text in samples {
            let harness = try makeHarness()
            try harness.writeConfig(text, mode: 0o600)
            XCTAssertThrowsError(try harness.adapter.apply()) { error in
                XCTAssertEqual(error as? CodexUserMCPError, .illegalConfig, text)
            }
            XCTAssertEqual(try harness.configText(), text)
            XCTAssertFalse(try harness.configText().contains("[mcp_servers.askkey]"))
            XCTAssertNotEqual(harness.adapter.status(), .connected)
        }
    }
    func testLegalMultilineValueWithEqualsStillConnects() throws {
        let harness = try makeHarness()
        try harness.writeConfig("""
        note = \"\"\"
        a = b
        \"\"\"
        """, mode: 0o600)
        XCTAssertEqual(try harness.adapter.apply().status, .connected)
        XCTAssertTrue(try harness.configText().contains("a = b"))
        XCTAssertTrue(try harness.configText().contains("[mcp_servers.askkey]"))
    }
    func testDottedKeyParentCannotBeRedefinedAsExplicitTable() throws {
        let harness = try makeHarness()
        let original = "a.b = 1\n[a]\nc = 2\n"
        try harness.writeConfig(original, mode: 0o600)
        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CodexUserMCPError, .illegalConfig)
        }
        XCTAssertEqual(try harness.configText(), original)
    }
    func testLegalMultilineArrayAndImplicitParentTableAreMerged() throws {
        let harness = try makeHarness()
        let original = """
        notify = [
          "/usr/bin/true",
        ]
        [a.b]
        x = 1
        [a]
        y = 2
        """
        try harness.writeConfig(original, mode: 0o600)

        XCTAssertEqual(try harness.adapter.apply().status, .connected)
        let after = try harness.configText()
        XCTAssertTrue(after.contains("notify = [\n  \"/usr/bin/true\",\n]"))
        XCTAssertTrue(after.contains("[a.b]\nx = 1\n[a]\ny = 2\n"))
        XCTAssertTrue(after.contains("[mcp_servers.askkey]"))
        XCTAssertTrue(try harness.adapter.hasConfiguration())
    }
    func testMultilineStringSecretsAreRedacted() throws {
        let harness = try makeHarness()
        try harness.writeConfig("""
        TOKEN = \"\"\"
        \(Harness.secret)
        \"\"\"
        OTHER = '''
        \(Harness.secret)
        '''
        """, mode: 0o600)
        let preview = try harness.adapter.preview()
        XCTAssertFalse(preview.redactedDescription.contains(Harness.secret))
        XCTAssertTrue(preview.redactedDescription.contains("***"))
    }
    func testEmptyKeyAndEmptyDottedSegmentsFailClosed() throws {
        let samples = [
            "= 1\n",
            ".foo = 1\n",
            "foo. = 1\n",
        ]
        for text in samples {
            let harness = try makeHarness()
            try harness.writeConfig(text, mode: 0o600)
            XCTAssertThrowsError(try harness.adapter.apply()) { error in
                XCTAssertEqual(error as? CodexUserMCPError, .illegalConfig, text)
            }
            XCTAssertEqual(try harness.configText(), text)
            XCTAssertFalse(try harness.configText().contains("[mcp_servers.askkey]"))
            XCTAssertNotEqual(harness.adapter.status(), .connected)
        }
    }
    func testArrayOfTablesAndQuotedKeyDoNotBlockAskKey() throws {
        let harness = try makeHarness()
        let original = """
        "a.b" = 1
        a.b = 2
        [[servers]]
        name = "one"
        [[servers]]
        name = "two"
        """
        try harness.writeConfig(original, mode: 0o600)
        XCTAssertEqual(try harness.adapter.apply().status, .connected)
        let after = try harness.configText()
        XCTAssertTrue(after.contains("[[servers]]"))
        XCTAssertTrue(after.contains("name = \"one\""))
        XCTAssertTrue(after.contains("name = \"two\""))
        XCTAssertTrue(after.contains("\"a.b\" = 1"))
        XCTAssertTrue(after.contains("a.b = 2"))
        XCTAssertTrue(after.contains("[mcp_servers.askkey]"))
    }
    func testArrayTableMixedWithStandardTableOrValueFailsClosed() throws {
        let samples = [
            "[[a]]\nx = 1\n[a]\ny = 2\n",
            "[a]\ny = 2\n[[a]]\nx = 1\n",
            "a = 1\n[[a]]\nx = 2\n",
        ]
        for text in samples {
            let harness = try makeHarness()
            try harness.writeConfig(text, mode: 0o600)
            XCTAssertThrowsError(try harness.adapter.apply()) { error in
                XCTAssertEqual(error as? CodexUserMCPError, .illegalConfig, text)
            }
            XCTAssertEqual(try harness.configText(), text)
            XCTAssertFalse(try harness.configText().contains("[mcp_servers.askkey]"))
            XCTAssertNotEqual(harness.adapter.status(), .connected)
        }
    }
    func testNestedArrayOfTablesCanConnect() throws {
        let harness = try makeHarness()
        let original = """
        [[fruits]]
        name = "apple"
        [fruits.physical]
        color = "red"
        [[fruits]]
        name = "banana"
        [fruits.physical]
        color = "yellow"
        """
        try harness.writeConfig(original, mode: 0o600)
        XCTAssertEqual(try harness.adapter.apply().status, .connected)
        let after = try harness.configText()
        XCTAssertTrue(after.contains("name = \"apple\""))
        XCTAssertTrue(after.contains("name = \"banana\""))
        XCTAssertTrue(after.contains("color = \"red\""))
        XCTAssertTrue(after.contains("color = \"yellow\""))
        XCTAssertTrue(after.contains("[mcp_servers.askkey]"))
    }
}
