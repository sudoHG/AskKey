import CryptoKit
import Darwin
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

class HumanFileCredentialTestSupport: XCTestCase {
    func makeManagedHarness() throws -> VaultHarness {
        let harness = try makeHarness()
        try harness.vault.beginManagementSession(using: .allow)
        return harness
    }
    func makeAgentCoordinator(
        _ harness: VaultHarness,
        stagingDirectory: URL,
        submitFrozenApproval: (@Sendable (
            String, String?, BrokerApprovalOperationRequest
        ) throws -> BrokerApprovalTicket)? = nil
    ) throws -> BrokerFileWriteCoordinator {
        let submit = submitFrozenApproval ?? { credentialID, expectedDigest, request in
            try harness.vault.submitFileWriteApprovalIfCurrent(
                credentialID: credentialID,
                expectedPreviousDigest: expectedDigest,
                request: request
            )
        }
        return try BrokerFileWriteCoordinator(
            stagingDirectory: stagingDirectory,
            approvals: harness.vault.approvalRequests,
            authenticateReveal: { true },
            commitFrozenFile: { try harness.vault.commitAgentFileWrite($0) },
            submitFrozenApproval: submit,
            normalizeCreateTarget: {
                try harness.vault.normalizeAgentCreateCredentialName($0)
            },
            resolvePreviousDigest: {
                try harness.vault.brokerFileContentDigest(credentialID: $0)
            }
        )
    }
    func makeHarness() throws -> VaultHarness {
        let directory = try scratchDirectory(prefix: "AskKeyHumanFileCredentialTests")
        let databaseURL = directory.appendingPathComponent("vault.db")
        let store = try VaultStore(path: databaseURL.path)
        return VaultHarness(
            directory: directory,
            databaseURL: databaseURL,
            store: store,
            vault: Vault(
                store: store,
                key: VaultCrypto.generateKey(),
                approvalRequests: BrokerApprovalStateMachine(authenticate: { _ in true })
            )
        )
    }
    func scratchDirectory(prefix: String = "AskKeyFileImportTests") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    func directoryNames(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
    static let fixtureDigest = Data(
        hex: "511109c28912a6333efe4acbe933c76d0f692a456e589b0f585e94995f1ab851"
    )
    static let fixtureDigestHex = "511109c28912a6333efe4acbe933c76d0f692a456e589b0f585e94995f1ab851"
    static let binaryDigestHex = "ff5d8507b6a72bee2debce2c0054798deaccdc5d8a1b945b6280ce8aa9cba52e"
    struct VaultHarness {
        let directory: URL
        let databaseURL: URL
        let store: VaultStore
        let vault: Vault

        func databaseBytes() throws -> Data {
            var combined = Data()
            for suffix in ["", "-wal", "-shm"] {
                let url = URL(fileURLWithPath: databaseURL.path + suffix)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                combined.append(try Data(contentsOf: url))
            }
            return combined
        }
    }
    final class FileCredentialVaultBox: @unchecked Sendable {
        let value: Vault
        init(_ value: Vault) { self.value = value }
    }
}

private extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(String(hex[index..<next]), radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
