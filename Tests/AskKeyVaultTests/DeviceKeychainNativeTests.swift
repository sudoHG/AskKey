import Foundation
import XCTest
@testable import AskKeyVault

/// The device items in a real file keychain (CI only): App-only access, no
/// in-place update, their own conflict kinds, and no effect on the vault key.
final class DeviceKeychainNativeTests: XCTestCase {
    func testNativeDeviceItemsRoundTripWithAppOnlyAccessAndLeaveTheVaultKeyAlone() throws {
        let fixture = try KeychainNativeTestSupport(test: self)
        let keys = try fixture.makeStore()
        let vaultKey = Data(repeating: 0x42, count: 32)
        try keys.savePendingKey(vaultKey)
        try keys.promotePendingKey(expected: vaultKey)

        for account in DeviceKeychainAccount.allCases {
            let value = Data("synthetic-\(account.rawValue)".utf8)
            XCTAssertNil(try keys.loadDeviceItem(account))
            try keys.saveDeviceItem(value, account: account)
            XCTAssertEqual(try keys.loadDeviceItem(account), value)
            try fixture.assertAppOnlyItem(account: account.rawValue)
            try keys.saveDeviceItem(value + Data([1]), account: account)
            XCTAssertEqual(try keys.loadDeviceItem(account), value + Data([1]))
        }
        for account in DeviceKeychainAccount.allCases {
            try keys.deleteDeviceItem(account)
            XCTAssertNil(try keys.loadDeviceItem(account))
        }
        XCTAssertEqual(try keys.loadAppKey(), vaultKey, "no device operation touched the vault key")
        XCTAssertEqual(try keys.loadPendingKey(), vaultKey)
    }

    func testNativePlantedPermissiveDeviceItemIsReplacedNotUpdated() throws {
        let fixture = try KeychainNativeTestSupport(test: self)
        let planted = try fixture.addItem(Data("synthetic-planted".utf8), account: "paired-devices", permissive: true)
        let keys = try fixture.makeStore()
        try keys.saveDeviceItem(Data("synthetic-list".utf8), account: .pairedDevices)
        try fixture.assertOldItemReplaced(planted, account: "paired-devices")
        try fixture.assertAppOnlyItem(account: "paired-devices")
        XCTAssertEqual(try keys.loadDeviceItem(.pairedDevices), Data("synthetic-list".utf8))
    }

    func testNativeDuplicateDeviceItemsRefuseEveryOperationWithTheirOwnKind() throws {
        let fixture = try KeychainNativeTestSupport(test: self)
        for account in DeviceKeychainAccount.allCases {
            _ = try fixture.addItem(Data("synthetic-pinned".utf8), account: account.rawValue)
            _ = try fixture.addItem(Data("synthetic-shadow".utf8), account: account.rawValue, outside: true)
        }
        let keys = try fixture.makeStore()
        for account in DeviceKeychainAccount.allCases {
            let operations: [() throws -> Void] = [
                { _ = try keys.loadDeviceItem(account) },
                { try keys.saveDeviceItem(Data("synthetic-new".utf8), account: account) },
                { try keys.deleteDeviceItem(account) },
            ]
            for operation in operations {
                XCTAssertThrowsError(try operation()) {
                    XCTAssertEqual($0 as? AppKeyStoreError, .conflictingItem(account.itemKind))
                }
            }
        }
    }
}
