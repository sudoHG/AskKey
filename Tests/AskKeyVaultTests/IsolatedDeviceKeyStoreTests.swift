import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
@testable import AskKeyVault

/// Isolated Debug runs keep the device items as owner-only files beside the
/// other synthetic key material.
final class IsolatedDeviceKeyStoreTests: AskKeyCoreTestCase {
#if DEBUG
    func testIsolatedRunStoresEachDeviceItemSeparatelyFromThePolicy() throws {
        let candidate = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyIsolatedDevices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: candidate) }
        let root = try physicalTestDirectory(candidate)
        let environment = AskKeyTestEnvironment(overrides: ["ASKKEY_DEBUG_RUN_DIRECTORY": root.path])
        defer { environment.restore() }
        let keys = try IsolatedAppKeyStore(directory: root, legacyService: "synthetic.legacy",
                                           pendingService: "synthetic.pending", appService: "synthetic.app")

        try keys.saveAgentAccessPolicy(Data("synthetic-policy".utf8))
        for account in DeviceKeychainAccount.allCases {
            XCTAssertNil(try keys.loadDeviceItem(account))
            try keys.saveDeviceItem(Data("synthetic-\(account.rawValue)".utf8), account: account)
        }
        for account in DeviceKeychainAccount.allCases {
            XCTAssertEqual(try keys.loadDeviceItem(account), Data("synthetic-\(account.rawValue)".utf8))
        }
        XCTAssertEqual(try keys.loadAgentAccessPolicy(), Data("synthetic-policy".utf8))
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("key-material"),
                                                                includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 5)
        for file in files {
            let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
            XCTAssertEqual(mode, 0o600)
        }
        XCTAssertThrowsError(try keys.saveDeviceItem(Data(count: 65_537), account: .pairedDevices))

        try keys.saveDeviceItem(Data("synthetic-replacement".utf8), account: .pairedDevices)
        XCTAssertEqual(try keys.loadDeviceItem(.pairedDevices), Data("synthetic-replacement".utf8))
        for account in DeviceKeychainAccount.allCases { try keys.deleteDeviceItem(account) }
        for account in DeviceKeychainAccount.allCases { XCTAssertNil(try keys.loadDeviceItem(account)) }
        XCTAssertEqual(try keys.loadAgentAccessPolicy(), Data("synthetic-policy".utf8))
    }
#endif
}
