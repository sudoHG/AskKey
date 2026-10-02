import CryptoKit
import Foundation
import GRDB
import AskKeyBroker

public struct FrozenCredentialWrite: Equatable, Sendable {
    public let credentialName: String
    public let operation: BrokerApprovalOperation
    public let before: [CredentialComponentInput]
    public let after: [CredentialComponentInput]
}

enum FrozenAgentTextMutation {
    case create(CredentialRecord)
    case modify(CredentialRecord, expectedUpdatedAt: String)
    case delete(credentialID: String, expectedUpdatedAt: String, deletedAt: String)
}

struct FrozenAgentTextWrite {
    let operationID: String
    let digest: String
    let approvalRequest: BrokerApprovalOperationRequest
    let credentialExpiresAt: Date?
    let mutation: FrozenAgentTextMutation
    var beforeRecord: CredentialRecord? = nil
    var summary: BrokerCredentialWriteSummary? = nil
}

final class FrozenAgentTextWriteRegistry: @unchecked Sendable {
    private let operationLock = NSRecursiveLock()
    private let lock = NSLock()
    private var entries: [String: FrozenAgentTextWrite] = [:]

    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        operationLock.lock(); defer { operationLock.unlock() }
        return try body()
    }

    func store(_ candidate: FrozenAgentTextWrite) throws -> (write: FrozenAgentTextWrite, inserted: Bool) {
        lock.lock(); defer { lock.unlock() }
        if let existing = entries[candidate.operationID] {
            guard existing.digest == candidate.digest else {
                throw BrokerApprovalError.payloadMismatch
            }
            return (existing, false)
        }
        guard entries.count < BrokerLimits.maximumPendingApprovalRequests else {
            throw BrokerApprovalError.capacityReached
        }
        entries[candidate.operationID] = candidate
        return (candidate, true)
    }

    func entry(operationID: String) -> FrozenAgentTextWrite? {
        lock.lock(); defer { lock.unlock() }
        return entries[operationID]
    }

    func remove(operationID: String) {
        operationLock.lock(); defer { operationLock.unlock() }
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: operationID)
    }
}

extension Vault {
    public func requestAgentTextWrite(
        _ request: AgentTextWriteRequest,
        fileResolver: (BrokerComponentFileReference) throws -> BrokerFrozenComponentFile = { _ in
            throw BrokerApprovalError.invalidRequest
        }
    ) throws -> AgentTextWriteRequestOutcome {
        try validateAgentTextWrite(request)
        // Resolve upload capabilities outside the gate/registry locks. Legacy file
        // commit takes the coordinator lock before acquiring the exclusive gate.
        let alreadyFrozen = agentTextWrites.entry(operationID: request.operationID) != nil
        let alreadyCommitted = try store.fetchAgentWriteOperation(operationID: request.operationID) != nil
        var files: [BrokerComponentFileReference: BrokerFrozenComponentFile] = [:]
        if !alreadyFrozen && !alreadyCommitted {
            var totalFileBytes = 0
            for reference in request.componentFileReferences {
                let file = try fileResolver(reference)
                totalFileBytes += file.bytes.count
                guard totalFileBytes <= BrokerFileWriteCoordinator.maximumByteCount else {
                    throw BrokerApprovalError.invalidRequest
                }
                guard file.digest == reference.digest,
                      Self.componentDigest(file.bytes) == reference.digest else {
                    throw BrokerApprovalError.payloadMismatch
                }
                files[reference] = file
            }
        }
        try agentAccessGate.beginAgentOperation()
        defer { agentAccessGate.endAgentOperation() }
        return try agentTextWrites.synchronized {
            try requestAgentTextWriteSynchronized(request, files: files)
        }
    }

    private func requestAgentTextWriteSynchronized(
        _ request: AgentTextWriteRequest,
        files: [BrokerComponentFileReference: BrokerFrozenComponentFile]
    ) throws -> AgentTextWriteRequestOutcome {
        try validateAgentTextWrite(request)
        let digest = try agentTextWriteDigest(request)
        if let committed = try store.fetchAgentWriteOperation(operationID: request.operationID) {
            guard committed.payloadDigest == digest else { throw BrokerApprovalError.payloadMismatch }
            return .completed(.init(operationID: committed.operationId, credentialID: committed.credentialId))
        }
        if let ticket = try approvalRequests.terminalRetransmission(
            operationID: request.operationID,
            payloadDigest: digest
        ) {
            return .submitted(submission(operationID: request.operationID, ticket: ticket))
        }
        let key = try requireKey()
        let candidate: FrozenAgentTextWrite
        if let existing = agentTextWrites.entry(operationID: request.operationID) {
            guard existing.digest == digest else { throw BrokerApprovalError.payloadMismatch }
            candidate = existing
        } else {
            candidate = try freezeAgentTextWrite(request, digest: digest, key: key, files: files)
        }
        let reservation = try agentTextWrites.store(candidate)
        do {
            let ticket = try approvalRequests.submit(
                reservation.write.approvalRequest,
                trustedCredentialDeadline: reservation.write.credentialExpiresAt.map {
                    .expiresAt($0)
                } ?? .none
            )
            return .submitted(submission(operationID: request.operationID, ticket: ticket))
        } catch {
            if reservation.inserted {
                agentTextWrites.remove(operationID: request.operationID)
            }
            throw error
        }
    }

    private func submission(
        operationID: String,
        ticket: BrokerApprovalTicket
    ) -> AgentTextWriteSubmission {
        AgentTextWriteSubmission(
            operationID: operationID,
            requestID: ticket.requestID,
            capability: ticket.capability,
            state: ticket.state,
            retryCount: ticket.retryCount
        )
    }

    public func commitAgentTextWrite(
        _ request: AgentTextWriteRequest,
        requestID: String,
        capability: String
    ) throws -> AgentTextWriteResult {
        let operation: CredentialAccessEvent.Operation
        switch request.action {
        case .create, .createBundle: operation = .create
        case .modify, .modifyBundle: operation = .modify
        case .delete: operation = .delete
        }
        var credentialID = agentTextWrites.entry(operationID: request.operationID)?
            .approvalRequest.credentialID
        var succeeded = false
        defer {
            recordCredentialAccess(.init(
                timestamp: currentDate,
                credentialID: credentialID,
                operation: operation,
                result: succeeded ? .allowed : .failed,
                callerHint: request.callerName,
                declaredPurpose: request.callerPurpose
            ))
        }
        let wasPaused = try agentAccessGate.beginExclusiveAgentChange()
        defer { agentAccessGate.endExclusiveChange(paused: wasPaused) }
        let result = try agentTextWrites.synchronized {
            try commitAgentTextWriteSynchronized(
                request,
                requestID: requestID,
                capability: capability
            )
        }
        credentialID = result.credentialID
        fileDeliveryManager.revoke(credentialID: result.credentialID)
        succeeded = true
        return result
    }

    public func revealAgentTextWrite(
        operationID: String,
        requestID: String,
        capability: String,
        using authenticator: ManagementAuthenticator
    ) throws -> AgentTextWriteAction {
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.revealReason)
        guard let frozen = agentTextWrites.entry(operationID: operationID) else {
            throw BrokerApprovalError.requestNotFound
        }
        let state = try approvalRequests.status(
            requestID: requestID,
            capability: capability,
            operationRequest: frozen.approvalRequest
        )
        guard state == .pending || state == .approved else {
            throw BrokerApprovalError.invalidDecision
        }
        let key = try requireKey()
        switch frozen.mutation {
        case .create(let record):
            return .create(
                name: try VaultCrypto.decrypt(record.encryptedDisplayName, using: key),
                value: try VaultCrypto.decrypt(record.encryptedPayload, using: key)
            )
        case .modify(let record, _):
            return .modify(
                name: try VaultCrypto.decrypt(record.encryptedDisplayName, using: key),
                value: try VaultCrypto.decrypt(record.encryptedPayload, using: key)
            )
        case .delete(let credentialID, _, _):
            guard let record = try store.fetchCredential(id: credentialID) else {
                throw VaultError.credentialNotFound(credentialID)
            }
            return .delete(name: try VaultCrypto.decrypt(record.encryptedDisplayName, using: key))
        }
    }

    private func commitAgentTextWriteSynchronized(
        _ request: AgentTextWriteRequest,
        requestID: String,
        capability: String
    ) throws -> AgentTextWriteResult {
        let digest = try agentTextWriteDigest(request)
        if let committed = try completedAgentTextWrite(
            operationID: request.operationID,
            digest: digest,
            requestID: requestID,
            capability: capability
        ) {
            return committed
        }
        guard let frozen = agentTextWrites.entry(operationID: request.operationID) else {
            throw BrokerApprovalError.requestNotFound
        }
        guard frozen.digest == digest else {
            throw BrokerApprovalError.payloadMismatch
        }
        if let expiresAt = frozen.credentialExpiresAt, expiresAt <= currentDate {
            cancelAgentWrites(credentialID: frozen.approvalRequest.credentialID)
            throw VaultError.credentialUnavailable
        }
        do {
            let result = try approvalRequests.consumeApproved(
                requestID: requestID,
                capability: capability,
                operationRequest: frozen.approvalRequest
            ) {
                try store.commitAgentTextWrite(
                    frozen,
                    requestID: requestID,
                    capabilityDigest: agentTextWriteCapabilityDigest(capability),
                    clock: { currentDate }
                )
            }
            agentTextWrites.remove(operationID: request.operationID)
            brokerRequests.cancelPending(credentialID: result.credentialID)
            approvalRequests.cancelPending(credentialID: result.credentialID)
            notifySnapshotRelevantChange()
            return result
        } catch VaultError.credentialUnavailable {
            cancelAgentWrites(credentialID: frozen.approvalRequest.credentialID)
            throw VaultError.credentialUnavailable
        } catch BrokerApprovalError.alreadyConsumed {
            guard let committed = try completedAgentTextWrite(
                operationID: request.operationID,
                digest: digest,
                requestID: requestID,
                capability: capability
            ) else {
                throw BrokerApprovalError.alreadyConsumed
            }
            return committed
        } catch {
            do {
                let state = try approvalRequests.status(requestID: requestID, capability: capability)
                if state != .pending, state != .approved {
                    agentTextWrites.remove(operationID: request.operationID)
                }
            } catch {
                agentTextWrites.remove(operationID: request.operationID)
            }
            throw error
        }
    }

    private func cancelAgentWrites(credentialID: String) {
        brokerRequests.cancelPending(credentialID: credentialID)
        approvalRequests.cancelPending(credentialID: credentialID)
    }

    private func completedAgentTextWrite(
        operationID: String,
        digest: String,
        requestID: String,
        capability: String
    ) throws -> AgentTextWriteResult? {
        guard let committed = try store.fetchAgentWriteOperation(operationID: operationID) else {
            return nil
        }
        guard committed.payloadDigest == digest else { throw BrokerApprovalError.payloadMismatch }
        guard committed.requestId == requestID,
              committed.capabilityDigest == agentTextWriteCapabilityDigest(capability) else {
            throw BrokerApprovalError.requestNotFound
        }
        return .init(operationID: committed.operationId, credentialID: committed.credentialId)
    }

    public func cancelAgentTextWrite(
        operationID: String,
        requestID: String,
        capability: String
    ) throws -> BrokerRequestState {
        try agentTextWrites.synchronized {
            guard let frozen = agentTextWrites.entry(operationID: operationID) else {
                throw BrokerApprovalError.requestNotFound
            }
            let state = try approvalRequests.cancel(
                requestID: requestID,
                capability: capability,
                operationRequest: frozen.approvalRequest
            )
            if state == .cancelled || state == .denied || state == .expired {
                agentTextWrites.remove(operationID: operationID)
            }
            return state
        }
    }

    public func listRecycledTextCredentials() throws -> [ManagedTextCredential] {
        try requireManagementSession()
        let key = try requireKey()
        return try store.fetchRecycledCredentials()
            .map { try managedCredential(from: $0, key: key, includeSecrets: false) }
    }

    public func restoreRecycledTextCredential(
        id: String,
        using authenticator: ManagementAuthenticator
    ) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        _ = try requireKey()
        try performRecycledCredentialMutation(id: id) { try store.restoreCredential(id: id) }
    }

    public func permanentlyDeleteRecycledTextCredential(
        id: String,
        using authenticator: ManagementAuthenticator
    ) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        _ = try requireKey()
        try performRecycledCredentialMutation(id: id) { try store.deleteRecycledCredential(id: id) }
    }

    @discardableResult
    public func purgeRecycledTextCredentials(
        olderThan now: Date,
        using authenticator: ManagementAuthenticator
    ) throws -> Int {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        _ = try requireKey()
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let removed = try store.purgeRecycledCredentials(
            deletedOnOrBefore: sharedDateFormatter.string(from: cutoff)
        )
        if removed > 0 { notifySnapshotRelevantChange() }
        return removed
    }

    @discardableResult
    public func purgeExpiredRecycledCredentials() throws -> Int {
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        defer { agentAccessGate.endExclusiveChange(paused: wasPaused) }
        let cutoff = currentDate.addingTimeInterval(-30 * 24 * 60 * 60)
        let removed = try store.purgeRecycledCredentials(
            deletedOnOrBefore: sharedDateFormatter.string(from: cutoff)
        )
        if removed > 0 { notifySnapshotRelevantChange() }
        return removed
    }

    private func performRecycledCredentialMutation(
        id: String,
        _ mutation: () throws -> Void
    ) throws {
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        defer { agentAccessGate.endExclusiveChange(paused: wasPaused) }
        try mutation()
        brokerRequests.cancelPending(credentialID: id)
        approvalRequests.cancelPending(credentialID: id)
        notifySnapshotRelevantChange()
    }

    private func freezeAgentTextWrite(
        _ request: AgentTextWriteRequest,
        digest: String,
        key: SymmetricKey,
        files: [BrokerComponentFileReference: BrokerFrozenComponentFile]
    ) throws -> FrozenAgentTextWrite {
        let mutation: FrozenAgentTextMutation
        let credentialID: String
        let credentialExpiresAt: Date?
        let operation: BrokerApprovalOperation
        var beforeRecord: CredentialRecord?
        switch request.action {
        case let .create(name, value):
            credentialID = UUID().uuidString
            let record = try preparedRecord(
                from: .init(name: name, value: value, permission: .ask),
                id: credentialID,
                key: key,
                existing: nil
            )
            mutation = .create(record)
            credentialExpiresAt = nil
            operation = .create
        case let .modify(name, value):
            let existing = try availableTextCredential(
                named: name, key: key,
                callerHint: request.callerName, declaredPurpose: request.callerPurpose
            )
            beforeRecord = existing
            credentialID = existing.id
            credentialExpiresAt = try existing.expiresAt.map { try parseAgentWriteExpiry($0) }
            var updated = existing
            updated.encryptedPayload = try VaultCrypto.encrypt(value, using: key)
            updated.updatedAt = sharedDateFormatter.string(from: currentDate)
            mutation = .modify(updated, expectedUpdatedAt: existing.updatedAt)
            operation = .modify
        case let .createBundle(name, inputs):
            credentialID = UUID().uuidString
            let components = try inputs.map { try componentInput($0, files: files) }
            mutation = .create(try preparedBundleRecord(
                from: .init(name: name, components: components, permission: .ask),
                id: credentialID, key: key, existing: nil))
            credentialExpiresAt = nil
            operation = .create
        case let .modifyBundle(name, changes):
            let existing = try availableTextCredential(named: name, key: key, requiresText: false,
                callerHint: request.callerName, declaredPurpose: request.callerPurpose)
            beforeRecord = existing
            credentialID = existing.id
            credentialExpiresAt = try existing.expiresAt.map { try parseAgentWriteExpiry($0) }
            var components = try credentialComponents(from: existing, key: key)
            var touched = Set<String>()
            for change in changes {
                let rawName: String
                switch change {
                case .upsert(let input): rawName = input.name
                case .remove(let name): rawName = name
                }
                let normalized = CredentialName.normalized(try CredentialName.displayName(from: rawName))
                guard touched.insert(normalized).inserted else { throw BrokerApprovalError.invalidRequest }
                let index = components.firstIndex { CredentialName.normalized($0.name) == normalized }
                switch change {
                case .upsert(let input):
                    let replacement = try componentInput(input, files: files)
                    if let index { components[index] = replacement } else { components.append(replacement) }
                case .remove:
                    guard let index else { throw BrokerApprovalError.invalidRequest }
                    components.remove(at: index)
                }
            }
            components = try CredentialBundleValidator.validatedComponents(components)
            var updated = existing
            updated.payloadKind = CredentialPayloadKind.bundle.rawValue
            updated.encryptedPayload = try VaultCrypto.encrypt(JSONEncoder().encode(components), using: key)
            updated.encryptedEnvironmentVariable = nil
            updated.encryptedOriginalFilename = nil
            updated.byteSize = nil
            updated.contentDigest = nil
            updated.updatedAt = sharedDateFormatter.string(from: currentDate)
            mutation = .modify(updated, expectedUpdatedAt: existing.updatedAt)
            operation = .modify
        case let .delete(name):
            let existing = try availableTextCredential(
                named: name, key: key, requiresText: false,
                callerHint: request.callerName, declaredPurpose: request.callerPurpose
            )
            beforeRecord = existing
            credentialID = existing.id
            credentialExpiresAt = try existing.expiresAt.map { try parseAgentWriteExpiry($0) }
            mutation = .delete(
                credentialID: existing.id,
                expectedUpdatedAt: existing.updatedAt,
                deletedAt: sharedDateFormatter.string(from: currentDate)
            )
            operation = .delete
        }
        let credentialName = try CredentialName.displayName(from: request.action.credentialName)
        let before = try beforeRecord.map { try credentialComponents(from: $0, key: key) } ?? []
        let after: [CredentialComponentInput]
        switch mutation {
        case .create(let record), .modify(let record, _):
            after = try credentialComponents(from: record, key: key)
        case .delete: after = []
        }
        let summary = try componentSummary(name: credentialName, operation: operation, before: before, after: after)
        let approvalDigest = Self.componentDigest(try JSONEncoder().encode([
            digest, credentialID, summary.beforeDigest ?? "", summary.afterDigest ?? ""
        ]))
        let approval = BrokerApprovalOperationRequest(
            operationID: request.operationID,
            credentialID: credentialID,
            targetID: credentialID,
            operation: operation,
            payloadDigest: approvalDigest,
            credentialName: credentialName,
            callerName: request.callerName,
            callerPurpose: request.callerPurpose,
            retransmissionDigest: digest
        )
        return FrozenAgentTextWrite(
            operationID: request.operationID,
            digest: digest,
            approvalRequest: approval,
            credentialExpiresAt: credentialExpiresAt,
            mutation: mutation,
            beforeRecord: beforeRecord,
            summary: summary
        )
    }

    private func availableTextCredential(
        named rawName: String,
        key: SymmetricKey,
        requiresText: Bool = true,
        callerHint: String?,
        declaredPurpose: String?
    ) throws -> CredentialRecord {
        let displayName = try CredentialName.displayName(from: rawName)
        let nameIndex = CredentialIndex.hash(
            normalizedName: CredentialName.normalized(displayName),
            vaultKey: key
        )
        guard let record = try store.fetchCredential(nameIndex: nameIndex),
              let payloadKind = CredentialPayloadKind(rawValue: record.payloadKind),
              (!requiresText || payloadKind == .text),
              let permission = CredentialPermission(rawValue: record.permission),
              permission != .hidden else {
            recordHiddenCredentialGuess(
                callerHint: callerHint,
                declaredPurpose: declaredPurpose
            )
            throw VaultError.credentialUnavailable
        }
        if let expiresAt = record.expiresAt {
            let expiry = try parseAgentWriteExpiry(expiresAt)
            if expiry <= currentDate {
                approvalRequests.cancelPending(credentialID: record.id)
                throw VaultError.credentialUnavailable
            }
        }
        return record
    }

    private func parseAgentWriteExpiry(_ value: String) throws -> Date {
        guard let expiry = sharedDateFormatter.date(from: value) else {
            throw VaultError.databaseError("Credential expiry is not a valid timestamp.")
        }
        return expiry
    }

    private func validateAgentTextWrite(_ request: AgentTextWriteRequest) throws {
        guard request.isBounded else { throw BrokerApprovalError.invalidRequest }
    }

    private func componentInput(_ input: BrokerCredentialComponentInput,
        files: [BrokerComponentFileReference: BrokerFrozenComponentFile]) throws -> CredentialComponentInput {
        let value: CredentialComponentValue
        switch input.value {
        case .text(let text): value = .text(text)
        case .file(let reference):
            guard let file = files[reference] else { throw BrokerApprovalError.invalidRequest }
            value = .file(filename: file.originalFilename, bytes: file.bytes)
        }
        return .init(name: input.name, value: value, delivery: input.delivery, masked: input.masked)
    }

    private static func componentDigest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func componentSummary(name: String, operation: BrokerApprovalOperation,
        before: [CredentialComponentInput], after: [CredentialComponentInput]) throws -> BrokerCredentialWriteSummary {
        func projections(_ inputs: [CredentialComponentInput]) -> [BrokerCredentialComponentSummary] {
            inputs.map { input in
                let kind: BrokerCatalogPayloadKind
                let count: Int
                switch input.value {
                case .text(let text): kind = .text; count = text.utf8.count
                case .file(_, let bytes): kind = .file; count = bytes.count
                }
                return .init(name: input.name, payloadKind: kind, byteCount: count,
                    delivery: input.delivery, masked: input.masked)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return .init(credentialName: name, operation: operation,
            before: projections(before), after: projections(after),
            beforeDigest: before.isEmpty ? nil : Self.componentDigest(try encoder.encode(before)),
            afterDigest: after.isEmpty ? nil : Self.componentDigest(try encoder.encode(after)))
    }

    private func activeFrozenWrite(operationID: String, requestID: String, capability: String) throws -> FrozenAgentTextWrite {
        guard let frozen = agentTextWrites.entry(operationID: operationID) else {
            throw BrokerApprovalError.requestNotFound
        }
        let state = try approvalRequests.status(requestID: requestID, capability: capability,
            operationRequest: frozen.approvalRequest)
        guard state == .pending || state == .approved else { throw BrokerApprovalError.invalidDecision }
        return frozen
    }

    public func frozenAgentWriteSummary(operationID: String, requestID: String, capability: String) throws -> BrokerCredentialWriteSummary {
        let frozen = try activeFrozenWrite(operationID: operationID, requestID: requestID, capability: capability)
        guard let summary = frozen.summary else { throw BrokerApprovalError.invalidRequest }
        return summary
    }

    public func revealFrozenCredentialWrite(operationID: String, requestID: String, capability: String,
        using authenticator: ManagementAuthenticator) throws -> FrozenCredentialWrite {
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.revealReason)
        return try agentTextWrites.synchronized {
            let frozen = try activeFrozenWrite(operationID: operationID, requestID: requestID, capability: capability)
            let key = try requireKey()
            let before = try frozen.beforeRecord.map { try credentialComponents(from: $0, key: key) } ?? []
            let after: [CredentialComponentInput]
            switch frozen.mutation {
            case .create(let record), .modify(let record, _): after = try credentialComponents(from: record, key: key)
            case .delete: after = []
            }
            return .init(credentialName: frozen.approvalRequest.credentialName ?? "", operation: frozen.approvalRequest.operation,
                before: before, after: after)
        }
    }

    private func agentTextWriteDigest(_ request: AgentTextWriteRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(request)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func agentTextWriteCapabilityDigest(_ capability: String) -> String {
        SHA256.hash(data: Data(capability.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension VaultStore {
    func fetchAgentWriteOperation(operationID: String) throws -> AgentWriteOperationRecord? {
        try db.read { db in
            try AgentWriteOperationRecord.fetchOne(db, key: operationID)
        }
    }

    func fetchAgentFileWriteReceipt(requestID: String) throws -> AgentWriteOperationRecord? {
        try db.read { db in
            let records = try AgentWriteOperationRecord.filter(Column("request_id") == requestID).fetchAll(db)
            guard records.count <= 1 else { throw BrokerApprovalError.payloadMismatch }
            return records.first
        }
    }

    func commitAgentTextWrite(
        _ frozen: FrozenAgentTextWrite,
        requestID: String,
        capabilityDigest: String,
        clock: () -> Date,
        resultDigest: String? = nil,
        expectedFileDigest: Data? = nil
    ) throws -> AgentTextWriteResult {
        try db.write { db in
            let committedAt = clock()
            if let existing = try AgentWriteOperationRecord.fetchOne(db, key: frozen.operationID) {
                guard existing.payloadDigest == frozen.digest,
                      existing.resultDigest == resultDigest else {
                    throw BrokerApprovalError.payloadMismatch
                }
                guard existing.requestId == requestID,
                      existing.capabilityDigest == capabilityDigest else {
                    throw BrokerApprovalError.requestNotFound
                }
                return .init(operationID: existing.operationId, credentialID: existing.credentialId)
            }

            let credentialID: String
            let operation: BrokerApprovalOperation
            switch frozen.mutation {
            case let .create(record):
                try credentialForPersistence(record).insert(db)
                credentialID = record.id
                operation = .create
            case let .modify(record, expectedUpdatedAt):
                guard let current = try CredentialRecord.fetchOne(db, key: record.id),
                      current.deletedAt == nil,
                      current.updatedAt == expectedUpdatedAt else {
                    throw VaultError.credentialChanged
                }
                _ = try authenticatedCredential(current)
                if let expectedFileDigest, current.contentDigest != expectedFileDigest {
                    throw VaultError.credentialChanged
                }
                try requireAgentWriteCredentialUnexpired(current, at: committedAt)
                try credentialForPersistence(record).update(db)
                credentialID = record.id
                operation = .modify
            case let .delete(id, expectedUpdatedAt, deletedAt):
                guard let current = try CredentialRecord.fetchOne(db, key: id),
                      current.deletedAt == nil,
                      current.updatedAt == expectedUpdatedAt else {
                    throw VaultError.credentialChanged
                }
                _ = try authenticatedCredential(current)
                try requireAgentWriteCredentialUnexpired(current, at: committedAt)
                var recycled = current
                recycled.deletedAt = deletedAt
                try credentialForPersistence(recycled).update(db)
                credentialID = id
                operation = .delete
            }
            try AgentWriteOperationRecord(
                operationId: frozen.operationID,
                payloadDigest: frozen.digest,
                credentialId: credentialID,
                operation: operation.rawValue,
                committedAt: sharedDateFormatter.string(from: committedAt),
                requestId: requestID,
                capabilityDigest: capabilityDigest,
                resultDigest: resultDigest
            ).insert(db)
            return .init(operationID: frozen.operationID, credentialID: credentialID)
        }
    }

    private func requireAgentWriteCredentialUnexpired(
        _ record: CredentialRecord,
        at now: Date
    ) throws {
        guard let storedExpiry = record.expiresAt else { return }
        guard let expiry = sharedDateFormatter.date(from: storedExpiry) else {
            throw VaultError.databaseError("Credential expiry is not a valid timestamp.")
        }
        guard expiry > now else { throw VaultError.credentialUnavailable }
    }
}
