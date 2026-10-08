import Foundation

/// Shared wire/storage vocabulary. Values never appear in catalog projections.
public enum BrokerComponentDelivery: Codable, Equatable, Sendable {
    case environmentVariable(String)
    case temporaryFile(String)
    case none

    public var environmentVariable: String? {
        switch self {
        case .environmentVariable(let name), .temporaryFile(let name): return name
        case .none: return nil
        }
    }
}

public struct BrokerCatalogComponent: Codable, Equatable, Sendable {
    public let name: String
    public let payloadKind: BrokerCatalogPayloadKind
    public let delivery: BrokerComponentDelivery

    public init(name: String, payloadKind: BrokerCatalogPayloadKind, delivery: BrokerComponentDelivery) {
        self.name = name
        self.payloadKind = payloadKind
        self.delivery = delivery
    }
}

public struct BrokerComponentFileReference: Codable, Equatable, Sendable, Hashable {
    public let uploadID: String
    public let capability: String
    public let digest: String

    public init(uploadID: String, capability: String, digest: String) {
        self.uploadID = uploadID
        self.capability = capability
        self.digest = digest
    }
}

public struct BrokerComponentUploadBeginRequest: Codable, Equatable, Sendable {
    public let operationID: String
    public let originalFilename: String
    public let expectedByteCount: Int

    public init(operationID: String, originalFilename: String, expectedByteCount: Int) {
        self.operationID = operationID
        self.originalFilename = originalFilename
        self.expectedByteCount = expectedByteCount
    }
}

/// App-memory material. This is deliberately not Codable and cannot be a Broker
/// response. References to it are capability/digest/operation-bound.
public struct BrokerFrozenComponentFile: Equatable, Sendable {
    public let originalFilename: String
    public let bytes: Data
    public let digest: String

    public init(originalFilename: String, bytes: Data, digest: String) {
        self.originalFilename = originalFilename
        self.bytes = bytes
        self.digest = digest
    }
}

public enum BrokerCredentialComponentValue: Codable, Equatable, Sendable {
    case text(String)
    case file(BrokerComponentFileReference)
}

public struct BrokerCredentialComponentInput: Codable, Equatable, Sendable {
    public let name: String
    public let value: BrokerCredentialComponentValue
    public let delivery: BrokerComponentDelivery
    public let masked: Bool

    public init(name: String, value: BrokerCredentialComponentValue, delivery: BrokerComponentDelivery, masked: Bool = true) {
        self.name = name
        self.value = value
        self.delivery = delivery
        self.masked = masked
    }
}

public enum BrokerCredentialComponentChange: Codable, Equatable, Sendable {
    case upsert(BrokerCredentialComponentInput)
    case remove(String)
}

/// Nil on the action preserves the group; Ungrouped explicitly clears it.
public enum BrokerCredentialGroupChange: Codable, Equatable, Sendable {
    case named(String)
    case ungrouped
}

public struct BrokerCredentialComponentSummary: Equatable, Sendable {
    public let name: String
    public let payloadKind: BrokerCatalogPayloadKind
    public let byteCount: Int
    public let delivery: BrokerComponentDelivery
    public let masked: Bool

    public init(name: String, payloadKind: BrokerCatalogPayloadKind, byteCount: Int, delivery: BrokerComponentDelivery, masked: Bool) {
        self.name = name
        self.payloadKind = payloadKind
        self.byteCount = byteCount
        self.delivery = delivery
        self.masked = masked
    }
}

/// App-only approval projection; no credential values or upload capabilities.
public struct BrokerCredentialWriteSummary: Equatable, Sendable {
    public let credentialName: String
    public let operation: BrokerApprovalOperation
    public let before: [BrokerCredentialComponentSummary]
    public let after: [BrokerCredentialComponentSummary]
    public let beforeDigest: String?
    public let afterDigest: String?
    public let beforeUsageInstructions: String?
    public let afterUsageInstructions: String?
    public let beforeGroup: String?
    public let afterGroup: String?
    public let createsGroup: Bool

    public init(credentialName: String, operation: BrokerApprovalOperation,
                before: [BrokerCredentialComponentSummary], after: [BrokerCredentialComponentSummary],
                beforeDigest: String?, afterDigest: String?,
                beforeUsageInstructions: String? = nil, afterUsageInstructions: String? = nil,
                beforeGroup: String? = nil, afterGroup: String? = nil, createsGroup: Bool = false) {
        self.credentialName = credentialName
        self.operation = operation
        self.before = before
        self.after = after
        self.beforeDigest = beforeDigest
        self.afterDigest = afterDigest
        self.beforeUsageInstructions = beforeUsageInstructions
        self.afterUsageInstructions = afterUsageInstructions
        self.beforeGroup = beforeGroup
        self.afterGroup = afterGroup
        self.createsGroup = createsGroup
    }
}

public extension AgentTextWriteAction {
    var operation: BrokerApprovalOperation {
        switch self {
        case .create, .createBundle: return .create
        case .modify, .modifyBundle: return .modify
        case .delete: return .delete
        case .organize: return .organize
        }
    }

    var credentialName: String {
        switch self {
        case .create(let name, _), .modify(let name, _), .delete(let name),
             .createBundle(let name, _, _, _), .modifyBundle(let name, _, _, _): return name
        case .organize: return ""
        }
    }
}

public extension AgentTextWriteRequest {
    var componentFileReferences: [BrokerComponentFileReference] {
        let components: [BrokerCredentialComponentInput]
        switch action {
        case .createBundle(_, let inputs, _, _): components = inputs
        case .modifyBundle(_, let changes, _, _):
            components = changes.compactMap { if case .upsert(let input) = $0 { return input }; return nil }
        default: components = []
        }
        return components.compactMap { if case .file(let reference) = $0.value { return reference }; return nil }
    }

    var isBounded: Bool {
        if case .organize(let operations) = action {
            return !operationID.isEmpty && !operations.isEmpty && operations.count <= 64
                && operations.allSatisfy(\.isBounded)
                && [operationID, callerName, callerPurpose].compactMap { $0 }
                    .allSatisfy { $0.utf8.count <= BrokerLimits.maximumFieldBytes }
        }
        var fields = [operationID, action.credentialName, callerName, callerPurpose].compactMap { $0 }
        guard !operationID.isEmpty, !action.credentialName.isEmpty else { return false }
        func add(_ component: BrokerCredentialComponentInput) -> Bool {
            guard !component.name.isEmpty else { return false }
            fields.append(component.name)
            if let variable = component.delivery.environmentVariable { fields.append(variable) }
            switch component.value {
            case .text(let value): fields.append(value)
            case .file(let reference):
                guard !reference.uploadID.isEmpty, !reference.capability.isEmpty,
                      reference.digest.utf8.count == 64,
                      reference.digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
                fields += [reference.uploadID, reference.capability, reference.digest]
            }
            return true
        }
        switch action {
        case .create(_, let value), .modify(_, let value): fields.append(value)
        case .delete: break
        case .organize: return false // Handled above, without a single-credential name.
        case .createBundle(_, let components, let instructions, let group):
            guard !components.isEmpty, components.count <= 64, components.allSatisfy(add) else { return false }
            fields += [instructions, group].compactMap { $0 }
        case .modifyBundle(_, let changes, let instructions, let group):
            guard (!changes.isEmpty || instructions != nil || group != nil), changes.count <= 64 else { return false }
            if let instructions { fields.append(instructions) }
            if case .named(let name) = group { fields.append(name) }
            for change in changes {
                switch change {
                case .upsert(let component): guard add(component) else { return false }
                case .remove(let name): guard !name.isEmpty else { return false }; fields.append(name)
                }
            }
        }
        return fields.allSatisfy { $0.utf8.count <= BrokerLimits.maximumFieldBytes }
    }
}
