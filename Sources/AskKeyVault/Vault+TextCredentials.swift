import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    static var agentAccessPausedConfigKey: String { "agent_access_paused" }
    static var credentialGroupsConfigKey: String { "credential_groups" }

    public func isAgentAccessPaused() throws -> Bool {
        try agentAccessGate.isPaused()
    }

    func synchronizeAgentAccessState() throws {
        let configuredPaused: Bool
        switch try store.configValue(key: Self.agentAccessPausedConfigKey) {
        case nil: configuredPaused = false
        case "true": configuredPaused = true
        default:
            agentAccessGate.invalidate()
            throw VaultError.databaseError("Agent access pause state is invalid.")
        }
        let paused = configuredPaused
        agentAccessGate.synchronize(paused: paused)
        if paused {
            brokerRequests.pauseAndCancelAll()
            approvalRequests.pauseAndCancelAll()
        } else {
            brokerRequests.resume()
            approvalRequests.resume()
        }
    }

    public func pauseAgentAccess(using authenticator: ManagementAuthenticator) throws {
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.pauseReason)
        _ = try requireKey()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        do {
            try store.setConfigValue(key: Self.agentAccessPausedConfigKey, value: "true")
            brokerRequests.pauseAndCancelAll()
            approvalRequests.pauseAndCancelAll()
            cleanupRuntimeFileDeliveries()
            agentAccessGate.endExclusiveChange(paused: true)
        } catch {
            agentAccessGate.endExclusiveChange(paused: wasPaused)
            throw error
        }
    }

    public func resumeAgentAccess(using authenticator: ManagementAuthenticator) throws {
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.resumeReason)
        _ = try requireKey()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        do {
            try store.setConfigValue(key: Self.agentAccessPausedConfigKey, value: nil)
            brokerRequests.resume()
            approvalRequests.resume()
            agentAccessGate.endExclusiveChange(paused: false)
        } catch {
            agentAccessGate.endExclusiveChange(paused: wasPaused)
            throw error
        }
    }

    public func cleanupRuntimeFileDeliveries() {
        fileDeliveryManager.cleanupAll()
    }

    public var hasRuntimeFileCleanupFailures: Bool {
        fileDeliveryManager.hasFailures
    }

    /// Resolves the Agent permission without trusting caller-provided identity.
    /// Hidden, unknown, and expired names deliberately share one error.
    public func authorizeAgentCredential(
        named rawName: String,
        operation: AgentCredentialOperation,
        caller: BrokerCallerClaim,
        now: Date = Date()
    ) throws -> AgentCredentialAuthorization {
        try agentAccessGate.beginAgentOperation()
        defer { agentAccessGate.endAgentOperation() }
        _ = caller
        let key = try requireKey()
        guard let displayName = try? CredentialName.displayName(from: rawName) else {
            throw VaultError.credentialUnavailable
        }
        let nameIndex = CredentialIndex.hash(
            normalizedName: CredentialName.normalized(displayName),
            vaultKey: key
        )
        guard let record = try store.fetchCredential(nameIndex: nameIndex),
              let permission = CredentialPermission(rawValue: record.permission),
              permission != .hidden else {
            throw VaultError.credentialUnavailable
        }
        if let expiresAt = try record.expiresAt.map({ try parseExpiry($0) }), expiresAt <= now {
            approvalRequests.cancelPending(credentialID: record.id)
            throw VaultError.credentialUnavailable
        }
        guard operation == .read else { return .requiresApproval }
        return permission == .allowed ? .allowed : .requiresApproval
    }

    /// Agent-visible metadata only. This deliberately bypasses the App management
    /// session while still requiring the App-held vault key. Component metadata
    /// is projected inside the App; private notes, values and filenames never
    /// cross the Broker directory boundary.
    public func brokerCredentialCatalog(
        now: Date = Date(),
        cancellation: BrokerCancellation? = nil
    ) throws -> [BrokerCatalogItem] {
        try agentAccessGate.beginAgentOperation()
        defer { agentAccessGate.endAgentOperation() }
        let key = try requireKey()
        try cancellation?.check()
        let catalogStore = try store
        let records: [CredentialRecord]
        if let cancellation {
            records = try catalogStore.fetchAllCredentials(cancellation: cancellation)
        } else {
            records = try catalogStore.fetchAllCredentials()
        }
        try cancellation?.check()
        return try records.compactMap { record in
            try cancellation?.check()
            guard let permission = CredentialPermission(rawValue: record.permission) else {
                throw VaultError.databaseError("Credential has an unknown permission.")
            }
            guard permission != .hidden else { return nil }
            let name = try VaultCrypto.decrypt(record.encryptedDisplayName, using: key)
            let instructions = try VaultCrypto.decrypt(record.encryptedUsageInstructions, using: key)
            let environmentVariable = try record.encryptedEnvironmentVariable.map {
                try VaultCrypto.decrypt($0, using: key)
            }
            guard [name, instructions, environmentVariable]
                .compactMap({ $0 })
                .allSatisfy({ $0.utf8.count <= BrokerLimits.maximumFieldBytes }) else {
                throw VaultError.databaseError("Credential catalog field exceeds the Broker limit.")
            }
            guard let storedPayloadKind = CredentialPayloadKind(rawValue: record.payloadKind) else {
                throw VaultError.databaseError("Credential has an unknown payload kind.")
            }
            let payloadKind: BrokerCatalogPayloadKind = storedPayloadKind == .file ? .file : .text
            let expiresAt = try record.expiresAt.map { try parseExpiry($0) }
            let expired = expiresAt.map { $0 <= now } ?? false
            if expired {
                approvalRequests.cancelPending(credentialID: record.id)
                try fileDeliveryManager.get().revoke(credentialID: record.id)
            }
            return BrokerCatalogItem(
                credentialID: record.id,
                name: name,
                payloadKind: payloadKind,
                usageInstructions: instructions,
                environmentVariable: environmentVariable,
                expired: expired,
                components: try credentialComponents(from: record, key: key).map {
                    BrokerCatalogComponent(name: $0.name, payloadKind: $0.value.payloadKind == .file ? .file : .text, delivery: $0.delivery)
                }
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Prepares an explicit text-only runtime delivery. Approval-tier values are
    /// never decrypted until every operation in the requested set is approved.
    public func brokerTextCredentials(
        for request: BrokerTextRunRequest,
        cancellation: BrokerCancellation
    ) throws -> BrokerTextCredentialResolution {
        try agentAccessGate.beginAgentOperation()
        var ownsAgentOperation = true
        defer { if ownsAgentOperation { agentAccessGate.endAgentOperation() } }
        try cancellation.check()
        guard request.declarationsAreValid else { throw BrokerTextRuntimeError.invalidRequest }
        let key = try requireKey()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(request)
        let payloadDigest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        let callerName = request.sanitizedCallerName
        let callerPurpose = request.sanitizedCallerPurpose
        var records: [CredentialRecord] = []
        var consumptions: [BrokerApprovalConsumption] = []
        var pending: [BrokerApprovalTicket] = []

        for name in request.credentialNames {
            try cancellation.check()
            let displayName = try CredentialName.displayName(from: name)
            let index = CredentialIndex.hash(
                normalizedName: CredentialName.normalized(displayName),
                vaultKey: key
            )
            guard let record = try store.fetchCredential(nameIndex: index),
                  let permission = CredentialPermission(rawValue: record.permission),
                  permission != .hidden,
                  CredentialPayloadKind(rawValue: record.payloadKind) != nil else {
                recordHiddenCredentialGuess(callerHint: callerName, declaredPurpose: callerPurpose)
                throw VaultError.credentialUnavailable
            }
            let trustedName = try VaultCrypto.decrypt(record.encryptedDisplayName, using: key)
            let expiresAt = try record.expiresAt.map { try parseExpiry($0) }
            guard expiresAt.map({ $0 > Date() }) ?? true else {
                recordCredentialAccess(.init(
                    timestamp: currentDate,
                    credentialID: record.id,
                    operation: .runtimeRead,
                    result: .failed,
                    callerHint: callerName,
                    declaredPurpose: callerPurpose
                ))
                approvalRequests.cancelPending(credentialID: record.id)
                try fileDeliveryManager.get().revoke(credentialID: record.id)
                throw VaultError.credentialUnavailable
            }
            records.append(record)
            guard permission == .ask else { continue }
            let approvalRequest = BrokerApprovalOperationRequest(
                operationID: SHA256.hash(data: Data("\(request.operationID):\(record.id)".utf8))
                    .map { String(format: "%02x", $0) }.joined(),
                credentialID: record.id,
                targetID: record.id,
                operation: .read,
                payloadDigest: payloadDigest,
                credentialName: trustedName,
                callerName: callerName,
                callerPurpose: callerPurpose
            )
            let ticket = try approvalRequests.submit(
                approvalRequest,
                trustedCredentialDeadline: expiresAt.map(BrokerCredentialDeadline.expiresAt) ?? .none,
                trustedCredentialName: trustedName
            )
            switch ticket.state {
            case .approved:
                consumptions.append(.init(
                    requestID: ticket.requestID,
                    capability: ticket.capability,
                    operationRequest: approvalRequest
                ))
            case .pending:
                pending.append(ticket)
            default:
                throw VaultError.credentialUnavailable
            }
        }
        if !pending.isEmpty { return .approvalRequired(pending) }
        let runtimeAuthorization = try approvalRequests.consumeForRuntime(consumptions)
        var fileDeliveries: [FileDelivery] = []
        let credentials: [BrokerTextCredential]
        do {
            credentials = try records.flatMap { record -> [BrokerTextCredential] in
                try credentialComponents(from: record, key: key).compactMap { component in
                    try cancellation.check()
                    switch component.delivery {
                    case .none:
                        return nil
                    case .environmentVariable(let variable):
                        guard case .text(let value) = component.value else {
                            throw VaultError.credentialUnavailable
                        }
                        return BrokerTextCredential(environmentVariable: variable, value: value)
                    case .temporaryFile(let variable):
                        let bytes: Data
                        switch component.value {
                        case .text(let text): bytes = Data(text.utf8)
                        case .file(_, let value): bytes = value
                        }
                        let expiry = try record.expiresAt.map { try parseExpiry($0) }
                        let delivery = try fileDeliveryManager.get().materialize(
                            credentialID: record.id, bytes: bytes, expiresAt: expiry,
                            authorization: runtimeAuthorization
                        )
                        fileDeliveries.append(delivery)
                        return BrokerTextCredential(environmentVariable: variable, value: delivery.url.path)
                    }
                }
            }
        } catch {
            fileDeliveries.forEach { $0.finish() }
            throw error
        }
        let gate = agentAccessGate
        let credentialDeadline = try records.compactMap { record in
            try record.expiresAt.map { try parseExpiry($0) }
        }.min()
        let spawnDeadline = ([credentialDeadline, runtimeAuthorization?.expiresAt].compactMap { $0 }
            + fileDeliveries.map(\.expiresAt)).min()
        let completedFileDeliveries = fileDeliveries
        let lease = BrokerTextDeliveryLease(
            beginSpawnAuthorization: { try gate.beginSpawnAuthorization() },
            validate: {
                try cancellation.check()
                guard records.allSatisfy({ record in
                    guard let value = record.expiresAt else { return true }
                    return ((try? self.parseExpiry(value))?.timeIntervalSinceNow ?? -1) > 0
                }) else {
                    throw BrokerProviderError.requestRejected
                }
            },
            endSpawnAuthorization: { gate.endSpawnAuthorization() },
            spawnDeadline: spawnDeadline,
            runtimeAuthorization: runtimeAuthorization,
            finish: { gate.endAgentOperation() },
            cleanup: { completedFileDeliveries.forEach { $0.finish() } }
        )
        for record in records {
            recordCredentialAccess(.init(
                timestamp: currentDate,
                credentialID: record.id,
                operation: .runtimeRead,
                result: .allowed,
                callerHint: callerName,
                declaredPurpose: callerPurpose
            ))
        }
        ownsAgentOperation = false
        return .resolved(
            credentials: credentials,
            resolvedRequestCount: records.count,
            deliveryLease: lease
        )
    }

    public func createTextCredential(
        _ input: TextCredentialInput,
        using authenticator: ManagementAuthenticator
    ) throws -> ManagedTextCredential {
        return try performCredentialCreation(using: authenticator) {
        let key = try requireKey()
        let prepared = try preparedRecord(from: input, id: UUID().uuidString, key: key, existing: nil)
        try store.insertCredential(prepared)
        return try managedCredential(from: prepared, key: key, includeSecrets: false)
        }
    }

    public func createBundleCredential(
        _ input: BundleCredentialInput,
        using authenticator: ManagementAuthenticator
    ) throws -> ManagedTextCredential {
        return try performCredentialCreation(using: authenticator) {
        let key = try requireKey()
        let prepared = try preparedBundleRecord(
            from: input,
            id: UUID().uuidString,
            key: key,
            existing: nil
        )
        try store.insertCredential(prepared)
        return try managedCredential(from: prepared, key: key, includeSecrets: false)
        }
    }

    public func updateBundleCredential(
        id: String,
        _ input: BundleCredentialInput,
        using authenticator: ManagementAuthenticator
    ) throws -> ManagedTextCredential {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        let key = try requireKey()
        let prepared = try performCredentialMutation(id: id) {
            guard let existing = try store.fetchCredential(id: id) else {
                throw VaultError.credentialNotFound(id)
            }
            let prepared = try preparedBundleRecord(from: input, id: id, key: key, existing: existing)
            try store.updateCredential(prepared)
            return prepared
        }
        return try managedCredential(from: prepared, key: key, includeSecrets: false)
    }

    /// Replaces imported material without reconstructing redacted management metadata.
    public func replaceImportedBundleCredential(
        id: String,
        components: [CredentialComponentInput],
        using authenticator: ManagementAuthenticator
    ) throws -> ManagedTextCredential {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        let key = try requireKey()
        let validated = try CredentialBundleValidator.validatedComponents(components)
        let prepared = try performCredentialMutation(id: id) {
            guard var existing = try store.fetchCredential(id: id) else {
                throw VaultError.credentialNotFound(id)
            }
            existing.encryptedPayload = try VaultCrypto.encrypt(JSONEncoder().encode(validated), using: key)
            existing.payloadKind = CredentialPayloadKind.bundle.rawValue
            existing.encryptedEnvironmentVariable = nil
            existing.encryptedOriginalFilename = nil
            existing.byteSize = nil
            existing.contentDigest = nil
            existing.updatedAt = sharedDateFormatter.string(from: currentDate)
            try store.updateCredential(existing)
            return existing
        }
        return try managedCredential(from: prepared, key: key, includeSecrets: false)
    }

    public func updateCredentialGroup(
        id: String,
        groupName: String?,
        using authenticator: ManagementAuthenticator
    ) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        let key = try requireKey()
        let group = try CredentialName.optionalDisplayName(groupName)
        try performCredentialMutation(id: id) {
            guard var existing = try store.fetchCredential(id: id) else {
                throw VaultError.credentialNotFound(id)
            }
            existing.encryptedGroupName = try group.map { try VaultCrypto.encrypt($0, using: key) }
            existing.updatedAt = sharedDateFormatter.string(from: currentDate)
            try store.updateCredential(existing)
        }
    }

    public func updateCredentialPermission(
        id: String,
        permission: CredentialPermission,
        using authenticator: ManagementAuthenticator
    ) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        _ = try requireKey()
        try performCredentialMutation(id: id) {
            guard var existing = try store.fetchCredential(id: id) else {
                throw VaultError.credentialNotFound(id)
            }
            existing.permission = permission.rawValue
            existing.updatedAt = sharedDateFormatter.string(from: currentDate)
            try store.updateCredential(existing)
        }
    }

    public func updateCredentialMetadata(
        id: String,
        name: String,
        usageInstructions: String,
        groupName: String?,
        permission: CredentialPermission,
        expiresAt: Date?,
        using authenticator: ManagementAuthenticator
    ) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        let key = try requireKey()
        let displayName = try CredentialName.displayName(from: name)
        let nameIndex = CredentialIndex.hash(
            normalizedName: CredentialName.normalized(displayName),
            vaultKey: key
        )
        try CredentialFieldValidation.usageInstructions(usageInstructions)
        let group = try CredentialName.optionalDisplayName(groupName)
        try performCredentialMutation(id: id) {
            guard var existing = try store.fetchCredential(id: id) else {
                throw VaultError.credentialNotFound(id)
            }
            if let conflict = try store.fetchCredentialIncludingRecycled(nameIndex: nameIndex),
               conflict.id != id {
                throw VaultError.credentialNameConflict(displayName)
            }
            existing.nameIndex = nameIndex
            existing.encryptedDisplayName = try VaultCrypto.encrypt(displayName, using: key)
            existing.encryptedUsageInstructions = try VaultCrypto.encrypt(usageInstructions, using: key)
            existing.encryptedGroupName = try group.map { try VaultCrypto.encrypt($0, using: key) }
            existing.permission = permission.rawValue
            existing.expiresAt = expiresAt.map { sharedDateFormatter.string(from: $0) }
            existing.updatedAt = sharedDateFormatter.string(from: currentDate)
            try store.updateCredential(existing)
        }
    }

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

    public func listTextCredentials() throws -> [ManagedTextCredential] {
        try requireManagementSession()
        let key = try requireKey()
        return try store.fetchAllCredentials()
            .map { try managedCredential(from: $0, key: key, includeSecrets: false) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func listCredentialExpirySnapshots() throws -> [CredentialExpirySnapshot] {
        try store.fetchAllCredentials().map { record in
            CredentialExpirySnapshot(
                id: record.id,
                expiresAt: try record.expiresAt.map { try parseExpiry($0) }
            )
        }
    }

    public func storedCredentialCount() throws -> Int {
        try credentialCountForBootstrap()
    }

    public func listCredentialGroups() throws -> [String] {
        try requireManagementSession()
        let key = try requireKey()
        var groups = Set(try storedCredentialGroups(key: key))
        for record in try (store.fetchAllCredentials() + store.fetchRecycledCredentials()) {
            if let encrypted = record.encryptedGroupName {
                groups.insert(try VaultCrypto.decrypt(encrypted, using: key))
            }
        }
        return groups.sorted()
    }

    public func createCredentialGroup(
        _ rawName: String,
        using authenticator: ManagementAuthenticator
    ) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        let key = try requireKey()
        let name = try CredentialName.displayName(from: rawName)
        var groups = Set(try storedCredentialGroups(key: key))
        groups.insert(name)
        try persistCredentialGroups(groups.sorted(), key: key)
        notifySnapshotRelevantChange()
    }

    public func deleteCredentialGroup(
        _ rawName: String,
        using authenticator: ManagementAuthenticator
    ) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        let key = try requireKey()
        let name = try CredentialName.displayName(from: rawName)
        let deliveryManager = try fileDeliveryManager.get()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        defer { agentAccessGate.endExclusiveChange(paused: wasPaused) }
        var groups = Set(try storedCredentialGroups(key: key))
        groups.remove(name)
        let matchingIDs = try (store.fetchAllCredentials() + store.fetchRecycledCredentials())
            .compactMap { record -> String? in
                guard let encrypted = record.encryptedGroupName,
                      try VaultCrypto.decrypt(encrypted, using: key) == name else { return nil }
                return record.id
            }
        let encrypted = try encryptedCredentialGroups(groups.sorted(), key: key)
        try store.replaceCredentialGroupsConfig(
            key: Self.credentialGroupsConfigKey,
            value: encrypted,
            clearingCredentialIDs: matchingIDs,
            updatedAt: sharedDateFormatter.string(from: currentDate)
        )
        for id in matchingIDs {
            brokerRequests.cancelPending(credentialID: id)
            approvalRequests.cancelPending(credentialID: id)
            deliveryManager.revoke(credentialID: id)
        }
        notifySnapshotRelevantChange()
    }

    func storedCredentialGroups(key: SymmetricKey) throws -> [String] {
        guard let value = try store.configValue(key: Self.credentialGroupsConfigKey) else { return [] }
        guard let encrypted = Data(base64Encoded: value) else {
            throw VaultError.databaseError("Credential groups are invalid.")
        }
        return try JSONDecoder().decode(
            [String].self,
            from: VaultCrypto.decryptData(encrypted, using: key)
        )
    }

    private func persistCredentialGroups(_ groups: [String], key: SymmetricKey) throws {
        try store.setConfigValue(
            key: Self.credentialGroupsConfigKey,
            value: try encryptedCredentialGroups(groups, key: key)
        )
    }

    func encryptedCredentialGroups(_ groups: [String], key: SymmetricKey) throws -> String {
        try VaultCrypto.encrypt(JSONEncoder().encode(groups), using: key).base64EncodedString()
    }

    public func revealTextCredential(
        id: String,
        using authenticator: ManagementAuthenticator
    ) throws -> ManagedTextCredential {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.revealReason)
        let key = try requireKey()
        guard let record = try store.fetchCredential(id: id) else {
            throw VaultError.credentialNotFound(id)
        }
        return try managedCredential(from: record, key: key, includeSecrets: true)
    }

    public func updateTextCredential(
        id: String,
        _ input: TextCredentialInput,
        using authenticator: ManagementAuthenticator
    ) throws -> ManagedTextCredential {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        let key = try requireKey()
        let prepared = try performCredentialMutation(id: id) {
            guard let existing = try store.fetchCredential(id: id) else {
                throw VaultError.credentialNotFound(id)
            }
            let prepared = try preparedRecord(from: input, id: existing.id, key: key, existing: existing)
            try store.updateCredential(prepared)
            return prepared
        }
        return try managedCredential(from: prepared, key: key, includeSecrets: false)
    }

    public func deleteTextCredential(
        id: String,
        using authenticator: ManagementAuthenticator
    ) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        _ = try requireKey()
        try performCredentialMutation(id: id) {
            try store.recycleCredential(id: id, deletedAt: sharedDateFormatter.string(from: currentDate))
        }
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

    private func performCredentialMutation<T>(id: String, _ mutation: () throws -> T) throws -> T {
        let deliveryManager = try fileDeliveryManager.get()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        defer { agentAccessGate.endExclusiveChange(paused: wasPaused) }
        let result = try mutation()
        brokerRequests.cancelPending(credentialID: id)
        approvalRequests.cancelPending(credentialID: id)
        deliveryManager.revoke(credentialID: id)
        notifySnapshotRelevantChange()
        return result
    }

    func preparedRecord(
        from input: TextCredentialInput,
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
        let group = try CredentialName.optionalDisplayName(input.groupName)
        try CredentialFieldValidation.usageInstructions(input.usageInstructions)
        let environmentVariable = try optionalEnvironmentVariable(input.environmentVariable)
        let now = sharedDateFormatter.string(from: currentDate)
        return CredentialRecord(
            id: id,
            nameIndex: nameIndex,
            encryptedDisplayName: try VaultCrypto.encrypt(displayName, using: key),
            encryptedPayload: try VaultCrypto.encrypt(input.value, using: key),
            encryptedUsageInstructions: try VaultCrypto.encrypt(input.usageInstructions, using: key),
            encryptedPrivateNotes: try VaultCrypto.encrypt(input.privateNotes, using: key),
            encryptedGroupName: try group.map { try VaultCrypto.encrypt($0, using: key) },
            encryptedEnvironmentVariable: try environmentVariable.map { try VaultCrypto.encrypt($0, using: key) },
            payloadKind: CredentialPayloadKind.text.rawValue,
            permission: input.permission.rawValue,
            expiresAt: input.expiresAt.map { sharedDateFormatter.string(from: $0) },
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            encryptedOriginalFilename: nil,
            byteSize: nil,
            contentDigest: nil,
            deletedAt: existing?.deletedAt
        )
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

    func preparedBundleRecord(
        from input: BundleCredentialInput,
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
        let components = try CredentialBundleValidator.validatedComponents(input.components)
        let group = try CredentialName.optionalDisplayName(input.groupName)
        try CredentialFieldValidation.usageInstructions(input.usageInstructions)
        let now = sharedDateFormatter.string(from: currentDate)
        return CredentialRecord(
            id: id,
            nameIndex: nameIndex,
            encryptedDisplayName: try VaultCrypto.encrypt(displayName, using: key),
            encryptedPayload: try VaultCrypto.encrypt(JSONEncoder().encode(components), using: key),
            encryptedUsageInstructions: try VaultCrypto.encrypt(input.usageInstructions, using: key),
            encryptedPrivateNotes: try VaultCrypto.encrypt(input.privateNotes, using: key),
            encryptedGroupName: try group.map { try VaultCrypto.encrypt($0, using: key) },
            encryptedEnvironmentVariable: nil,
            payloadKind: CredentialPayloadKind.bundle.rawValue,
            permission: input.permission.rawValue,
            expiresAt: input.expiresAt.map { sharedDateFormatter.string(from: $0) },
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            encryptedOriginalFilename: nil,
            byteSize: nil,
            contentDigest: nil,
            deletedAt: existing?.deletedAt
        )
    }

    /// Converts legacy single-material records into the same whole-credential
    /// representation used by bundles, without exposing their values to Broker.
    func credentialComponents(from record: CredentialRecord, key: SymmetricKey) throws -> [CredentialComponentInput] {
        let components: [CredentialComponentInput]
        switch CredentialPayloadKind(rawValue: record.payloadKind) {
        case .bundle:
            components = try JSONDecoder().decode([CredentialComponentInput].self,
                from: VaultCrypto.decryptData(record.encryptedPayload, using: key))
        case .text:
            let variable = try record.encryptedEnvironmentVariable.map { try VaultCrypto.decrypt($0, using: key) }
            components = [.init(name: legacyComponentName(mapping: variable, fallback: "VALUE"),
                value: .text(try VaultCrypto.decrypt(record.encryptedPayload, using: key)),
                delivery: variable.map { .environmentVariable($0) } ?? .none)]
        case .file:
            let bytes = try VaultCrypto.decryptData(record.encryptedPayload, using: key)
            guard let digest = record.contentDigest, Data(SHA256.hash(data: bytes)) == digest,
                  let filename = record.encryptedOriginalFilename else {
                throw VaultError.invalidFileCredential(.digestMismatch)
            }
            let variable = try record.encryptedEnvironmentVariable.map { try VaultCrypto.decrypt($0, using: key) }
            components = [.init(name: legacyComponentName(mapping: variable, fallback: "FILE"),
                value: .file(filename: try VaultCrypto.decrypt(filename, using: key), bytes: bytes),
                delivery: variable.map { .temporaryFile($0) } ?? .none)]
        case nil:
            throw VaultError.databaseError("Credential has an unknown payload kind.")
        }
        return try CredentialBundleValidator.validatedComponents(components)
    }

    private func legacyComponentName(mapping: String?, fallback: String) -> String {
        // A delivery mapping has its own byte limit; it is not necessarily a valid display name.
        guard let mapping, let name = try? CredentialName.displayName(from: mapping) else { return fallback }
        return name
    }

    func managedCredential(
        from record: CredentialRecord,
        key: SymmetricKey,
        includeSecrets: Bool
    ) throws -> ManagedTextCredential {
        let permission = CredentialPermission(rawValue: record.permission) ?? .ask
        let payloadKind = CredentialPayloadKind(rawValue: record.payloadKind) ?? .text
        let digestHex = record.contentDigest.map { $0.map { String(format: "%02x", $0) }.joined() }
        var value: String?
        var fileBytes: Data?
        var originalFilename: String?
        var privateNotes: String?
        var components: [ManagedCredentialComponent] = []
        if payloadKind == .bundle {
            let decoded = try JSONDecoder().decode(
                [CredentialComponentInput].self,
                from: VaultCrypto.decryptData(record.encryptedPayload, using: key)
            )
            components = decoded.map {
                ManagedCredentialComponent(
                    name: $0.name,
                    kind: $0.value.payloadKind,
                    value: includeSecrets ? $0.value : nil,
                    delivery: $0.delivery,
                    masked: $0.masked
                )
            }
        }
        if includeSecrets {
            privateNotes = try VaultCrypto.decrypt(record.encryptedPrivateNotes, using: key)
            if payloadKind == .file {
                let bytes = try VaultCrypto.decryptData(record.encryptedPayload, using: key)
                guard let expected = record.contentDigest, Data(SHA256.hash(data: bytes)) == expected else {
                    throw VaultError.invalidFileCredential(.digestMismatch)
                }
                fileBytes = bytes
                originalFilename = try record.encryptedOriginalFilename.map {
                    try VaultCrypto.decrypt($0, using: key)
                }
            } else if payloadKind == .text {
                value = try VaultCrypto.decrypt(record.encryptedPayload, using: key)
            }
        }
        return ManagedTextCredential(
            id: record.id,
            name: try VaultCrypto.decrypt(record.encryptedDisplayName, using: key),
            value: value,
            usageInstructions: try VaultCrypto.decrypt(record.encryptedUsageInstructions, using: key),
            privateNotes: privateNotes,
            groupName: try record.encryptedGroupName.map { try VaultCrypto.decrypt($0, using: key) },
            environmentVariable: try record.encryptedEnvironmentVariable.map { try VaultCrypto.decrypt($0, using: key) },
            permission: permission,
            expiresAt: try record.expiresAt.map { try parseExpiry($0) },
            payloadKind: payloadKind,
            originalFilename: originalFilename,
            byteSize: record.byteSize,
            contentDigest: digestHex,
            fileBytes: fileBytes,
            components: components,
            deletedAt: try record.deletedAt.map { try parseExpiry($0) }
        )
    }

    private func optionalEnvironmentVariable(_ raw: String?) throws -> String? {
        try CredentialFieldValidation.optionalEnvironmentVariable(raw)
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

    private func parseExpiry(_ value: String) throws -> Date {
        guard let date = sharedDateFormatter.date(from: value) else {
            throw VaultError.databaseError("Credential expiry is not a valid timestamp.")
        }
        return date
    }
}

final class AgentAccessGate: @unchecked Sendable {
    private enum State { case active, paused, invalid }

    private let condition = NSCondition()
    private var state: State = .active
    private var activeOperations = 0
    private var changing = false

    func beginAgentOperation() throws {
        condition.lock(); defer { condition.unlock() }
        switch state {
        case .active: activeOperations += 1
        case .paused: throw VaultError.agentAccessPaused
        case .invalid: throw invalidStateError
        }
    }

    func endAgentOperation() {
        condition.lock()
        if activeOperations > 0 { activeOperations -= 1 }
        condition.broadcast()
        condition.unlock()
    }

    /// Keeps the gate condition locked across the final expiry check and spawn.
    /// An exclusive mutation either marks the gate paused first or waits until
    /// the target exists; there is no check-then-spawn gap.
    func beginSpawnAuthorization() throws {
        condition.lock()
        guard state == .active else {
            condition.unlock()
            throw BrokerProviderError.requestRejected
        }
    }

    func endSpawnAuthorization() {
        condition.unlock()
    }

    /// Agent writes share the spawn exclusion boundary without gaining the
    /// ability to operate while access was already paused.
    func beginExclusiveAgentChange() throws -> Bool {
        condition.lock()
        while changing { condition.wait() }
        guard state == .active else {
            let error: Error = state == .paused ? VaultError.agentAccessPaused : invalidStateError
            condition.unlock()
            throw error
        }
        changing = true
        state = .paused
        while activeOperations > 0 { condition.wait() }
        condition.unlock()
        return false
    }

    func beginExclusiveChange() throws -> Bool {
        condition.lock()
        while changing { condition.wait() }
        guard state != .invalid else {
            condition.unlock()
            throw invalidStateError
        }
        changing = true
        let wasPaused = state == .paused
        state = .paused
        while activeOperations > 0 { condition.wait() }
        condition.unlock()
        return wasPaused
    }

    func endExclusiveChange(paused: Bool) {
        condition.lock()
        state = paused ? .paused : .active
        changing = false
        condition.broadcast()
        condition.unlock()
    }

    func synchronize(paused: Bool) {
        condition.lock()
        state = paused ? .paused : .active
        condition.broadcast()
        condition.unlock()
    }

    func invalidate() {
        condition.lock()
        state = .invalid
        condition.broadcast()
        condition.unlock()
    }

    func isPaused() throws -> Bool {
        condition.lock(); defer { condition.unlock() }
        switch state {
        case .active: return false
        case .paused: return true
        case .invalid: throw invalidStateError
        }
    }

    private var invalidStateError: VaultError {
        .databaseError("Agent access pause state is invalid.")
    }
}
