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
        XCTAssertEqual(try VaultCrypto.decrypt(XCTUnwrap(Data(base64Encoded: marker)), using: key), "AskKey component metadata complete v1")
        for record in try store.fetchAllCredentialsIncludingRecycled() {
            XCTAssertEqual(try CredentialComponentMetadata.read(from: record, using: key),
                try CredentialComponentMetadata(components: vault.credentialComponents(from: record, key: key)))
        }
    }
}
