import Foundation

/// Strict JSON coding for snapshot format version 1. Every object carries
/// exactly its documented keys, absent values are explicit nulls, timestamps
/// are canonical ISO 8601 strings in UTC and file bytes are Base64. Nothing
/// here reuses the library's stored encodings, so the schema can change
/// without changing the format.
extension BackupSnapshot: Codable {
    static func decode(_ data: Data) throws -> BackupSnapshot {
        let snapshot: BackupSnapshot
        do {
            snapshot = try JSONDecoder().decode(BackupSnapshot.self, from: data)
        } catch let issue as BackupContentsIssue {
            throw issue
        } catch {
            throw BackupContentsIssue.malformedDocument
        }
        try snapshot.validate()
        return snapshot
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.backupContainer(keys: ["createdAt", "appVersion", "groups", "credentials"])
        guard let createdAt = BackupTimestamp.date(try container.decode(String.self, forKey: "createdAt")) else {
            throw BackupContentsIssue.malformedDocument
        }
        self.createdAt = createdAt
        appVersion = try container.decode(String.self, forKey: "appVersion")
        groups = try container.decode([String].self, forKey: "groups")
        credentials = try container.decode([CodedCredential].self, forKey: "credentials").map(\.credential)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: BackupCodingKey.self)
        try container.encode(BackupTimestamp.string(createdAt), forKey: "createdAt")
        try container.encode(appVersion, forKey: "appVersion")
        try container.encode(groups, forKey: "groups")
        try container.encode(credentials.map { CodedCredential($0) }, forKey: "credentials")
    }
}

private struct CodedCredential: Codable {
    let credential: BackupSnapshot.Credential

    init(_ credential: BackupSnapshot.Credential) { self.credential = credential }

    init(from decoder: Decoder) throws {
        let container = try decoder.backupContainer(keys: [
            "name", "payloadKind", "components", "usageInstructions", "privateNotes", "group",
            "permission", "expiresAt", "createdAt", "updatedAt", "deletedAt",
        ])
        guard let payloadKind = CredentialPayloadKind(rawValue: try container.decode(String.self, forKey: "payloadKind")) else {
            throw BackupContentsIssue.unknownPayloadKind
        }
        guard let permission = CredentialPermission(rawValue: try container.decode(String.self, forKey: "permission")) else {
            throw BackupContentsIssue.invalidCredential
        }
        credential = .init(
            name: try container.decode(String.self, forKey: "name"),
            payloadKind: payloadKind,
            components: try container.decode([CodedComponent].self, forKey: "components").map(\.component),
            usageInstructions: try container.decode(String.self, forKey: "usageInstructions"),
            privateNotes: try container.decode(String.self, forKey: "privateNotes"),
            groupName: try container.decodeNullable(String.self, forKey: "group"),
            permission: permission,
            expiresAt: try container.decodeNullableTimestamp(forKey: "expiresAt"),
            createdAt: try container.decodeTimestamp(forKey: "createdAt"),
            updatedAt: try container.decodeTimestamp(forKey: "updatedAt"),
            deletedAt: try container.decodeNullableTimestamp(forKey: "deletedAt")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: BackupCodingKey.self)
        try container.encode(credential.name, forKey: "name")
        try container.encode(credential.payloadKind.rawValue, forKey: "payloadKind")
        try container.encode(credential.components.map { CodedComponent($0) }, forKey: "components")
        try container.encode(credential.usageInstructions, forKey: "usageInstructions")
        try container.encode(credential.privateNotes, forKey: "privateNotes")
        try container.encodeNullable(credential.groupName, forKey: "group")
        try container.encode(credential.permission.rawValue, forKey: "permission")
        try container.encodeNullable(credential.expiresAt.map(BackupTimestamp.string), forKey: "expiresAt")
        try container.encode(BackupTimestamp.string(credential.createdAt), forKey: "createdAt")
        try container.encode(BackupTimestamp.string(credential.updatedAt), forKey: "updatedAt")
        try container.encodeNullable(credential.deletedAt.map(BackupTimestamp.string), forKey: "deletedAt")
    }
}

/// `{"name", "value": {"type": "text"|"file", …}, "delivery": {"type", "name"?}, "masked"}`
private struct CodedComponent: Codable {
    let component: CredentialComponentInput

    init(_ component: CredentialComponentInput) { self.component = component }

    init(from decoder: Decoder) throws {
        let container = try decoder.backupContainer(keys: ["name", "value", "delivery", "masked"])
        let value = try container.nestedContainer(keyedBy: BackupCodingKey.self, forKey: "value")
        let decodedValue: CredentialComponentValue
        switch try value.decode(String.self, forKey: "type") {
        case "text":
            try value.requireKeys(["type", "text"])
            decodedValue = .text(try value.decode(String.self, forKey: "text"))
        case "file":
            try value.requireKeys(["type", "filename", "bytes"])
            decodedValue = .file(filename: try value.decode(String.self, forKey: "filename"),
                                 bytes: try value.decode(Data.self, forKey: "bytes"))
        default:
            throw BackupContentsIssue.unknownPayloadKind
        }
        let delivery = try container.nestedContainer(keyedBy: BackupCodingKey.self, forKey: "delivery")
        let decodedDelivery: CredentialComponentDelivery
        switch try delivery.decode(String.self, forKey: "type") {
        case "environmentVariable":
            try delivery.requireKeys(["type", "name"])
            decodedDelivery = .environmentVariable(try delivery.decode(String.self, forKey: "name"))
        case "temporaryFile":
            try delivery.requireKeys(["type", "name"])
            decodedDelivery = .temporaryFile(try delivery.decode(String.self, forKey: "name"))
        case "none":
            try delivery.requireKeys(["type"])
            decodedDelivery = .none
        default:
            throw BackupContentsIssue.malformedDocument
        }
        component = .init(name: try container.decode(String.self, forKey: "name"), value: decodedValue,
                          delivery: decodedDelivery, masked: try container.decode(Bool.self, forKey: "masked"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: BackupCodingKey.self)
        try container.encode(component.name, forKey: "name")
        var value = container.nestedContainer(keyedBy: BackupCodingKey.self, forKey: "value")
        switch component.value {
        case .text(let text):
            try value.encode("text", forKey: "type")
            try value.encode(text, forKey: "text")
        case .file(let filename, let bytes):
            try value.encode("file", forKey: "type")
            try value.encode(filename, forKey: "filename")
            try value.encode(bytes, forKey: "bytes")
        }
        var delivery = container.nestedContainer(keyedBy: BackupCodingKey.self, forKey: "delivery")
        switch component.delivery {
        case .environmentVariable(let name):
            try delivery.encode("environmentVariable", forKey: "type")
            try delivery.encode(name, forKey: "name")
        case .temporaryFile(let name):
            try delivery.encode("temporaryFile", forKey: "type")
            try delivery.encode(name, forKey: "name")
        case .none:
            try delivery.encode("none", forKey: "type")
        }
        try container.encode(component.masked, forKey: "masked")
    }
}

enum BackupTimestamp {
    static func string(_ date: Date) -> String { sharedDateFormatter.string(from: date) }

    /// Accepts only the canonical form `string(_:)` writes.
    static func date(_ string: String) -> Date? {
        guard let date = sharedDateFormatter.date(from: string), sharedDateFormatter.string(from: date) == string else {
            return nil
        }
        return date
    }
}

struct BackupCodingKey: CodingKey, ExpressibleByStringLiteral {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init(stringLiteral value: String) { stringValue = value }
    init?(intValue: Int) { nil }
}

private extension Decoder {
    func backupContainer(keys: Set<String>) throws -> KeyedDecodingContainer<BackupCodingKey> {
        let keyed = try container(keyedBy: BackupCodingKey.self)
        try keyed.requireKeys(keys)
        return keyed
    }
}

private extension KeyedDecodingContainer where Key == BackupCodingKey {
    func requireKeys(_ keys: Set<String>) throws {
        guard Set(allKeys.map(\.stringValue)) == keys else { throw BackupContentsIssue.malformedDocument }
    }

    func decodeNullable<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        try decodeNil(forKey: key) ? nil : decode(type, forKey: key)
    }

    func decodeTimestamp(forKey key: Key) throws -> Date {
        guard let date = BackupTimestamp.date(try decode(String.self, forKey: key)) else {
            throw BackupContentsIssue.invalidCredential
        }
        return date
    }

    func decodeNullableTimestamp(forKey key: Key) throws -> Date? {
        try decodeNil(forKey: key) ? nil : decodeTimestamp(forKey: key)
    }
}

private extension KeyedEncodingContainer where Key == BackupCodingKey {
    mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }
}
