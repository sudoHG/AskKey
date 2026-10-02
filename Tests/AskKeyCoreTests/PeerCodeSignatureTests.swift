import XCTest
@testable import AskKeyCore

final class PeerCodeSignatureTests: XCTestCase {
    private func makeVault() throws -> Vault {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(path: directory.appendingPathComponent("vault.db").path)
        return Vault(store: store, key: VaultCrypto.generateKey())
    }

    func testLogAccessRoundTripsPeerTeam() throws {
        let vault = try makeVault()
        vault.logAccess(secretName: "K", projectName: "App", environmentName: "prod", source: .mcp, agent: "claude", peerTeamID: "67S22M7P3P", action: .read)
        vault.logAccess(secretName: "K", projectName: "App", environmentName: "prod", source: .app)

        let entries = try vault.listActivity()
        XCTAssertEqual(entries.first { $0.source == .mcp }?.peerTeamID, "67S22M7P3P")
        // App-local reads carry no peer signature.
        XCTAssertNil(entries.first { $0.source == .app }?.peerTeamID)
    }
}
