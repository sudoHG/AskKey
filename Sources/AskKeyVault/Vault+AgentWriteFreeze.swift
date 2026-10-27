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
        var before: [BrokerCredentialComponentSummary] = []
        var after: [BrokerCredentialComponentSummary] = []
        var proposed: [CredentialComponentInput] = []
        var componentChanges: [FrozenAgentComponentChange] = []
        var permitsLegacyTextReveal = false
        switch request.action {
        case .organize: throw BrokerApprovalError.invalidRequest
        case let .create(name, value):
            permitsLegacyTextReveal = true
            credentialID = UUID().uuidString
            let record = try preparedRecord(
                from: .init(name: name, value: value, permission: .ask),
                id: credentialID,
                key: key,
                existing: nil,
                checkNameAvailability: false
            )
            mutation = .create(record)
            proposed = [.init(name: "VALUE", value: .text(value), delivery: .none)]
            credentialExpiresAt = nil
            operation = .create
        case let .modify(name, value):
            permitsLegacyTextReveal = true
            let existing = try availableTextCredential(
                named: name, key: key,
                callerHint: request.callerName, declaredPurpose: request.callerPurpose
            )
            beforeRecord = existing
            before = try storedComponentSummaries(existing, key: key)
            credentialID = existing.id
            credentialExpiresAt = try existing.expiresAt.map { try parseAgentWriteExpiry($0) }
            var updated = existing
            updated.encryptedPayload = try VaultCrypto.encrypt(value, using: key)
            updated.updatedAt = sharedDateFormatter.string(from: currentDate)
            mutation = .modify(updated, expectedUpdatedAt: existing.updatedAt)
            let metadata = try CredentialComponentMetadata.read(from: existing, using: key)
            proposed = [.init(name: metadata.components[0].name, value: .text(value),
                delivery: metadata.components[0].delivery)]
            operation = .modify
        case let .createBundle(name, inputs, instructions, group):
            credentialID = UUID().uuidString
            let components = try CredentialBundleValidator.validatedComponents(inputs.map { try componentInput($0, files: files) })
            proposed = components
            if let group {
                (groupAssignment, createsGroup) = try resolvedAgentGroup(group, key: key)
            }
            mutation = .create(try preparedBundleRecord(
                from: .init(name: name, components: components, usageInstructions: instructions ?? "",
                    groupName: groupAssignment, permission: .ask),
                id: credentialID, key: key, existing: nil, checkNameAvailability: false))
            credentialExpiresAt = nil
            operation = .create
        case let .modifyBundle(name, changes, instructions, group):
            let existing = try availableTextCredential(named: name, key: key, requiresText: false,
                callerHint: request.callerName, declaredPurpose: request.callerPurpose)
            beforeRecord = existing
            before = try storedComponentSummaries(existing, key: key)
            credentialID = existing.id
            credentialExpiresAt = try existing.expiresAt.map { try parseAgentWriteExpiry($0) }
            componentChanges = try changes.map { change in
                switch change {
                case .upsert(let input):
                    let validated = try CredentialBundleValidator.validatedComponents([componentInput(input, files: files)])
                    return .upsert(validated[0])
                case .remove(let name): return .remove(try CredentialName.displayName(from: name))
                }
            }
            proposed = componentChanges.compactMap { if case .upsert(let input) = $0 { return input }; return nil }
            after = try FrozenAgentComponentChange.applying(componentChanges, to: before,
                name: { $0.name }, replacement: { proposedComponentSummary($0, key: key) })
            try validateComponentSummary(after)
            var updated = existing
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
            before = try storedComponentSummaries(existing, key: key)
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
        let afterRecord: CredentialRecord?
        switch mutation {
        case .create(let record), .modify(let record, _):
            afterRecord = record
        case .delete: after = []; afterRecord = nil
        }
        switch request.action {
        case .modifyBundle: break
        default: after = proposed.map { proposedComponentSummary($0, key: key) }
        }
        let beforeStateDigest = try beforeRecord?.agentWriteStateDigest()
        let summary = try componentSummary(name: credentialName, operation: operation, before: before, after: after,
            proposed: proposed, beforeRecord: beforeRecord, afterRecord: afterRecord, createsGroup: createsGroup, key: key)
        let approvalDigest = Self.componentDigest(try JSONEncoder().encode([
            digest, credentialID, beforeStateDigest, summary.afterDigest,
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
            groupAssignment: groupAssignment,
            beforeStateDigest: beforeStateDigest,
            componentChanges: componentChanges,
            permitsLegacyTextReveal: permitsLegacyTextReveal
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
                approvalRequests.cancelPendingForExpiry(credentialID: record.id)
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

    private func storedComponentSummaries(_ record: CredentialRecord, key: SymmetricKey) throws -> [BrokerCredentialComponentSummary] {
        try store.requireComponentMetadata()
        return try CredentialComponentMetadata.read(from: record, using: key).components.map {
            .init(name: $0.name, payloadKind: $0.payloadKind == .file ? .file : .text,
                byteCount: nil, delivery: $0.delivery, masked: nil, valueChanged: false)
        }
    }

    private func validateComponentSummary(_ components: [BrokerCredentialComponentSummary]) throws {
        guard !components.isEmpty, components.count <= CredentialBundleValidator.maximumComponents else {
            throw VaultError.databaseError("A credential must contain between 1 and 64 components.")
        }
        var variables = Set<String>()
        for component in components {
            if let variable = component.delivery.environmentVariable {
                try CredentialFieldValidation.environmentVariable(variable)
                guard variables.insert(variable).inserted else {
                    throw VaultError.databaseError("Credential delivery mappings must use unique environment variables.")
                }
            }
            if case .environmentVariable = component.delivery, component.payloadKind == .file {
                throw VaultError.databaseError("File components must use a temporary file mapping or remain undelivered.")
            }
        }
    }

    private func proposedComponentSummary(_ input: CredentialComponentInput, key: SymmetricKey) -> BrokerCredentialComponentSummary {
        // Only proposed values are available before approval. These keyed
        // digests are presentation-only and never include stored plaintext.
        let digestKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(),
            info: Data("AskKey approval component value digest v1".utf8), outputByteCount: 32)
        func valueDigest(_ value: CredentialComponentValue) -> String {
            func field(_ bytes: Data) -> Data { withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { Data($0) } + bytes }
            let material: Data
            switch value {
            case .text(let text): material = Data("text".utf8) + field(Data(text.utf8))
            case .file(let filename, let bytes): material = Data("file".utf8) + field(Data(filename.utf8)) + field(bytes)
            }
            return Data(HMAC<SHA256>.authenticationCode(for: material, using: digestKey))
                .map { String(format: "%02x", $0) }.joined()
        }
        let kind: BrokerCatalogPayloadKind
        let count: Int
        switch input.value {
        case .text(let text): kind = .text; count = text.utf8.count
        case .file(_, let bytes): kind = .file; count = bytes.count
        }
        return .init(name: input.name, payloadKind: kind, byteCount: count,
            delivery: input.delivery, masked: input.masked, valueDigest: valueDigest(input.value), valueChanged: true)
    }

    private func componentSummary(name: String, operation: BrokerApprovalOperation,
        before: [BrokerCredentialComponentSummary], after: [BrokerCredentialComponentSummary], proposed: [CredentialComponentInput],
        beforeRecord: CredentialRecord?, afterRecord: CredentialRecord?, createsGroup: Bool,
        key: SymmetricKey) throws -> BrokerCredentialWriteSummary {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return .init(credentialName: name, operation: operation,
            before: before, after: after,
            beforeDigest: nil,
            afterDigest: proposed.isEmpty ? nil : Self.componentDigest(try encoder.encode(proposed)),
            beforeUsageInstructions: try beforeRecord.map { try VaultCrypto.decrypt($0.encryptedUsageInstructions, using: key) },
            afterUsageInstructions: try afterRecord.map { try VaultCrypto.decrypt($0.encryptedUsageInstructions, using: key) },
            beforeGroup: try beforeRecord?.encryptedGroupName.map { try VaultCrypto.decrypt($0, using: key) },
            afterGroup: try afterRecord?.encryptedGroupName.map { try VaultCrypto.decrypt($0, using: key) },
            createsGroup: createsGroup)
    }
}
