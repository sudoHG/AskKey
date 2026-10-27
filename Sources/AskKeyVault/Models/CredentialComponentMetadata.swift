import CryptoKit
import Foundation

/// Only the projection needed for discovery and approval; never contains material.
struct CredentialComponentMetadata: Codable, Equatable {
    struct Component: Codable, Equatable {
        let name: String
        let payloadKind: CredentialPayloadKind
        let delivery: CredentialComponentDelivery
    }

    let version: Int
    let components: [Component]

    init(components: [CredentialComponentInput]) {
        version = 1
        self.components = components.map {
            Component(name: $0.name, payloadKind: $0.value.payloadKind, delivery: $0.delivery)
        }
    }

    init(singleKind: CredentialPayloadKind, mapping: String?) {
        version = 1
        let fallback = singleKind == .file ? "FILE" : "VALUE"
        let name = mapping.flatMap { try? CredentialName.displayName(from: $0) } ?? fallback
        let delivery: CredentialComponentDelivery = mapping.map {
            singleKind == .file ? .temporaryFile($0) : .environmentVariable($0)
        } ?? .none
        components = [Component(name: name, payloadKind: singleKind, delivery: delivery)]
    }

    func encrypted(using key: SymmetricKey) throws -> Data {
        try VaultCrypto.encrypt(JSONEncoder().encode(self), using: key)
    }

    /// Historical payloads need no delivery-time value, filename or size checks
    /// to recover their projection. Single-material payloads are never opened.
    init(backfilling record: CredentialRecord, using key: SymmetricKey) throws {
        guard let kind = CredentialPayloadKind(rawValue: record.payloadKind) else {
            throw CredentialRecordAuthenticationError.invalidAuthentication
        }
        if kind == .bundle {
            self.init(projections: try JSONDecoder().decode([LegacyComponent].self,
                from: VaultCrypto.decryptData(record.encryptedPayload, using: key)).map(\.projection))
        } else {
            self.init(singleKind: kind, mapping: try record.encryptedEnvironmentVariable.map {
                try VaultCrypto.decrypt($0, using: key)
            })
        }
        try validate()
    }

    private init(projections: [Component]) {
        version = 1
        components = projections
    }

    private struct LegacyComponent: Decodable {
        let projection: Component
        private enum CodingKeys: String, CodingKey { case name, value, delivery }
        private enum ValueKeys: String, CodingKey { case text, file }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            let name = try fields.decode(String.self, forKey: .name)
            let value = try fields.nestedContainer(keyedBy: ValueKeys.self, forKey: .value)
            guard value.allKeys.count == 1, let valueKind = value.allKeys.first else {
                throw CredentialRecordAuthenticationError.invalidAuthentication
            }
            let kind: CredentialPayloadKind = valueKind == .file ? .file : .text
            let delivery = try fields.decodeIfPresent(CredentialComponentDelivery.self, forKey: .delivery)
                ?? (kind == .file ? .temporaryFile(name) : .environmentVariable(name))
            projection = Component(name: name, payloadKind: kind, delivery: delivery)
        }
    }

    static func read(from record: CredentialRecord, using key: SymmetricKey) throws -> Self {
        do {
            guard let encrypted = record.encryptedComponentMetadata else {
                throw CredentialRecordAuthenticationError.invalidAuthentication
            }
            let metadata = try JSONDecoder().decode(Self.self, from: VaultCrypto.decryptData(encrypted, using: key))
            try metadata.validate()
            guard let kind = CredentialPayloadKind(rawValue: record.payloadKind),
                  kind == .bundle || (metadata.components.count == 1 && metadata.components[0].payloadKind == kind) else {
                throw CredentialRecordAuthenticationError.invalidAuthentication
            }
            return metadata
        } catch {
            // Same fail-closed error as an unauthenticated credential row.
            throw CredentialRecordAuthenticationError.invalidAuthentication
        }
    }

    private func validate() throws {
        guard version == 1, !components.isEmpty,
              components.count <= CredentialBundleValidator.maximumComponents else {
            throw CredentialRecordAuthenticationError.invalidAuthentication
        }
        var names = Set<String>()
        var variables = Set<String>()
        for component in components {
            guard try CredentialName.displayName(from: component.name) == component.name,
                  names.insert(CredentialName.normalized(component.name)).inserted,
                  component.payloadKind != .bundle else {
                throw CredentialRecordAuthenticationError.invalidAuthentication
            }
            if let variable = component.delivery.environmentVariable {
                try CredentialFieldValidation.environmentVariable(variable)
                guard variables.insert(variable).inserted else {
                    throw CredentialRecordAuthenticationError.invalidAuthentication
                }
            }
            if case .environmentVariable = component.delivery, component.payloadKind == .file {
                throw CredentialRecordAuthenticationError.invalidAuthentication
            }
        }
    }
}
