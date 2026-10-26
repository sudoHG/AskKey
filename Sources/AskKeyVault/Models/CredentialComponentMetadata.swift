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
