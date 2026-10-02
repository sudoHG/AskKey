import Darwin
import Foundation
import XCTest
@testable import AskKeyApp

final class MulticaProcessDiagnosticLogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-multica-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testWritesAndReadsBackOnlyMetadata() throws {
        let directory = root.appendingPathComponent("diagnostics", isDirectory: true)
        let record = MulticaProcessDiagnosticLog.Record(
            operation: "listing workspaces",
            exit: 7,
            stdoutBytes: 123,
            stderrBytes: 45,
            validJSON: false,
            failure: "permission_denied",
            stage: "stderr_read",
            systemError: 13,
            durationMilliseconds: 208
        )

        XCTAssertTrue(MulticaProcessDiagnosticLog.write(record, directory: directory))
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let log = try XCTUnwrap(files.first { $0.pathExtension == "json" })
        let decoded = try JSONDecoder().decode(
            MulticaProcessDiagnosticLog.Record.self,
            from: Data(contentsOf: log)
        )
        XCTAssertEqual(decoded, record)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: log), options: []) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            Set(["operation", "exit", "stdoutBytes", "stderrBytes", "validJSON", "failure", "stage", "systemError", "durationMilliseconds"])
        )
        XCTAssertFalse(object.keys.contains { $0 == "argv" || $0 == "env" || $0 == "path" })
    }

    func testUsesPrivateDirectoryAndFilePermissions() throws {
        let directory = root.appendingPathComponent("diagnostics", isDirectory: true)
        let record = MulticaProcessDiagnosticLog.Record(
            operation: "listing MCP servers",
            stdoutBytes: 0,
            stderrBytes: 0,
            validJSON: true
        )

        XCTAssertTrue(MulticaProcessDiagnosticLog.write(record, directory: directory))
        let directoryMode = try mode(of: directory)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let fileMode = try mode(of: file)
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)
    }

    func testRejectsSymlinkedDirectoryWithoutWritingToItsTarget() throws {
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let record = MulticaProcessDiagnosticLog.Record(
            operation: "listing workspaces",
            stdoutBytes: 0,
            stderrBytes: 0,
            validJSON: true
        )
        XCTAssertFalse(MulticaProcessDiagnosticLog.write(record, directory: link))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testRetainsAtMost32OwnLogsAndUnknownFiles() throws {
        let directory = root.appendingPathComponent("diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let unknown = directory.appendingPathComponent("keep-me.json")
        try Data("unrelated data".utf8).write(to: unknown)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: unknown.path)

        for index in 0..<40 {
            let record = MulticaProcessDiagnosticLog.Record(
                operation: "operation-\(index)",
                exit: index == 39 ? 1 : 0,
                stdoutBytes: index,
                stderrBytes: 0,
                validJSON: index % 2 == 0
            )
            XCTAssertTrue(MulticaProcessDiagnosticLog.write(record, directory: directory))
        }

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        XCTAssertEqual(files.filter { $0.pathExtension == "json" && $0.lastPathComponent != unknown.lastPathComponent }.count, 32)
        XCTAssertEqual(files.filter { $0.pathExtension == "json" }.count, 33)
    }

    func testConcurrentWritesDoNotExceedRetentionLimit() throws {
        let directory = root.appendingPathComponent("diagnostics", isDirectory: true)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "askkey-multica-log-tests", attributes: .concurrent)
        for index in 0..<48 {
            group.enter()
            queue.async {
                let record = MulticaProcessDiagnosticLog.Record(
                    operation: "operation-\(index)",
                    stdoutBytes: index,
                    stderrBytes: 0,
                    validJSON: true
                )
                XCTAssertTrue(MulticaProcessDiagnosticLog.write(record, directory: directory))
                group.leave()
            }
        }
        group.wait()

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "json" }.count, 32)
    }

    private func mode(of url: URL) throws -> Int {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        XCTAssertEqual(result, 0)
        return Int(info.st_mode & 0o777)
    }
}
