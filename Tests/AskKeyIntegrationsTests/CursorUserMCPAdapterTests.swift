import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
import AskKeyBroker
@testable import AskKeyIntegrations

class CursorUserMCPAdapterTests: AskKeyCoreTestCase {
    func makeHarness(
        replaceConfig: ((URL, URL) throws -> Void)? = nil,
        removeConfig: ((URL) throws -> Void)? = nil,
        moveConfigExclusively: ((URL, URL) throws -> Void)? = nil,
        removeBackupItem: ((URL) throws -> Void)? = nil,
        helperURL: URL? = nil
    ) throws -> Harness {
        let harness = try Harness(
            replaceConfig: replaceConfig,
            removeConfig: removeConfig,
            moveConfigExclusively: moveConfigExclusively,
            removeBackupItem: removeBackupItem,
            helperURL: helperURL
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }
        return harness
    }

    func fakeHelper(lines: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ak-cursor-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fake-mcp")
        var script = "#!/bin/sh\nwhile IFS= read -r _; do :; done\n"
        for line in lines {
            script += "printf '%s\\n' '" + line.replacingOccurrences(of: "'", with: "'\\''") + "'\n"
        }
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func termIgnoringHelper() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ak-cursor-term-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ignore-term.c")
        let binary = directory.appendingPathComponent("ignore-term")
        try """
        #include <signal.h>
        #include <unistd.h>
        int main(void) {
            signal(SIGTERM, SIG_IGN);
            for (;;) pause();
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = [source.path, "-o", binary.path]
        compile.standardOutput = FileHandle.nullDevice
        compile.standardError = FileHandle.nullDevice
        try compile.run()
        compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0)
        return binary
    }
}
