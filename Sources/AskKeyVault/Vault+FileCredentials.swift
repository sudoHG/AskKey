import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    /// App-internal approval context. The digest is never returned on the Agent
    /// protocol and is derived from the current non-hidden file record.
    public func brokerFileContentDigest(
        credentialID: String,
        now: Date = Date()
    ) throws -> String {
        try agentAccessGate.beginAgentOperation()
        defer { agentAccessGate.endAgentOperation() }
        return try currentFileContentDigest(credentialID: credentialID, now: now)
    }

    public func normalizeAgentCreateCredentialName(_ raw: String) throws -> String {
        try CredentialName.displayName(from: raw)
    }

    /// Reads the current target and creates its approval while holding one Agent
    /// operation lease. Credential mutations wait for that lease, then cancel the
    /// newly-created request instead of slipping between the read and submit.
    public func submitFileWriteApprovalIfCurrent(
        credentialID: String,
        expectedPreviousDigest: String?,
        request: BrokerApprovalOperationRequest
    ) throws -> BrokerApprovalTicket {
        try submitFileWriteApprovalIfCurrent(
            credentialID: credentialID,
            expectedPreviousDigest: expectedPreviousDigest,
            request: request,
            beforeSubmit: {}
        )
    }

    /// Test seam for a mutation attempt in the exact digest-return → submit window.
    func submitFileWriteApprovalIfCurrent(
        credentialID: String,
        expectedPreviousDigest: String?,
        request: BrokerApprovalOperationRequest,
        beforeSubmit: () throws -> Void
    ) throws -> BrokerApprovalTicket {
        try agentAccessGate.beginAgentOperation()
        defer { agentAccessGate.endAgentOperation() }
        guard request.credentialID == credentialID else {
            throw BrokerApprovalError.invalidRequest
        }
        let currentDigest: String?
        let trustedCredentialName: String?
        switch request.operation {
        case .modify:
            currentDigest = try currentFileContentDigest(credentialID: credentialID, now: Date())
            // The access gate keeps this authenticated record and digest stable
            // through submission. Caller target IDs are never display names.
            let key = try requireKey()
            guard let record = try store.fetchCredential(id: credentialID) else {
                throw VaultError.credentialUnavailable
            }
            trustedCredentialName = try VaultCrypto.decrypt(record.encryptedDisplayName, using: key)
        case .create:
            currentDigest = nil
            trustedCredentialName = nil
        default:
            throw BrokerApprovalError.invalidRequest
        }
        guard try equalDigest(currentDigest, expectedPreviousDigest) else {
            throw BrokerFileWriteError.targetChanged
        }
        try beforeSubmit()
        return try approvalRequests.submit(
            request,
            trustedCredentialDeadline: .none,
            trustedCredentialName: trustedCredentialName
        )
    }

    private func currentFileContentDigest(
        credentialID: String,
        now: Date
    ) throws -> String {
        guard let record = try store.fetchCredential(id: credentialID),
              record.permission != CredentialPermission.hidden.rawValue,
              record.payloadKind == CredentialPayloadKind.file.rawValue,
              let digest = record.contentDigest else {
            throw VaultError.credentialUnavailable
        }
        if let expiresAt = try record.expiresAt.map({ try parseExpiry($0) }), expiresAt <= now {
            throw VaultError.credentialUnavailable
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns only completion, never material. The persisted receipt is bound
    /// to its exact approval capability and frozen result digest, even if the
    /// credential was subsequently edited or deleted.
    public func completedAgentFileWrite(requestID: String, capability: String, expectedDigest: String) throws -> Bool {
        _ = try digestData(expectedDigest)
        guard let receipt = try validatedAgentFileWriteReceipt(requestID: requestID, capability: capability) else {
            return false
        }
        guard receipt.resultDigest == expectedDigest else { throw BrokerApprovalError.requestNotFound }
        return true
    }

    public func committedAgentFileWriteStatus(requestID: String, capability: String) throws -> BrokerRequestState? {
        try validatedAgentFileWriteReceipt(requestID: requestID, capability: capability) == nil ? nil : .completed
    }

    private func validatedAgentFileWriteReceipt(requestID: String, capability: String) throws -> AgentWriteOperationRecord? {
        guard !requestID.isEmpty, !capability.isEmpty,
              requestID.utf8.count <= BrokerLimits.maximumFieldBytes,
              capability.utf8.count <= BrokerLimits.maximumFieldBytes else {
            throw BrokerApprovalError.invalidRequest
        }
        _ = try requireKey()
        guard let receipt = try store.fetchAgentFileWriteReceipt(requestID: requestID),
              receipt.resultDigest != nil else { return nil }
        guard receipt.capabilityDigest == fileWriteCapabilityDigest(capability),
              receipt.operation == BrokerApprovalOperation.create.rawValue
                || receipt.operation == BrokerApprovalOperation.modify.rawValue else {
            throw BrokerApprovalError.requestNotFound
        }
        return receipt
    }

    /// Commits legacy file create/rotation through the same transaction ledger
    /// as component/text writes. An approval binding is mandatory for new work;
    /// an exact committed replay does not need a surviving in-memory approval.
    public func commitAgentFileWrite(_ frozen: BrokerFrozenFile) throws {
        let accessOperation: CredentialAccessEvent.Operation
        switch frozen.operation {
        case .create: accessOperation = .create
        case .modify: accessOperation = .modify
        default: throw BrokerApprovalError.invalidRequest
        }
        guard let requestID = frozen.approvalRequestID, !requestID.isEmpty,
              let capability = frozen.approvalCapability, !capability.isEmpty else {
            throw BrokerApprovalError.invalidRequest
        }
        var succeeded = false
        defer {
            recordCredentialAccess(.init(timestamp: currentDate, credentialID: frozen.credentialID,
                operation: accessOperation, result: succeeded ? .allowed : .failed,
                callerHint: nil, declaredPurpose: nil))
        }
        guard frozen.byteCount == frozen.bytes.count else {
            throw VaultError.invalidFileCredential(.digestMismatch)
        }
        let contentDigest = Data(SHA256.hash(data: frozen.bytes))
        guard contentDigest == (try digestData(frozen.digest)) else {
            throw VaultError.invalidFileCredential(.digestMismatch)
        }
        let deliveryManager = try fileDeliveryManager.get()
        let wasPaused = try agentAccessGate.beginExclusiveAgentChange()
        defer { agentAccessGate.endExclusiveChange(paused: wasPaused) }
        let digest = frozen.approvalPayloadDigest
        let capabilityDigest = fileWriteCapabilityDigest(capability)
        if let receipt = try store.fetchAgentWriteOperation(operationID: frozen.operationID) {
            guard receipt.payloadDigest == digest, receipt.credentialId == frozen.credentialID,
                  receipt.operation == frozen.operation.rawValue, receipt.resultDigest == frozen.digest else {
                throw BrokerApprovalError.payloadMismatch
            }
            guard receipt.requestId == requestID, receipt.capabilityDigest == capabilityDigest else {
                throw BrokerApprovalError.requestNotFound
            }
            succeeded = true
            return
        }
        let approval = BrokerApprovalOperationRequest(operationID: frozen.operationID,
            credentialID: frozen.credentialID, targetID: frozen.targetID,
            operation: frozen.operation, payloadDigest: digest)
        guard try approvalRequests.status(requestID: requestID, capability: capability,
            operationRequest: approval) == .approved else { throw BrokerApprovalError.invalidDecision }
        let key = try requireKey()
        let mutation: FrozenAgentTextMutation
        let expectedFileDigest: Data?
        switch frozen.operation {
        case .create:
            guard frozen.previousDigest == nil else { throw VaultError.credentialChanged }
            let prepared = try preparedFileRecord(from: .init(name: frozen.targetID,
                snapshot: FileImport.FrozenFile(originalFilename: frozen.originalFilename,
                    bytes: frozen.bytes, byteSize: frozen.byteCount, contentDigest: contentDigest),
                permission: .ask), id: frozen.credentialID, key: key, existing: nil)
            mutation = .create(prepared)
            expectedFileDigest = nil
        case .modify:
            guard frozen.targetID == frozen.credentialID, let previousDigest = frozen.previousDigest,
                  let existing = try store.fetchCredential(id: frozen.credentialID),
                  existing.payloadKind == CredentialPayloadKind.file.rawValue,
                  existing.permission != CredentialPermission.hidden.rawValue else {
                throw VaultError.credentialChanged
            }
            expectedFileDigest = try digestData(previousDigest)
            guard existing.contentDigest == expectedFileDigest else { throw VaultError.credentialChanged }
            var updated = existing
            updated.encryptedPayload = try VaultCrypto.encrypt(frozen.bytes, using: key)
            updated.encryptedOriginalFilename = try VaultCrypto.encrypt(frozen.originalFilename, using: key)
            updated.byteSize = frozen.byteCount
            updated.contentDigest = contentDigest
            updated.updatedAt = sharedDateFormatter.string(from: currentDate)
            mutation = .modify(updated, expectedUpdatedAt: existing.updatedAt)
        default: throw BrokerApprovalError.invalidRequest
        }
        let write = FrozenAgentTextWrite(operationID: frozen.operationID, digest: digest,
            approvalRequest: approval, credentialExpiresAt: nil, mutation: mutation)
        _ = try store.commitAgentTextWrite(write, requestID: requestID, capabilityDigest: capabilityDigest,
            clock: { currentDate }, resultDigest: frozen.digest, expectedFileDigest: expectedFileDigest)
        brokerRequests.cancelPending(credentialID: frozen.credentialID)
        approvalRequests.cancelPending(credentialID: frozen.credentialID)
        deliveryManager.revoke(credentialID: frozen.credentialID)
        succeeded = true
        notifySnapshotRelevantChange()
    }

    private func fileWriteCapabilityDigest(_ capability: String) -> String {
        SHA256.hash(data: Data(capability.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func createFileCredential(
        _ input: FileCredentialInput,
        using authenticator: ManagementAuthenticator
    ) throws -> ManagedTextCredential {
        return try performCredentialCreation(using: authenticator) {
        let key = try requireKey()
        let prepared = try preparedFileRecord(from: input, id: UUID().uuidString, key: key, existing: nil)
        try store.insertCredential(prepared)
        return try managedCredential(from: prepared, key: key, includeSecrets: false)
        }
    }

    public func updateFileCredential(
        id: String,
        _ input: FileCredentialInput,
        using authenticator: ManagementAuthenticator
    ) throws -> ManagedTextCredential {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        let key = try requireKey()
        let prepared = try performCredentialMutation(id: id) {
            guard let existing = try store.fetchCredential(id: id) else {
                throw VaultError.credentialNotFound(id)
            }
            let prepared = try preparedFileRecord(from: input, id: existing.id, key: key, existing: existing)
            try store.updateCredential(prepared)
            return prepared
        }
        return try managedCredential(from: prepared, key: key, includeSecrets: false)
    }

    private func preparedFileRecord(
        from input: FileCredentialInput,
        id: String,
        key: SymmetricKey,
        existing: CredentialRecord?
    ) throws -> CredentialRecord {
        let displayName = try CredentialName.displayName(from: input.name)
        let nameIndex = CredentialIndex.hash(
            normalizedName: CredentialName.normalized(displayName),
            vaultKey: key
        )
        if let conflict = try store.fetchCredentialIncludingRecycled(nameIndex: nameIndex), conflict.id != id {
            throw VaultError.credentialNameConflict(displayName)
        }
        let snapshot = input.snapshot
        let encryptedPayload: Data
        let encryptedOriginalFilename: Data
        let byteSize: Int
        let contentDigest: Data
        if let snapshot {
            encryptedPayload = try VaultCrypto.encrypt(snapshot.bytes, using: key)
            encryptedOriginalFilename = try VaultCrypto.encrypt(snapshot.originalFilename, using: key)
            byteSize = snapshot.bytes.count
            contentDigest = Data(SHA256.hash(data: snapshot.bytes))
        } else if let existing,
                  let existingFilename = existing.encryptedOriginalFilename,
                  let existingSize = existing.byteSize,
                  let existingDigest = existing.contentDigest {
            encryptedPayload = existing.encryptedPayload
            encryptedOriginalFilename = existingFilename
            byteSize = existingSize
            contentDigest = existingDigest
        } else {
            throw VaultError.invalidFileCredential(.missingFile)
        }
        let group = try CredentialName.optionalDisplayName(input.groupName)
        try CredentialFieldValidation.usageInstructions(input.usageInstructions)
        let environmentVariable = try optionalEnvironmentVariable(input.environmentVariable)
        let now = sharedDateFormatter.string(from: currentDate)
        return CredentialRecord(
            id: id,
            nameIndex: nameIndex,
            encryptedDisplayName: try VaultCrypto.encrypt(displayName, using: key),
            encryptedPayload: encryptedPayload,
            encryptedUsageInstructions: try VaultCrypto.encrypt(input.usageInstructions, using: key),
            encryptedPrivateNotes: try VaultCrypto.encrypt(input.privateNotes, using: key),
            encryptedGroupName: try group.map { try VaultCrypto.encrypt($0, using: key) },
            encryptedEnvironmentVariable: try environmentVariable.map { try VaultCrypto.encrypt($0, using: key) },
            payloadKind: CredentialPayloadKind.file.rawValue,
            permission: input.permission.rawValue,
            expiresAt: input.expiresAt.map { sharedDateFormatter.string(from: $0) },
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            encryptedOriginalFilename: encryptedOriginalFilename,
            byteSize: byteSize,
            contentDigest: contentDigest,
            deletedAt: existing?.deletedAt
        )
    }

    private func digestData(_ hex: String) throws -> Data {
        guard hex.utf8.count == 64 else {
            throw VaultError.invalidFileCredential(.digestMismatch)
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var iterator = hex.utf8.makeIterator()
        while let high = iterator.next() {
            guard let low = iterator.next(),
                  let highNibble = hexNibble(high),
                  let lowNibble = hexNibble(low) else {
                throw VaultError.invalidFileCredential(.digestMismatch)
            }
            bytes.append((highNibble << 4) | lowNibble)
        }
        guard bytes.count == 32 else { throw VaultError.invalidFileCredential(.digestMismatch) }
        return Data(bytes)
    }

    private func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    private func equalDigest(_ lhs: String?, _ rhs: String?) throws -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return try digestData(lhs) == digestData(rhs)
        default: return false
        }
    }
}
