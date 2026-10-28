import CryptoKit
import Foundation
import XCTest
@testable import AskKeyVault

extension CurrentLibraryAdoptionTests {
    func assertEmptyAppKeyUpgradePreservesFiles(paths: VaultBootstrapPaths, keys: MemoryAppKeyStore, appKey: Data) throws {
        let before = try directoryBytes(paths.directory)
        let rows = try allDataRows(paths.currentDatabase)
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        XCTAssertEqual(VaultCrypto.keyToData(opened.key), appKey)
        XCTAssertNil(opened.store.componentMetadataIssue)
        try opened.store.close()
        let after = try directoryBytes(paths.directory)
        XCTAssertEqual(try allDataRows(paths.currentDatabase), rows)
        XCTAssertEqual(after.filter { $0.key != "credentials-v2.db" }, before.filter { $0.key != "credentials-v2.db" })
        let repeated = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        try repeated.store.close()
        XCTAssertEqual(try directoryBytes(paths.directory), after)
    }

    func verifyCompletedComponentMetadata(store: VaultStore, key: SymmetricKey, vault: Vault) throws {
        XCTAssertNil(store.componentMetadataIssue)
        let marker = try XCTUnwrap(store.configValue(key: VaultStore.componentMetadataCompletionKey))
        let markerKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(),
            info: Data("AskKey component metadata completion authentication v2".utf8), outputByteCount: 32)
        XCTAssertTrue(HMAC<SHA256>.isValidAuthenticationCode(try XCTUnwrap(Data(base64Encoded: marker)),
            authenticating: Data("AskKey component metadata complete v2\0".utf8), using: markerKey))
        XCTAssertNil(try store.configValue(key: VaultStore.componentMetadataLegacyCompletionKey))
        for record in try store.fetchAllCredentialsIncludingRecycled() {
            XCTAssertEqual(try CredentialComponentMetadata.read(from: record, using: key),
                try CredentialComponentMetadata(components: vault.credentialComponents(from: record, key: key)))
        }
    }
}
