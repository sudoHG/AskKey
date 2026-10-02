import CryptoKit
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyCore

/// Opt-in current-library fixtures. Never runs during ordinary regression tests.
final class NativeBootstrapFixtureGenerationTests: XCTestCase {
    func testGenerateSyntheticNativeBootstrapFixtures() throws {
        guard let name = ProcessInfo.processInfo.environment["ASKKEY_GENERATE_NATIVE_BOOTSTRAP_FIXTURES"],
              !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent else {
            throw XCTSkip("Explicit synthetic fixture generation only")
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: base.path) else { throw FixtureError.destinationAlreadyExists }
        try manager.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = try XCTUnwrap(Bundle.module.url(forResource: "library.db", withExtension: nil, subdirectory: "Fixtures/v15"))
        let sourceKey = try XCTUnwrap(Bundle.module.url(forResource: "library.key", withExtension: nil, subdirectory: "Fixtures/v15"))
        for state in ["fresh", "current"] {
            let root = base.appendingPathComponent(state, isDirectory: true)
            let core = root.appendingPathComponent("core", isDirectory: true)
            try manager.createDirectory(at: core, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let paths = VaultBootstrapPaths(directory: core)
            let keys = MemoryAppKeyStore()
            if state == "current" {
                try manager.copyItem(at: source, to: paths.currentDatabase)
                keys.appKey = try Data(contentsOf: sourceKey)
                let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
                try opened.store.close()
                try writeKey(try keys.loadAppKey(), root: root)
            }
            XCTAssertEqual(try VaultBootstrap.state(paths: paths).rawValue, state)
        }
    }

    private func writeKey(_ key: Data, root: URL) throws {
        let directory = root.appendingPathComponent("key-material", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let service = "com.sudohg.askkey.vault.v2.app.dev.run." + DebugRunDirectory.namespace(for: root)
        let filename = SHA256.hash(data: Data(service.utf8)).map { String(format: "%02x", $0) }.joined() + ".key"
        guard FileManager.default.createFile(atPath: directory.appendingPathComponent(filename).path,
                                            contents: key, attributes: [.posixPermissions: 0o600]) else {
            throw FixtureError.keyWriteFailed
        }
    }

    private enum FixtureError: Error { case destinationAlreadyExists, keyWriteFailed }
}
