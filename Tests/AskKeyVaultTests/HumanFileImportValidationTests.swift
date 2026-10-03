import CryptoKit
import Darwin
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class HumanFileImportValidationTests: HumanFileCredentialTestSupport {
    func testSymbolicLinkIsRejectedWithoutFollowing() throws {
        let directory = try scratchDirectory()
        let target = directory.appendingPathComponent("target.pem")
        let link = directory.appendingPathComponent("link.pem")
        let payload = Data("ssh-ed25519 AAAA fixture-key".utf8)
        try payload.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let before = try Data(contentsOf: target)

        XCTAssertThrowsError(try FileImport.freeze(url: link)) { error in
            guard case VaultError.invalidFileCredential(.symbolicLink) = error else {
                return XCTFail("expected symbolicLink, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: target), before)
        XCTAssertEqual(try directoryNames(directory), ["link.pem", "target.pem"])
    }
    func testDirectoryIsRejected() throws {
        let directory = try scratchDirectory()
        XCTAssertThrowsError(try FileImport.freeze(url: directory)) { error in
            guard case VaultError.invalidFileCredential(.directory) = error else {
                return XCTFail("expected directory, got \(error)")
            }
        }
    }
    func testDeviceFileIsRejected() throws {
        XCTAssertThrowsError(try FileImport.freeze(url: URL(fileURLWithPath: "/dev/null"))) { error in
            guard case VaultError.invalidFileCredential(.specialFile) = error else {
                return XCTFail("expected specialFile, got \(error)")
            }
        }
    }
    func testFifoIsRejectedWithoutBlocking() throws {
        let fifo = try scratchDirectory().appendingPathComponent("named.pipe")
        guard mkfifo(fifo.path, 0o600) == 0 else {
            return XCTFail("mkfifo failed")
        }

        let finished = expectation(description: "fifo freeze fails closed")
        DispatchQueue.global().async {
            do {
                _ = try FileImport.freeze(url: fifo)
                XCTFail("expected specialFile")
            } catch VaultError.invalidFileCredential(.specialFile) {
                ()
            } catch {
                XCTFail("expected specialFile, got \(error)")
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 1.0)
    }
    func testOversizedFileIsRejected() throws {
        let url = try scratchDirectory().appendingPathComponent("huge.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(FileImport.maxByteCount) + 1)
        try handle.close()

        XCTAssertThrowsError(try FileImport.freeze(url: url)) { error in
            guard case VaultError.invalidFileCredential(.tooLarge) = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, FileImport.maxByteCount + 1)
    }
    func testReplacementDuringReadFailsClosed() throws {
        let url = try scratchDirectory().appendingPathComponent("race.p8")
        try Data("first-bytes".utf8).write(to: url)

        XCTAssertThrowsError(
            try FileImport.freeze(url: url) { stage in
                guard stage == .afterPathCheck else { return }
                try FileManager.default.removeItem(at: url)
                try Data("second-bytes".utf8).write(to: url)
            }
        ) { error in
            guard case VaultError.invalidFileCredential(.replacedDuringRead) = error else {
                return XCTFail("expected replacedDuringRead, got \(error)")
            }
        }
    }
    func testABASameSizeSwapThenRestoreOriginalInodeFailsClosed() throws {
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("key.p8")
        let aside = directory.appendingPathComponent("aside.p8")
        let original = Data("AAAAAAAAAA".utf8)
        let decoy = Data("BBBBBBBBBB".utf8)
        try original.write(to: url)
        defer {
            if FileManager.default.fileExists(atPath: aside.path) {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.moveItem(at: aside, to: url)
            }
        }

        XCTAssertThrowsError(
            try FileImport.freeze(url: url) { stage in
                switch stage {
                case .afterPathCheck:
                    try FileManager.default.moveItem(at: url, to: aside)
                    try decoy.write(to: url)
                case .afterOpen:
                    try FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: aside, to: url)
                }
            }
        ) { error in
            guard case VaultError.invalidFileCredential(.replacedDuringRead) = error else {
                return XCTFail("expected replacedDuringRead, got \(error)")
            }
        }
    }
    func testSameInodeSameSizeOverwriteFailsClosed() throws {
        let url = try scratchDirectory().appendingPathComponent("key.p8")
        let original = Data("AAAAAAAAAA".utf8)
        try original.write(to: url)

        XCTAssertThrowsError(
            try FileImport.freeze(url: url) { stage in
                guard stage == .afterOpen else { return }
                try Data("BBBBBBBBBB".utf8).write(to: url)
            }
        ) { error in
            guard case VaultError.invalidFileCredential(.replacedDuringRead) = error else {
                return XCTFail("expected replacedDuringRead, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("BBBBBBBBBB".utf8))
    }
    func testOrdinaryFilesOfAnyExtensionFreezeNameSizeAndDigest() throws {
        let directory = try scratchDirectory()
        let payload = Data("ssh-ed25519 AAAA fixture-key".utf8)
        let names = ["AuthKey.p8", "id_ed25519", "service-account.json", "weird.notakey"]
        let beforeNames = try directoryNames(directory)

        for name in names {
            let url = directory.appendingPathComponent(name)
            try payload.write(to: url)
            let frozen = try FileImport.freeze(url: url)
            XCTAssertEqual(frozen.originalFilename, name)
            XCTAssertEqual(frozen.bytes, payload)
            XCTAssertEqual(frozen.byteSize, 28)
            XCTAssertEqual(frozen.contentDigest, Self.fixtureDigest)
            XCTAssertEqual(try Data(contentsOf: url), payload)
        }

        XCTAssertEqual(
            try directoryNames(directory),
            (beforeNames + names).sorted()
        )
    }
}
