import CryptoKit
import Darwin
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyCore

final class HumanFileCredentialTests: XCTestCase {
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

    func testCreateStoresEncryptedBytesAndLeavesSourceUnchanged() throws {
        let harness = try makeManagedHarness()
        let payload = Data("ssh-ed25519 AAAA fixture-key".utf8)
        let source = harness.directory.appendingPathComponent("id_ed25519")
        try payload.write(to: source)
        let sourceBefore = try Data(contentsOf: source)

        let created = try harness.vault.createFileCredential(
            FileCredentialInput(
                name: "Laptop SSH",
                snapshot: try FileImport.freeze(url: source),
                privateNotes: "do not copy"
            ),
            using: .allow
        )

        XCTAssertEqual(created.payloadKind, .file)
        XCTAssertEqual(created.permission, .ask)
        XCTAssertNil(created.groupName)
        XCTAssertEqual(created.usageInstructions, "")
        XCTAssertNil(created.value)
        XCTAssertNil(created.fileBytes)
        XCTAssertNil(created.originalFilename)
        XCTAssertNil(created.privateNotes)
        XCTAssertEqual(created.byteSize, 28)
        XCTAssertEqual(created.contentDigest, Self.fixtureDigestHex)

        let listed = try harness.vault.listTextCredentials()
        XCTAssertEqual(listed.count, 1)
        XCTAssertNil(listed[0].fileBytes)
        XCTAssertNil(listed[0].originalFilename)

        XCTAssertThrowsError(try harness.vault.revealTextCredential(id: created.id, using: .deny)) { error in
            guard case VaultError.managementAuthenticationRequired = error else {
                return XCTFail("expected reveal confirmation, got \(error)")
            }
        }

        let revealed = try harness.vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(revealed.originalFilename, "id_ed25519")
        XCTAssertEqual(revealed.fileBytes, payload)
        XCTAssertEqual(revealed.privateNotes, "do not copy")
        XCTAssertEqual(revealed.contentDigest, Self.fixtureDigestHex)

        XCTAssertEqual(try Data(contentsOf: source), sourceBefore)
        try harness.store.checkpoint()
        let stored = try harness.databaseBytes()
        XCTAssertFalse(stored.contains(payload), "file bytes must not be stored in plaintext")
        XCTAssertFalse(stored.contains(Data("id_ed25519".utf8)), "original filename must not be stored in plaintext")
        XCTAssertFalse(stored.contains(Data("Laptop SSH".utf8)), "display name must not be stored in plaintext")
        XCTAssertFalse(stored.contains(Data("do not copy".utf8)), "private notes must not be stored in plaintext")
        XCTAssertEqual(try directoryNames(harness.directory), ["id_ed25519", "vault.db", "vault.db-shm", "vault.db-wal"].filter {
            FileManager.default.fileExists(atPath: harness.directory.appendingPathComponent($0).path)
        }.sorted())
    }

    func testFailedCreateDoesNotLeaveStagingPlaintextOrChangeSource() throws {
        let harness = try makeManagedHarness()
        _ = try harness.vault.createTextCredential(
            TextCredentialInput(name: "Laptop SSH", value: "text"),
            using: .allow
        )
        let payload = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
        let source = harness.directory.appendingPathComponent("AuthKey.p8")
        try payload.write(to: source)
        let namesBefore = try directoryNames(harness.directory)
        let sourceBefore = try Data(contentsOf: source)

        XCTAssertThrowsError(
            try harness.vault.createFileCredential(
                FileCredentialInput(name: "Laptop SSH", snapshot: try FileImport.freeze(url: source)),
                using: .allow
            )
        ) { error in
            guard case VaultError.credentialNameConflict = error else {
                return XCTFail("expected name conflict, got \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains("Project"))
            XCTAssertFalse(error.localizedDescription.contains("Environment"))
        }

        XCTAssertEqual(try Data(contentsOf: source), sourceBefore)
        XCTAssertEqual(try directoryNames(harness.directory), namesBefore)
        try harness.store.checkpoint()
        XCTAssertFalse(try harness.databaseBytes().contains(payload))
        XCTAssertEqual(try harness.vault.listTextCredentials().map(\.payloadKind), [.text])
    }

    func testReplaceRequiresConfirmationAndKeepsSourceFilesIntact() throws {
        let harness = try makeManagedHarness()
        let original = Data("ssh-ed25519 AAAA fixture-key".utf8)
        let replacement = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
        let source = harness.directory.appendingPathComponent("id_ed25519")
        let next = harness.directory.appendingPathComponent("AuthKey.p8")
        try original.write(to: source)
        try replacement.write(to: next)

        let created = try harness.vault.createFileCredential(
            FileCredentialInput(name: "Laptop SSH", snapshot: try FileImport.freeze(url: source)),
            using: .allow
        )

        XCTAssertThrowsError(
            try harness.vault.updateFileCredential(
                id: created.id,
                FileCredentialInput(name: "Laptop SSH", snapshot: try FileImport.freeze(url: next)),
                using: .deny
            )
        )

        let updated = try harness.vault.updateFileCredential(
            id: created.id,
            FileCredentialInput(
                name: "Rotated Key",
                snapshot: try FileImport.freeze(url: next),
                usageInstructions: "use with CI",
                groupName: "Work",
                permission: .hidden
            ),
            using: .allow
        )
        XCTAssertEqual(updated.name, "Rotated Key")
        XCTAssertEqual(updated.groupName, "Work")
        XCTAssertEqual(updated.permission, .hidden)
        XCTAssertEqual(updated.byteSize, 5)
        XCTAssertEqual(updated.contentDigest, Self.binaryDigestHex)
        XCTAssertNil(updated.fileBytes)

        let revealed = try harness.vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(revealed.originalFilename, "AuthKey.p8")
        XCTAssertEqual(revealed.fileBytes, replacement)

        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: next), replacement)

        try harness.vault.deleteTextCredential(id: created.id, using: .allow)
        XCTAssertTrue(try harness.vault.listTextCredentials().isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testPersistedDigestIsComputedFromFileBytesNotCallerClaim() throws {
        let harness = try makeManagedHarness()
        let payload = Data("ssh-ed25519 AAAA fixture-key".utf8)
        let source = harness.directory.appendingPathComponent("id_ed25519")
        try payload.write(to: source)
        let frozen = try FileImport.freeze(url: source)
        let lying = FileImport.FrozenFile(
            originalFilename: frozen.originalFilename,
            bytes: frozen.bytes,
            byteSize: 999,
            contentDigest: Data(repeating: 0xAB, count: 32)
        )

        let created = try harness.vault.createFileCredential(
            FileCredentialInput(name: "Laptop SSH", snapshot: lying),
            using: .allow
        )
        XCTAssertEqual(created.byteSize, 28)
        XCTAssertEqual(created.contentDigest, Self.fixtureDigestHex)

        let revealed = try harness.vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(revealed.fileBytes, payload)
        XCTAssertEqual(revealed.contentDigest, Self.fixtureDigestHex)
    }

    func testAgentFileCommitAtomicallyRejectsAStalePreviousDigest() throws {
        let harness = try makeManagedHarness()
        func authorize(_ file: BrokerFrozenFile) throws -> BrokerFrozenFile {
            let ticket = try harness.vault.approvalRequests.submit(.init(operationID: file.operationID,
                credentialID: file.credentialID, targetID: file.targetID,
                operation: file.operation, payloadDigest: file.approvalPayloadDigest), trustedCredentialDeadline: .none)
            _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID,
                capability: ticket.capability, decision: .once)
            return .init(operationID: file.operationID, credentialID: file.credentialID,
                targetID: file.targetID, operation: file.operation, previousDigest: file.previousDigest,
                originalFilename: file.originalFilename, bytes: file.bytes, byteCount: file.byteCount,
                digest: file.digest, approvalRequestID: ticket.requestID, approvalCapability: ticket.capability)
        }
        let source = harness.directory.appendingPathComponent("id_ed25519")
        try Data("ssh-ed25519 AAAA fixture-key".utf8).write(to: source)
        let created = try harness.vault.createFileCredential(
            FileCredentialInput(
                name: "Laptop SSH",
                snapshot: try FileImport.freeze(url: source)
            ),
            using: .allow
        )
        let replacement = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
        let approved = BrokerFrozenFile(
            operationID: "approved-rotation",
            credentialID: created.id,
            targetID: created.id,
            operation: .modify,
            previousDigest: created.contentDigest,
            originalFilename: "AuthKey.p8",
            bytes: replacement,
            byteCount: replacement.count,
            digest: Self.binaryDigestHex
        )
        try harness.vault.commitAgentFileWrite(authorize(approved))

        let staleBytes = Data("stale-replacement".utf8)
        let stale = BrokerFrozenFile(
            operationID: "stale-rotation",
            credentialID: created.id,
            targetID: created.id,
            operation: .modify,
            previousDigest: created.contentDigest,
            originalFilename: "stale.p8",
            bytes: staleBytes,
            byteCount: staleBytes.count,
            digest: "02f9b34e708c0f04f4e122a1b9f07060daf3193a79cbe8224f88454daf742dba"
        )
        XCTAssertThrowsError(try harness.vault.commitAgentFileWrite(authorize(stale))) { error in
            guard case VaultError.credentialChanged = error else {
                return XCTFail("expected credentialChanged, got \(error)")
            }
        }
        let revealed = try harness.vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(revealed.fileBytes, replacement)
        XCTAssertEqual(revealed.contentDigest, Self.binaryDigestHex)
        XCTAssertEqual(revealed.originalFilename, "AuthKey.p8")
    }

    func testCoordinatorPublicCommitUsesVaultConditionalTransaction() throws {
        let harness = try makeManagedHarness()
        let source = harness.directory.appendingPathComponent("id_ed25519")
        try Data("ssh-ed25519 AAAA fixture-key".utf8).write(to: source)
        let created = try harness.vault.createFileCredential(
            FileCredentialInput(
                name: "最终单文件协议",
                snapshot: try FileImport.freeze(url: source)
            ),
            using: .allow
        )
        let staging = harness.directory.appendingPathComponent("agent-write-staging")
        let coordinator = try makeAgentCoordinator(harness, stagingDirectory: staging)
        let replacement = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
        let upload = try coordinator.begin(
            operationID: "integrated-rotation",
            credentialID: created.id,
            targetID: created.id,
            operation: .modify,
            originalFilename: "AuthKey.p8",
            expectedByteCount: replacement.count
        )
        try coordinator.append(
            uploadID: upload.uploadID,
            capability: upload.capability,
            offset: 0,
            bytes: replacement
        )
        let approval = try coordinator.freeze(
            uploadID: upload.uploadID,
            capability: upload.capability
        )
        let pending = try XCTUnwrap(harness.vault.approvalRequests.pendingRequests().first)
        XCTAssertEqual(pending.trustedCredentialName, "最终单文件协议")
        XCTAssertEqual(pending.displayCredentialName, "最终单文件协议")
        XCTAssertNil(pending.request.credentialName)
        XCTAssertEqual(pending.request.credentialID, created.id)
        XCTAssertEqual(pending.request.targetID, created.id)
        let retried = try coordinator.freeze(uploadID: upload.uploadID, capability: upload.capability)
        XCTAssertEqual(retried.requestID, approval.requestID)
        XCTAssertEqual(retried.capability, approval.capability)
        XCTAssertEqual(harness.vault.approvalRequests.pendingRequests().first?.request, pending.request)
        XCTAssertEqual(harness.vault.approvalRequests.pendingRequests().first?.displayCredentialName, "最终单文件协议")
        let summary = try coordinator.summary(requestID: approval.requestID)
        _ = try coordinator.decide(
            requestID: approval.requestID,
            capability: approval.capability,
            decision: .once
        )
        try coordinator.commit(
            requestID: approval.requestID,
            capability: approval.capability,
            expectedDigest: summary.digest
        )

        let revealed = try harness.vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(revealed.fileBytes, replacement)
        XCTAssertEqual(revealed.contentDigest, Self.binaryDigestHex)
        XCTAssertEqual(revealed.originalFilename, "AuthKey.p8")
    }

    func testFileApprovalDisplayNameIgnoresCallerMetadataWithoutChangingBinding() throws {
        let harness = try makeManagedHarness()
        let source = harness.directory.appendingPathComponent("fixture.pem")
        try Data("synthetic-key".utf8).write(to: source)
        let created = try harness.vault.createFileCredential(
            FileCredentialInput(name: "可信文件名称", snapshot: try FileImport.freeze(url: source)),
            using: .allow
        )
        let request = BrokerApprovalOperationRequest(
            operationID: "display-metadata",
            credentialID: created.id,
            targetID: created.id,
            operation: .modify,
            payloadDigest: String(repeating: "a", count: 64),
            credentialName: "caller-display-label"
        )
        let mismatchedTarget = BrokerApprovalOperationRequest(
            operationID: request.operationID, credentialID: created.id,
            targetID: "caller-target-label", operation: .modify,
            payloadDigest: request.payloadDigest, credentialName: request.credentialName
        )
        XCTAssertThrowsError(try harness.vault.submitFileWriteApprovalIfCurrent(
            credentialID: created.id, expectedPreviousDigest: created.contentDigest,
            request: mismatchedTarget
        )) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidRequest)
        }
        XCTAssertTrue(harness.vault.approvalRequests.pendingRequests().isEmpty)
        let ticket = try harness.vault.submitFileWriteApprovalIfCurrent(
            credentialID: created.id, expectedPreviousDigest: created.contentDigest, request: request
        )
        let pending = try XCTUnwrap(harness.vault.approvalRequests.pendingRequests().first)
        XCTAssertEqual(pending.request, request)
        XCTAssertEqual(pending.displayCredentialName, "可信文件名称")
        XCTAssertEqual(try harness.vault.approvalRequests.status(
            requestID: ticket.requestID, capability: ticket.capability, operationRequest: request
        ), .pending)
    }

    func testFileCreateApprovalKeepsTargetName() throws {
        let harness = try makeManagedHarness()
        let request = BrokerApprovalOperationRequest(
            operationID: "create-display-metadata", credentialID: "new-file",
            targetID: "新建文件名称", operation: .create,
            payloadDigest: String(repeating: "b", count: 64)
        )
        _ = try harness.vault.submitFileWriteApprovalIfCurrent(
            credentialID: request.credentialID, expectedPreviousDigest: nil, request: request
        )
        let pending = try XCTUnwrap(harness.vault.approvalRequests.pendingRequests().first)
        XCTAssertNil(pending.trustedCredentialName)
        XCTAssertEqual(pending.displayCredentialName, "新建文件名称")
        XCTAssertEqual(pending.request, request)
    }

    func testDigestReadAndApprovalSubmitBlockAnInterveningMutation() throws {
        let harness = try makeManagedHarness()
        let source = harness.directory.appendingPathComponent("id_ed25519")
        try Data("ssh-ed25519 AAAA fixture-key".utf8).write(to: source)
        let created = try harness.vault.createFileCredential(
            FileCredentialInput(
                name: "Laptop SSH",
                snapshot: try FileImport.freeze(url: source)
            ),
            using: .allow
        )
        let mutationStarted = DispatchSemaphore(value: 0)
        let mutationFinished = DispatchSemaphore(value: 0)
        let vault = FileCredentialVaultBox(harness.vault)
        let replacement = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
        let coordinator = try makeAgentCoordinator(
            harness,
            stagingDirectory: harness.directory.appendingPathComponent("critical-staging"),
            submitFrozenApproval: { credentialID, expectedDigest, request in
                try harness.vault.submitFileWriteApprovalIfCurrent(
                    credentialID: credentialID,
                    expectedPreviousDigest: expectedDigest,
                    request: request,
                    beforeSubmit: {
                        DispatchQueue.global().async {
                            mutationStarted.signal()
                            _ = try? vault.value.updateFileCredential(
                                id: created.id,
                                FileCredentialInput(
                                    name: "Laptop SSH",
                                    snapshot: FileImport.FrozenFile(
                                        originalFilename: "AuthKey.p8",
                                        bytes: replacement,
                                        byteSize: replacement.count,
                                        contentDigest: Data(SHA256.hash(data: replacement))
                                    )
                                ),
                                using: .allow
                            )
                            mutationFinished.signal()
                        }
                        XCTAssertEqual(mutationStarted.wait(timeout: .now() + 1), .success)
                        XCTAssertEqual(mutationFinished.wait(timeout: .now() + 0.1), .timedOut)
                    }
                )
            }
        )
        let uploadBytes = Data("approved-rotation".utf8)
        let upload = try coordinator.begin(
            operationID: "freeze-critical-section",
            credentialID: created.id,
            targetID: created.id,
            operation: .modify,
            originalFilename: "next.p8",
            expectedByteCount: uploadBytes.count
        )
        try coordinator.append(
            uploadID: upload.uploadID,
            capability: upload.capability,
            offset: 0,
            bytes: uploadBytes
        )
        let ticket = try coordinator.freeze(
            uploadID: upload.uploadID,
            capability: upload.capability
        )
        XCTAssertEqual(mutationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            try harness.vault.approvalRequests.status(
                requestID: ticket.requestID,
                capability: ticket.capability
            ),
            .cancelled
        )
    }

    func testCoordinatorPublicCommitCreatesAnAskFileCredential() throws {
        let harness = try makeManagedHarness()
        let coordinator = try makeAgentCoordinator(
            harness,
            stagingDirectory: harness.directory.appendingPathComponent("create-staging")
        )
        let credentialID = UUID().uuidString
        let bytes = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
        let upload = try coordinator.begin(
            operationID: "agent-create-file",
            credentialID: credentialID,
            targetID: "Agent Created File",
            operation: .create,
            originalFilename: "AuthKey.p8",
            expectedByteCount: bytes.count
        )
        try coordinator.append(
            uploadID: upload.uploadID,
            capability: upload.capability,
            offset: 0,
            bytes: bytes
        )
        let approval = try coordinator.freeze(
            uploadID: upload.uploadID,
            capability: upload.capability
        )
        let summary = try coordinator.summary(requestID: approval.requestID)
        _ = try coordinator.decide(
            requestID: approval.requestID,
            capability: approval.capability,
            decision: .once
        )
        try coordinator.commit(
            requestID: approval.requestID,
            capability: approval.capability,
            expectedDigest: summary.digest
        )

        let created = try XCTUnwrap(
            harness.vault.listTextCredentials().first { $0.id == credentialID }
        )
        XCTAssertEqual(created.name, "Agent Created File")
        XCTAssertEqual(created.permission, .ask)
        XCTAssertEqual(created.payloadKind, .file)
        XCTAssertEqual(created.contentDigest, Self.binaryDigestHex)
        let revealed = try harness.vault.revealTextCredential(id: credentialID, using: .allow)
        XCTAssertEqual(revealed.fileBytes, bytes)
        XCTAssertEqual(revealed.originalFilename, "AuthKey.p8")
    }

    func testCreateNameIsBoundToThePersistedDisplayNameBeforeApproval() throws {
        let harness = try makeManagedHarness()
        let coordinator = try makeAgentCoordinator(
            harness,
            stagingDirectory: harness.directory.appendingPathComponent("name-staging")
        )
        let bytes = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
        let credentialID = UUID().uuidString
        let upload = try coordinator.begin(
            operationID: "trimmed-create-name",
            credentialID: credentialID,
            targetID: "  Prod Key  ",
            operation: .create,
            originalFilename: "AuthKey.p8",
            expectedByteCount: bytes.count
        )
        try coordinator.append(
            uploadID: upload.uploadID,
            capability: upload.capability,
            offset: 0,
            bytes: bytes
        )
        let approval = try coordinator.freeze(
            uploadID: upload.uploadID,
            capability: upload.capability
        )
        let summary = try coordinator.summary(requestID: approval.requestID)
        XCTAssertEqual(summary.targetID, "Prod Key")
        _ = try coordinator.decide(
            requestID: approval.requestID,
            capability: approval.capability,
            decision: .once
        )
        try coordinator.commit(
            requestID: approval.requestID,
            capability: approval.capability,
            expectedDigest: summary.digest
        )
        let created = try XCTUnwrap(
            harness.vault.listTextCredentials().first { $0.id == credentialID }
        )
        XCTAssertEqual(created.name, "Prod Key")

        for invalidName in ["   ", "Bad\nName", String(repeating: "x", count: 256)] {
            XCTAssertThrowsError(try coordinator.begin(
                operationID: UUID().uuidString,
                credentialID: UUID().uuidString,
                targetID: invalidName,
                operation: .create,
                originalFilename: "key.bin",
                expectedByteCount: 1
            )) { error in
                guard case VaultError.invalidCredentialName = error else {
                    return XCTFail("expected invalidCredentialName, got \(error)")
                }
            }
        }
    }

    func testRevealFailsClosedWhenDigestDoesNotMatchPayload() throws {
        let harness = try makeManagedHarness()
        let source = harness.directory.appendingPathComponent("id_ed25519")
        try Data("ssh-ed25519 AAAA fixture-key".utf8).write(to: source)
        let created = try harness.vault.createFileCredential(
            FileCredentialInput(name: "Laptop SSH", snapshot: try FileImport.freeze(url: source)),
            using: .allow
        )

        guard var record = try harness.store.fetchCredential(id: created.id) else {
            return XCTFail("missing credential")
        }
        record.contentDigest = Data(repeating: 0xAB, count: 32)
        try harness.store.updateCredential(record)

        XCTAssertThrowsError(try harness.vault.revealTextCredential(id: created.id, using: .allow)) { error in
            guard case VaultError.invalidFileCredential(.digestMismatch) = error else {
                return XCTFail("expected digestMismatch, got \(error)")
            }
        }
    }

    func testManagementCopyKeepsFileVocabularyOnExistingScreens() throws {
        XCTAssertEqual(CredentialManagementCopy.file, "File")
        XCTAssertEqual(CredentialManagementCopy.text, "Text")
        XCTAssertEqual(CredentialManagementCopy.originalFilename, "Original filename")
        XCTAssertEqual(CredentialManagementCopy.fileSize, "Size")
        XCTAssertEqual(CredentialManagementCopy.contentDigest, "Digest")
        XCTAssertEqual(CredentialManagementCopy.chooseFile, "Choose file")
        XCTAssertEqual(CredentialManagementCopy.replaceFile, "Replace file")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for relative in ["Sources/AskKeyApp/Views/CredentialManagementView.swift"] {
            let viewSource = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            XCTAssertTrue(
                viewSource.contains("CredentialManagementCopy.file") || viewSource.contains("\"文件\""),
                "\(relative) should surface the frozen file label"
            )
            XCTAssertTrue(viewSource.contains("Choose file") || viewSource.contains("CredentialManagementCopy.chooseFile") || viewSource.contains("payloadKind"), "\(relative) should surface file credentials")
            XCTAssertFalse(viewSource.contains("Project"), "\(relative) still names Project")
            XCTAssertFalse(viewSource.contains("Environments"), "\(relative) still names Environments")
            XCTAssertFalse(viewSource.localizedCaseInsensitiveContains("strict"), "\(relative) still names strict")
        }
    }

    private static let fixtureDigest = Data(
        hex: "511109c28912a6333efe4acbe933c76d0f692a456e589b0f585e94995f1ab851"
    )
    private static let fixtureDigestHex = "511109c28912a6333efe4acbe933c76d0f692a456e589b0f585e94995f1ab851"
    private static let binaryDigestHex = "ff5d8507b6a72bee2debce2c0054798deaccdc5d8a1b945b6280ce8aa9cba52e"

    private func makeManagedHarness() throws -> VaultHarness {
        let harness = try makeHarness()
        try harness.vault.beginManagementSession(using: .allow)
        return harness
    }

    private func makeAgentCoordinator(
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

    private func makeHarness() throws -> VaultHarness {
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

    private func scratchDirectory(prefix: String = "AskKeyFileImportTests") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func directoryNames(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}

private struct VaultHarness {
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

private final class FileCredentialVaultBox: @unchecked Sendable {
    let value: Vault
    init(_ value: Vault) { self.value = value }
}

private extension VaultStore {
    func checkpoint() throws {
        try db.write { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
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
