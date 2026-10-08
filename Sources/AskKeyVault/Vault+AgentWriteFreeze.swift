import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    func freezeAgentTextWrite(
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
        var groupAssignment: String?
        var createsGroup = false
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
        case let .createBundle(name, inputs, instructions, group):
            credentialID = UUID().uuidString
            let components = try inputs.map { try componentInput($0, files: files) }
            if let group {
                (groupAssignment, createsGroup) = try resolvedAgentGroup(group, key: key)
            }
            mutation = .create(try preparedBundleRecord(
                from: .init(name: name, components: components, usageInstructions: instructions ?? "",
                    groupName: groupAssignment, permission: .ask),
                id: credentialID, key: key, existing: nil))
            credentialExpiresAt = nil
            operation = .create
        case let .modifyBundle(name, changes, instructions, group):
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
            if !changes.isEmpty {
                updated.payloadKind = CredentialPayloadKind.bundle.rawValue
                updated.encryptedPayload = try VaultCrypto.encrypt(JSONEncoder().encode(components), using: key)
                updated.encryptedEnvironmentVariable = nil
                updated.encryptedOriginalFilename = nil
                updated.byteSize = nil
                updated.contentDigest = nil
            }
            if let instructions {
                try CredentialFieldValidation.usageInstructions(instructions)
                updated.encryptedUsageInstructions = try VaultCrypto.encrypt(instructions, using: key)
            }
            switch group {
            case .named(let name):
                (groupAssignment, createsGroup) = try resolvedAgentGroup(name, key: key)
                updated.encryptedGroupName = try groupAssignment.map { try VaultCrypto.encrypt($0, using: key) }
            case .ungrouped: updated.encryptedGroupName = nil
            case nil: break
            }
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
        let afterRecord: CredentialRecord?
        switch mutation {
        case .create(let record), .modify(let record, _):
            after = try credentialComponents(from: record, key: key)
            afterRecord = record
        case .delete: after = []; afterRecord = nil
        }
        let summary = try componentSummary(name: credentialName, operation: operation, before: before, after: after,
            beforeRecord: beforeRecord, afterRecord: afterRecord, createsGroup: createsGroup, key: key)
        let approvalDigest = Self.componentDigest(try JSONEncoder().encode([
            digest, credentialID, summary.beforeDigest, summary.afterDigest,
            summary.beforeUsageInstructions, summary.afterUsageInstructions,
            summary.beforeGroup, summary.afterGroup, String(createsGroup)
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
            summary: summary,
            groupAssignment: groupAssignment
        )
    }

    private func resolvedAgentGroup(_ rawName: String, key: SymmetricKey) throws -> (String, Bool) {
        let name = try CredentialName.displayName(from: rawName)
        let normalized = CredentialName.normalized(name)
        if let existing = try credentialGroupNames(key: key).first(where: { CredentialName.normalized($0) == normalized }) {
            return (existing, false)
        }
        return (name, true)
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

    static func componentDigest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func componentSummary(name: String, operation: BrokerApprovalOperation,
        before: [CredentialComponentInput], after: [CredentialComponentInput],
        beforeRecord: CredentialRecord?, afterRecord: CredentialRecord?, createsGroup: Bool,
        key: SymmetricKey) throws -> BrokerCredentialWriteSummary {
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
            afterDigest: after.isEmpty ? nil : Self.componentDigest(try encoder.encode(after)),
            beforeUsageInstructions: try beforeRecord.map { try VaultCrypto.decrypt($0.encryptedUsageInstructions, using: key) },
            afterUsageInstructions: try afterRecord.map { try VaultCrypto.decrypt($0.encryptedUsageInstructions, using: key) },
            beforeGroup: try beforeRecord?.encryptedGroupName.map { try VaultCrypto.decrypt($0, using: key) },
            afterGroup: try afterRecord?.encryptedGroupName.map { try VaultCrypto.decrypt($0, using: key) },
            createsGroup: createsGroup)
    }
}
