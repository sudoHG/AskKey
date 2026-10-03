import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
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
}
