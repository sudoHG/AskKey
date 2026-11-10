import AskKeyDevices
import AskKeyDevicesTestSupport
import CryptoKit
import Foundation
import XCTest
@testable import AskKeyVault

/// The Mac's device identity and paired-device list in the Vault (ADR 0013),
/// on a real temporary library with an in-memory key store.
final class DeviceStorageTests: XCTestCase {
    private var libraries: [AgentAccessPolicyLibrary] = []

    override func tearDownWithError() throws {
        for library in libraries { try library.close() }
        libraries = []
    }

    private func makeLibrary() throws -> AgentAccessPolicyLibrary {
        let library = try AgentAccessPolicyLibrary()
        libraries.append(library)
        try library.vault.beginManagementSession(using: .allow)
        return library
    }

    private func syntheticBlobs() -> DeviceIdentityKeyBlobs {
        DeviceIdentityKeyBlobs(message: Data("synthetic-message-blob".utf8), agreement: Data("synthetic-agreement-blob".utf8),
                               approval: Data("synthetic-approval-blob".utf8))
    }

    private func syntheticDevice(name: String = "Synthetic Phone") throws -> PairedDevice {
        let card = try DeviceCard.make(identity: SoftwareDeviceIdentity(), platform: .iOS,
                                       createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let pairingID = try XCTUnwrap(PairingID(rawValue: Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })))
        return PairedDevice(card: card, pairingID: pairingID, displayName: name,
                            pairedAt: Date(timeIntervalSince1970: 1_800_000_100))
    }

    /// Adds a device the way pairing does: the person's authorization, then one list change.
    private func add(_ device: PairedDevice, to library: AgentAccessPolicyLibrary) async throws {
        try library.vault.authorizeDevicePairing(with: device.deviceID, using: .allow)
        try await library.vault.pairedDeviceRegistry().apply(.add(device))
    }

    func testIdentityAndListRoundTripAcrossReopening() async throws {
        let library = try makeLibrary()
        XCTAssertNil(try library.vault.storedDeviceIdentityKeyBlobs(), "a Mac that never paired has no identity")
        XCTAssertTrue(library.keys.deviceItems.isEmpty)
        try library.vault.saveDeviceIdentityKeyBlobs(syntheticBlobs())
        let device = try syntheticDevice()
        try await add(device, to: library)

        XCTAssertEqual(Set(library.keys.deviceItems.keys),
                       [.messageKey, .agreementKey, .approvalKey, .pairedDevices])
        library.vault.endManagementSession()
        try library.reopen()
        // Reading needs no management session: messages are verified in the background.
        XCTAssertEqual(try library.vault.storedDeviceIdentityKeyBlobs(), syntheticBlobs())
        let list = try await library.vault.pairedDeviceRegistry().list()
        XCTAssertEqual(list.devices, [device])
    }

    func testListItemIsTheSerializationFollowedByItsTagOverTheExactBytes() async throws {
        let library = try makeLibrary()
        try library.vault.saveDeviceIdentityKeyBlobs(syntheticBlobs())
        try await add(try syntheticDevice(), to: library)
        let item = try XCTUnwrap(library.keys.deviceItems[.pairedDevices])
        let bytes = item.prefix(item.count - 32)
        // Labels written out byte by byte, independently of the implementation.
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: try library.key, salt: Data(),
                                         info: Data("AskKey paired devices key v1".utf8) + Data([0]),
                                         outputByteCount: 32)
        let expected = HMAC<SHA256>.authenticationCode(
            for: Data("AskKey paired devices v1".utf8) + Data([0]) + bytes, using: key)
        XCTAssertEqual(Data(item.suffix(32)), Data(expected))
        let stored = try await library.vault.pairedDeviceRegistry().list()
        XCTAssertEqual(try PairedDeviceList(serialized: Data(bytes)), stored)
    }

    func testTamperedOrReencodedListIsRefusedAndNotRepaired() async throws {
        let library = try makeLibrary()
        try library.vault.saveDeviceIdentityKeyBlobs(syntheticBlobs())
        try await add(try syntheticDevice(), to: library)
        let registry = try library.vault.pairedDeviceRegistry()
        let original = try XCTUnwrap(library.keys.deviceItems[.pairedDevices])

        var flipped = original
        flipped[flipped.startIndex + 10] ^= 0x01
        let bytes = original.prefix(original.count - 32)
        let object = try JSONSerialization.jsonObject(with: bytes)
        // The same list, encoded with other whitespace, keeps the old tag.
        let reencoded = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) + original.suffix(32)
        let otherKeyTag = Data(HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(size: .bits256)))
        for stored in [flipped, reencoded, Data(bytes) + otherKeyTag, Data(original.prefix(31))] {
            library.keys.deviceItems[.pairedDevices] = stored
            do {
                _ = try await registry.list()
                XCTFail("a list that fails authentication is refused")
            } catch {
                XCTAssertEqual(error as? DeviceStorageError, .listRefused)
            }
            do {
                try await registry.apply(.add(try syntheticDevice()))
                XCTFail("a refused list is not overwritten")
            } catch {
                XCTAssertEqual(error as? DeviceStorageError, .listRefused)
            }
            XCTAssertEqual(library.keys.deviceItems[.pairedDevices], stored, "nothing repairs the item")
        }
    }

    func testAddingNeedsTheManagementSessionAndThisSessionsAuthorization() async throws {
        let library = try makeLibrary()
        let vault = library.vault
        try vault.saveDeviceIdentityKeyBlobs(syntheticBlobs())
        let registry = try vault.pairedDeviceRegistry()
        let device = try syntheticDevice()

        await assertRefused(try await registry.apply(.add(device)), .pairingNotAuthorized, "no authorization")
        XCTAssertThrowsError(try vault.authorizeDevicePairing(with: device.deviceID, using: .deny),
                             "a cancelled authentication authorizes nothing")
        await assertRefused(try await registry.apply(.add(device)), .pairingNotAuthorized, "after a cancelled authentication")
        try vault.authorizeDevicePairing(with: try syntheticDevice().deviceID, using: .allow)
        await assertRefused(try await registry.apply(.add(device)), .pairingNotAuthorized, "authorized for another device")
        XCTAssertNil(library.keys.deviceItems[.pairedDevices], "nothing was stored")

        try vault.authorizeDevicePairing(with: device.deviceID, using: .allow)
        vault.endManagementSession()
        do {
            try await registry.apply(.add(device))
            XCTFail("an authorization does not outlive the management session")
        } catch VaultError.managementAuthenticationRequired {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertThrowsError(try vault.authorizeDevicePairing(with: device.deviceID, using: .allow),
                             "authorizing needs the management session")
        XCTAssertNil(library.keys.deviceItems[.pairedDevices])

        try vault.beginManagementSession(using: .allow)
        try vault.authorizeDevicePairing(with: device.deviceID, using: .allow)
        try await registry.apply(.add(device))
        let second = try syntheticDevice(name: "Synthetic Second Phone")
        await assertRefused(try await registry.apply(.add(second)), .pairingNotAuthorized, "the authorization is used up")
        // Pairing again replaces the entry and its pairing ID; that is an add too.
        let repaired = PairedDevice(card: device.card, pairingID: second.pairingID, displayName: "Synthetic Phone",
                                    pairedAt: device.pairedAt)
        await assertRefused(try await registry.apply(.add(repaired)), .pairingNotAuthorized, "re-pairing")

        // Renaming, delivery records and removal change no trust upward.
        vault.endManagementSession()
        try await registry.apply(.rename(device.deviceID, pairingID: device.pairingID, displayName: "Renamed Phone"))
        try await registry.apply(.recordReached(device.deviceID, pairingID: device.pairingID, at: Date()))
        let renamed = try await registry.list().devices.first?.displayName
        XCTAssertEqual(renamed, "Renamed Phone")
        let removal = try await registry.apply(.remove(device.deviceID, pairingID: device.pairingID))
        XCTAssertEqual(removal, .applied)
        let remaining = try await registry.list().devices
        XCTAssertTrue(remaining.isEmpty)
    }

    func testListChangePreparedBeforeARemovalDoesNotRestoreTheDevice() async throws {
        let library = try makeLibrary()
        try library.vault.saveDeviceIdentityKeyBlobs(syntheticBlobs())
        let device = try syntheticDevice()
        try await add(device, to: library)
        let registry = try library.vault.pairedDeviceRegistry()
        try await registry.apply(.remove(device.deviceID, pairingID: device.pairingID))
        let rename = try await registry.apply(.rename(device.deviceID, pairingID: device.pairingID, displayName: "Late"))
        XCTAssertEqual(rename, .dropped)
        let reached = try await registry.apply(.recordReached(device.deviceID, pairingID: device.pairingID, at: Date()))
        XCTAssertEqual(reached, .dropped)
        let remaining = try await registry.list().devices
        XCTAssertTrue(remaining.isEmpty)
    }

    func testIdentityIsNeverReplacedAndAPartialIdentityIsUnusable() throws {
        let library = try makeLibrary()
        try library.vault.saveDeviceIdentityKeyBlobs(syntheticBlobs())
        XCTAssertThrowsError(try library.vault.saveDeviceIdentityKeyBlobs(syntheticBlobs())) {
            XCTAssertEqual($0 as? DeviceStorageError, .identityExists)
        }
        library.keys.deviceItems[.approvalKey] = nil
        XCTAssertThrowsError(try library.vault.storedDeviceIdentityKeyBlobs()) {
            XCTAssertEqual($0 as? DeviceStorageError, .incompleteIdentity)
        }
        library.vault.endManagementSession()
        XCTAssertThrowsError(try library.vault.resetDeviceIdentity(), "resetting needs the management session")
    }

    func testCreatingAnIdentityNeedsTheManagementSessionAndDropsAListWithoutIdentity() throws {
        let library = try makeLibrary()
        library.keys.deviceItems[.pairedDevices] = Data("synthetic-stale-list".utf8)
        library.vault.endManagementSession()
        XCTAssertThrowsError(try library.vault.saveDeviceIdentityKeyBlobs(syntheticBlobs()))
        XCTAssertNil(try library.vault.storedDeviceIdentityKeyBlobs())
        try library.vault.beginManagementSession(using: .allow)
        try library.vault.saveDeviceIdentityKeyBlobs(syntheticBlobs())
        XCTAssertNil(library.keys.deviceItems[.pairedDevices])
    }

    func testResetDeletesKeysListAndInboxStateAndClosesTheOldRegistry() async throws {
        let library = try makeLibrary()
        try library.vault.saveDeviceIdentityKeyBlobs(syntheticBlobs())
        let device = try syntheticDevice()
        try await add(device, to: library)
        try library.vault.saveDeviceInboxState(DeviceInboxState(listAccount: "_synthetic-account", inboxToken: Data([1])))
        let old = try library.vault.pairedDeviceRegistry()

        try library.vault.resetDeviceIdentity()

        XCTAssertTrue(library.keys.deviceItems.isEmpty)
        XCTAssertEqual(try library.vault.loadDeviceInboxState(), DeviceInboxState())
        do {
            _ = try await old.apply(.rename(device.deviceID, pairingID: device.pairingID, displayName: "Late"))
            XCTFail("a registry from before the reset writes nothing")
        } catch {
            XCTAssertEqual(error as? DeviceStorageError, .servicesStopped)
        }
        XCTAssertTrue(library.keys.deviceItems.isEmpty)
        XCTAssertFalse(old === (try library.vault.pairedDeviceRegistry()))
    }

    func testNoDeviceOperationReadsWritesOrDeletesTheVaultKeyItem() async throws {
        let library = try makeLibrary()
        let mutations = library.keys.mutations
        let policyWrites = library.keys.policyWrites
        library.keys.appLoadFailure = SyntheticPolicyFailure()

        try library.vault.saveDeviceIdentityKeyBlobs(syntheticBlobs())
        _ = try library.vault.storedDeviceIdentityKeyBlobs()
        let device = try syntheticDevice()
        try await add(device, to: library)
        let registry = try library.vault.pairedDeviceRegistry()
        _ = try await registry.list()
        try await registry.apply(.remove(device.deviceID, pairingID: device.pairingID))
        try library.vault.saveDeviceInboxState(DeviceInboxState(listAccount: "_synthetic-account"))
        _ = try library.vault.loadDeviceInboxState()
        try library.vault.resetDeviceIdentity()

        XCTAssertEqual(library.keys.mutations, mutations, "the vault-key items were not written or deleted")
        XCTAssertEqual(library.keys.policyWrites, policyWrites)
        XCTAssertNotNil(library.keys.appKey)
    }

    func testLocalEraseStopsDeviceServicesFirstThenRemovesAllFourItems() async throws {
        let library = try makeLibrary()
        try library.vault.saveDeviceIdentityKeyBlobs(syntheticBlobs())
        let device = try syntheticDevice()
        try await add(device, to: library)
        try library.vault.saveDeviceInboxState(DeviceInboxState(listAccount: "_synthetic-account"))
        let registry = try library.vault.pairedDeviceRegistry()
        let keys = library.keys
        let itemsWhenStopped = LockedCount()
        library.vault.setDeviceServicesStopHandler {
            itemsWhenStopped.set(keys.deviceItems.count)
        }

        try library.vault.eraseLocalLibrary(confirmation: LocalVaultEraseLanguage.english.confirmationText,
                                            language: .english, using: .allow)

        XCTAssertEqual(itemsWhenStopped.value, 4, "the services stop before anything is deleted")
        XCTAssertTrue(library.keys.deviceItems.isEmpty, "the keys and the list are gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.paths.directory.path))
        do {
            try await registry.apply(.rename(device.deviceID, pairingID: device.pairingID, displayName: "Late"))
            XCTFail("a list change that started before the erase writes nothing afterwards")
        } catch {}
        XCTAssertTrue(library.keys.deviceItems.isEmpty)
    }

    func testAnInterruptedEraseKeepsDeviceStorageClosedUntilItFinishes() async throws {
        let library = try makeLibrary()
        try library.vault.saveDeviceIdentityKeyBlobs(syntheticBlobs())
        let journal = FileLocalVaultEraseJournalStore(url: library.vault.localEraseJournalURL)
        try journal.save(.operationsQuiesced)
        XCTAssertThrowsError(try library.vault.storedDeviceIdentityKeyBlobs()) {
            XCTAssertEqual($0 as? DeviceStorageError, .eraseInProgress)
        }
        XCTAssertThrowsError(try library.vault.pairedDeviceRegistry())
        try journal.clear()
        XCTAssertEqual(try library.vault.storedDeviceIdentityKeyBlobs(), syntheticBlobs())
    }

    func testBackupExportContainsNoDeviceItem() async throws {
        let library = try makeLibrary()
        try SyntheticBackupLibrary.populate(library.vault)
        try library.vault.saveDeviceIdentityKeyBlobs(syntheticBlobs())
        let device = try syntheticDevice(name: "Synthetic Backup Phone")
        try await add(device, to: library)
        try library.vault.saveDeviceInboxState(DeviceInboxState(listAccount: "_synthetic-account-name"))

        let export = try library.vault.exportBackup(using: .allow)
        let document = try BackupFileForge.document(of: export)
        XCTAssertEqual(Set(document.keys), ["createdAt", "appVersion", "groups", "credentials"])
        let plaintext = String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
        for marker in ["Synthetic Backup Phone", "synthetic-message-blob", "_synthetic-account-name",
                       device.card.bytes.base64EncodedString(), device.pairingID.rawValue.base64EncodedString()] {
            XCTAssertFalse(plaintext.contains(marker), "the backup carries no device data: \(marker)")
        }
    }

    func testDeviceItemConflictsNameTheirItemAndTheManualRecovery() {
        XCTAssertEqual(Set(DeviceKeychainAccount.allCases.map(\.rawValue)),
                       ["device-message-key", "device-agreement-key", "device-approval-key", "paired-devices"])
        for account in DeviceKeychainAccount.allCases {
            let message = account.itemKind.conflictMessage
            XCTAssertEqual(AppKeyStoreError.conflictingItem(account.itemKind).errorDescription, message)
            for fragment in [account.rawValue, "login.keychain-db", "Keychain Access", "Do not remove vault-key items"] {
                XCTAssertTrue(message.contains(fragment), "\(account): \(fragment)")
            }
        }
    }

    private func assertRefused(_ expression: @autoclosure () async throws -> PairedDeviceChangeOutcome,
                               _ expected: DeviceStorageError, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await expression()
            XCTFail("expected \(expected): \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? DeviceStorageError, expected, message, file: file, line: line)
        }
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?
    var value: Int? { lock.withLock { stored } }
    func set(_ value: Int) { lock.withLock { stored = value } }
}
