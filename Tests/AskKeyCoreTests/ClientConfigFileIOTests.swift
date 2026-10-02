import Darwin
import XCTest
@testable import AskKeyCore

final class ClientConfigFileIOTests: XCTestCase {
    func testPublishThenReadRoundTripPreservesBytesAndMode() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.toml")
        let payload = Data("token = \"visible\"\n".utf8)

        try ClientConfigFileIO.publishAtomically(
            payload,
            to: url,
            mode: 0o640,
            exclusive: true,
            temporaryPrefix: ".askkey-io-"
        )

        let file = try ClientConfigFileIO.readRegularFile(url, maximumBytes: 1_048_576)
        XCTAssertEqual(file.bytes, payload)
        XCTAssertEqual(file.mode, 0o640)
        XCTAssertEqual(try ClientConfigFileIO.inspectRegularFile(url), 0o640)
    }

    func testReadRejectsSymlink() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("real.toml")
        let link = directory.appendingPathComponent("config.toml")
        try Data("keep\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try ClientConfigFileIO.readRegularFile(link)) { error in
            XCTAssertEqual(error as? ClientConfigFileIO.Failure, .unsafe)
        }
        XCTAssertThrowsError(try ClientConfigFileIO.inspectRegularFile(link)) { error in
            XCTAssertEqual(error as? ClientConfigFileIO.Failure, .unsafe)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("keep\n".utf8))
    }

    func testExclusivePublishFailsWhenDestinationExists() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let original = Data(#"{}"#.utf8)
        try original.write(to: url)

        XCTAssertThrowsError(
            try ClientConfigFileIO.publishAtomically(
                Data(#"{"replaced":true}"#.utf8),
                to: url,
                mode: 0o600,
                exclusive: true,
                temporaryPrefix: ".askkey-io-"
            )
        ) { error in
            XCTAssertEqual(error as? ClientConfigFileIO.Failure, .exclusiveExists)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testExclusiveRenameFailsWhenDestinationExists() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let destination = directory.appendingPathComponent("dest")
        try Data("src".utf8).write(to: source)
        try Data("dst".utf8).write(to: destination)

        XCTAssertThrowsError(
            try ClientConfigFileIO.renameExclusively(from: source, to: destination)
        ) { error in
            XCTAssertEqual(error as? ClientConfigFileIO.Failure, .exclusiveExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("dst".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("src".utf8))
    }

    func testReadReportsMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try ClientConfigFileIO.readRegularFile(url)) { error in
            XCTAssertEqual(error as? ClientConfigFileIO.Failure, .notFound)
        }
    }

    func testReadEnforcesByteLimit() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("big")
        try Data(repeating: 0x61, count: 32).write(to: url)

        XCTAssertThrowsError(try ClientConfigFileIO.readRegularFile(url, maximumBytes: 16)) { error in
            XCTAssertEqual(error as? ClientConfigFileIO.Failure, .tooLarge)
        }
    }

    func testReadRejectsFIFOWithoutWaitingForWriter() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("synthetic.fifo")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)

        let started = Date()
        XCTAssertThrowsError(try ClientConfigFileIO.readRegularFile(fifo)) { error in
            XCTAssertEqual(error as? ClientConfigFileIO.Failure, .unsafe)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    func testReadRejectsFIFOReplacingARegularFileAfterInspect() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.toml")
        try Data("keep = true\n".utf8).write(to: url)
        XCTAssertNotNil(try ClientConfigFileIO.inspectRegularFile(url))

        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(mkfifo(url.path, S_IRUSR | S_IWUSR), 0)

        let started = Date()
        XCTAssertThrowsError(try ClientConfigFileIO.readRegularFile(url)) { error in
            XCTAssertEqual(error as? ClientConfigFileIO.Failure, .unsafe)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    func testTemporaryIs0600BeforePayloadIsWritten() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var observed: mode_t?
        _ = try ClientConfigFileIO.writeExclusiveTemporary(
            Data("payload".utf8),
            in: directory,
            prefix: ".askkey-io-",
            didCreate: { temporary in
                var info = stat()
                guard lstat(temporary.path, &info) == 0 else { return }
                observed = info.st_mode & 0o777
            }
        )
        XCTAssertEqual(observed, 0o600)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyClientConfigIO-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
