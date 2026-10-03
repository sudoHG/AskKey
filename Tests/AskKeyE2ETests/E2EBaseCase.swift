import Darwin
import XCTest

class E2EBaseCase: XCTestCase {
    var app: XCUIApplication!
    var runDirectory: URL!
    var runtimeDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let path = try XCTUnwrap(environment["ASKKEY_E2E_APP"])
        let rootPath = try XCTUnwrap(environment["ASKKEY_E2E_ROOT"])
        let resolvedRoot = URL(fileURLWithPath: rootPath, isDirectory: true).resolvingSymlinksInPath()
        // Foundation abbreviates /private/tmp to /tmp; retain physical ancestors.
        let physicalRoot = try XCTUnwrap(realpath(resolvedRoot.path, nil))
        defer { free(physicalRoot) }
        let root = URL(fileURLWithPath: String(cString: physicalRoot), isDirectory: true)
        XCTAssertEqual(rootPath, root.path)
        XCTAssertEqual(root.deletingLastPathComponent().path, "/private/tmp")
        XCTAssertTrue(root.lastPathComponent.hasPrefix("ak-e2e-"))
        let appURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let bundle = try XCTUnwrap(Bundle(url: appURL))
        XCTAssertEqual(bundle.bundleIdentifier, "com.sudohg.askkey.app.e2e")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "AskKeyE2ETesting") as? Bool, true)
        XCTAssertFalse(appURL.path.hasPrefix("/Applications/"))
        // Xcode's runner is sandboxed. Create fixtures in its own writable
        // temporary directory instead of requesting access to the repository.
        runDirectory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("askkey-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: runDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let caseID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
        runtimeDirectory = root.appendingPathComponent(String(caseID), isDirectory: true)
        XCTAssertLessThan(runtimeDirectory.appendingPathComponent("daemon.sock").path.utf8.count, 104)
        app = XCUIApplication(url: appURL)
        app.launchEnvironment = [
            "ASKKEY_E2E_ROOT": root.path,
            "ASKKEY_DEBUG_RUN_DIRECTORY": runtimeDirectory.path,
            "ASKKEY_E2E_RUN_DIRECTORY": runtimeDirectory.path,
            "ASKKEY_E2E_CONTROL_DIRECTORY": runDirectory.path,
            "ASKKEY_E2E_SCENARIO": "connected",
            "ASKKEY_E2E_LANGUAGE": "zh-Hans"
        ]
    }

    override func tearDownWithError() throws {
        defer {
            if let app, app.state != .notRunning { app.terminate() }
            if let runDirectory { try? FileManager.default.removeItem(at: runDirectory) }
        }
        if let app, app.state != .notRunning {
            let window = app.windows.firstMatch
            if window.exists {
                // macOS can report stale window capture coordinates after a
                // display change. Capture the screen while preserving the UI tree.
                let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screenshot.name = name
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            let tree = XCTAttachment(string: app.windows.debugDescription)
            tree.name = "UI tree"
            tree.lifetime = .keepAlways
            add(tree)
            try sendFixtureCommand("shutdown")
            let cleanup = runDirectory.appendingPathComponent("cleanup.json")
            let cleaned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: cleanup.path)
            }, object: nil)
            let result = XCTWaiter.wait(for: [cleaned], timeout: 10)
            // Attach every original reply before asserting cleanup, including
            // runs that already failed or timed out in the scenario.
            attachFixtureEvidence()
            XCTAssertEqual(result, .completed, "Fixture process cleanup did not finish")
            if let data = try? Data(contentsOf: cleanup),
               let report = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                XCTAssertEqual(report["processesStopped"] as? Bool, true)
            }
        } else {
            attachFixtureEvidence()
        }
        if let runDirectory {
            let location = XCTAttachment(string: runDirectory.path)
            location.name = "Isolated fixture directory"
            location.lifetime = .keepAlways
            add(location)
        }
    }

    private func attachFixtureEvidence() {
        guard let runDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: runDirectory, includingPropertiesForKeys: nil
              ) else { return }
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url), data.count <= 1_048_576 else { continue }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.data")
            attachment.name = "Fixture original — \(url.lastPathComponent)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func click(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[identifier].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 8), "Missing control: \(identifier)", file: file, line: line)
        XCTAssertTrue(button.isHittable, "Control is not visible: \(identifier)", file: file, line: line)
        button.click()
    }

    func sendFixtureCommand(_ command: String) throws {
        try Data("requested\n".utf8).write(
            to: runDirectory.appendingPathComponent("command-\(command).txt"), options: .atomic
        )
    }

    func waitForEvidence(_ filename: String, timeout: TimeInterval = 15) throws -> [String: Any] {
        let evidence = runDirectory.appendingPathComponent(filename)
        let failure = runDirectory.appendingPathComponent("failure.json")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: evidence.path)
                || FileManager.default.fileExists(atPath: failure.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, filename)
        if FileManager.default.fileExists(atPath: failure.path) {
            let detail = try String(contentsOf: failure, encoding: .utf8)
            XCTFail("Real Broker/helper fixture failed: \(detail)")
            throw NSError(domain: "AskKeyE2E", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: evidence)) as? [String: Any])
    }

    func assertTargetExecutionCount(_ expected: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let marker = runDirectory.appendingPathComponent("executions.txt")
        let entries = FileManager.default.fileExists(atPath: marker.path)
            ? try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").count : 0
        XCTAssertEqual(entries, expected, "Only the target process writes this execution ledger", file: file, line: line)
    }
}
