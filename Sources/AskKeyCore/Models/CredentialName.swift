import CryptoKit
import Foundation
import AskKeyBroker

enum CredentialName {
    static let maximumLength = 255

    static func displayName(from raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maximumLength,
              trimmed.utf8.count <= BrokerLimits.maximumFieldBytes,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw VaultError.invalidCredentialName(raw)
        }
        return trimmed
    }

    static func normalized(_ displayName: String) -> String {
        displayName
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    static func optionalDisplayName(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return try displayName(from: trimmed)
    }
}

enum CredentialIndex {
    static func hash(normalizedName: String, vaultKey: SymmetricKey) -> Data {
        let indexKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: vaultKey,
            salt: Data(),
            info: Data("AskKey vNext name index v1".utf8),
            outputByteCount: 32
        )
        return Data(HMAC<SHA256>.authenticationCode(
            for: Data(normalizedName.utf8),
            using: indexKey
        ))
    }
}

public struct ManagementAuthenticator: Sendable {
    private let confirmImpl: @Sendable (String) -> Bool

    public init(_ confirm: @escaping @Sendable (String) -> Bool) {
        confirmImpl = confirm
    }

    public func confirm(reason: String) -> Bool {
        confirmImpl(reason)
    }

    public static let allow = ManagementAuthenticator { _ in true }
    public static let deny = ManagementAuthenticator { _ in false }
}

public enum CredentialManagementCopy {
    public static let credential = "Credential"
    public static let credentialGroup = "Credential group"
    public static let ungrouped = "Ungrouped"
    public static let ask = "Ask"
    public static let allowed = "Allow"
    public static let hidden = "Hidden"
    public static let manageReason = "Confirm credential management"
    public static let revealReason = "Reveal credential value"
    public static let pauseReason = "Pause Agent access"
    public static let resumeReason = "Resume Agent access"
    public static let usageInstructions = "Usage instructions"
    public static let privateNotes = "Private notes"
    public static let environmentVariable = "Environment variable mapping"
    public static let expires = "Expires"
    public static let text = "Text"
    public static let file = "File"
    public static let originalFilename = "Original filename"
    public static let fileSize = "Size"
    public static let contentDigest = "Digest"
    public static let chooseFile = "Choose file"
    public static let replaceFile = "Replace file"
}

public struct TextCredentialInput: Equatable, Sendable {
    public var name: String
    public var value: String
    public var usageInstructions: String
    public var privateNotes: String
    public var groupName: String?
    public var environmentVariable: String?
    public var permission: CredentialPermission
    public var expiresAt: Date?

    public init(
        name: String,
        value: String,
        usageInstructions: String = "",
        privateNotes: String = "",
        groupName: String? = nil,
        environmentVariable: String? = nil,
        permission: CredentialPermission = .ask,
        expiresAt: Date? = nil
    ) {
        self.name = name
        self.value = value
        self.usageInstructions = usageInstructions
        self.privateNotes = privateNotes
        self.groupName = groupName
        self.environmentVariable = environmentVariable
        self.permission = permission
        self.expiresAt = expiresAt
    }
}

public struct ManagedTextCredential: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let value: String?
    public let usageInstructions: String
    public let privateNotes: String?
    public let groupName: String?
    public let environmentVariable: String?
    public let permission: CredentialPermission
    public let expiresAt: Date?
    public let payloadKind: CredentialPayloadKind
    public let originalFilename: String?
    public let byteSize: Int?
    public let contentDigest: String?
    public let fileBytes: Data?
    public let components: [ManagedCredentialComponent]
    public let deletedAt: Date?

    public init(
        id: String,
        name: String,
        value: String?,
        usageInstructions: String,
        privateNotes: String?,
        groupName: String?,
        environmentVariable: String?,
        permission: CredentialPermission,
        expiresAt: Date?,
        payloadKind: CredentialPayloadKind,
        originalFilename: String?,
        byteSize: Int?,
        contentDigest: String?,
        fileBytes: Data?,
        components: [ManagedCredentialComponent],
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.usageInstructions = usageInstructions
        self.privateNotes = privateNotes
        self.groupName = groupName
        self.environmentVariable = environmentVariable
        self.permission = permission
        self.expiresAt = expiresAt
        self.payloadKind = payloadKind
        self.originalFilename = originalFilename
        self.byteSize = byteSize
        self.contentDigest = contentDigest
        self.fileBytes = fileBytes
        self.components = components
        self.deletedAt = deletedAt
    }

    public var isUngrouped: Bool { groupName == nil }
}

#if DEBUG
public extension ManagedTextCredential {
    static func visualProof(
        id: String,
        name: String,
        componentNames: [String],
        groupName: String? = nil,
        permission: CredentialPermission = .ask,
        deletedAt: Date? = nil
    ) -> Self {
        .init(
            id: id,
            name: name,
            value: nil,
            usageInstructions: "仅用于批准的发布流程",
            privateNotes: nil,
            groupName: groupName,
            environmentVariable: nil,
            permission: permission,
            expiresAt: nil,
            payloadKind: .bundle,
            originalFilename: nil,
            byteSize: nil,
            contentDigest: nil,
            fileBytes: nil,
            components: componentNames.map { .init(name: $0, value: nil) },
            deletedAt: deletedAt
        )
    }
}
#endif

public enum CredentialComponentValue: Codable, Equatable, Sendable {
    case text(String)
    case file(filename: String, bytes: Data)

    public var payloadKind: CredentialPayloadKind {
        switch self {
        case .text: return .text
        case .file: return .file
        }
    }
}

public typealias CredentialComponentDelivery = BrokerComponentDelivery

public struct CredentialComponentInput: Codable, Equatable, Sendable {
    public var name: String
    public var value: CredentialComponentValue
    public var delivery: CredentialComponentDelivery
    public var masked: Bool

    public init(name: String, value: CredentialComponentValue, masked: Bool = true) {
        self.init(name: name, value: value, delivery: Self.defaultDelivery(name: name, value: value), masked: masked)
    }

    public init(
        name: String,
        value: CredentialComponentValue,
        delivery: CredentialComponentDelivery,
        masked: Bool = true
    ) {
        self.name = name
        self.value = value
        self.delivery = delivery
        self.masked = masked
    }

    private enum CodingKeys: String, CodingKey { case name, value, delivery, masked }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(CredentialComponentValue.self, forKey: .value)
        delivery = try container.decodeIfPresent(CredentialComponentDelivery.self, forKey: .delivery)
            ?? Self.defaultDelivery(name: name, value: value)
        masked = try container.decodeIfPresent(Bool.self, forKey: .masked) ?? true
    }

    private static func defaultDelivery(name: String, value: CredentialComponentValue) -> CredentialComponentDelivery {
        switch value {
        case .text: return .environmentVariable(name)
        case .file: return .temporaryFile(name)
        }
    }
}

public enum CredentialBundleValidator {
    public static let maximumComponents = 64
    public static let maximumMaterialBytes = 5 * 1024 * 1024

    public static func validatedComponents(
        _ components: [CredentialComponentInput]
    ) throws -> [CredentialComponentInput] {
        guard !components.isEmpty, components.count <= maximumComponents else {
            throw VaultError.databaseError("A credential must contain between 1 and 64 components.")
        }
        var names = Set<String>()
        var environmentNames = Set<String>()
        var materialBytes = 0
        return try components.map { component in
            let name = try CredentialName.displayName(from: component.name)
            guard names.insert(CredentialName.normalized(name)).inserted else {
                throw VaultError.databaseError("Credential component names must be unique.")
            }
            let value: CredentialComponentValue
            let byteCount: Int
            switch component.value {
            case .text(let text):
                value = component.value
                byteCount = text.utf8.count
            case .file(let filename, let bytes):
                let frozen = try FileImport.FrozenFile(originalFilename: filename, bytes: bytes)
                value = .file(filename: frozen.originalFilename, bytes: frozen.bytes)
                byteCount = bytes.count
            }
            guard byteCount <= maximumMaterialBytes - materialBytes else {
                throw VaultError.databaseError("Credential material exceeds the 5 MiB size limit.")
            }
            materialBytes += byteCount
            if let variable = component.delivery.environmentVariable {
                try CredentialFieldValidation.environmentVariable(variable)
                guard environmentNames.insert(variable).inserted else {
                    throw VaultError.databaseError("Credential delivery mappings must use unique environment variables.")
                }
            }
            if case .environmentVariable = component.delivery, case .file = value {
                throw VaultError.databaseError("File components must use a temporary file mapping or remain undelivered.")
            }
            return CredentialComponentInput(name: name, value: value, delivery: component.delivery, masked: component.masked)
        }
    }
}

public struct ManagedCredentialComponent: Equatable, Sendable {
    public let name: String
    public let kind: CredentialPayloadKind
    public let value: CredentialComponentValue?
    public let delivery: CredentialComponentDelivery
    public let masked: Bool

    public init(name: String, kind: CredentialPayloadKind? = nil, value: CredentialComponentValue?, masked: Bool = true) {
        let resolvedKind = kind ?? Self.kind(for: value)
        self.init(name: name, kind: resolvedKind, value: value,
            delivery: resolvedKind == .file ? .temporaryFile(name) : .environmentVariable(name), masked: masked)
    }

    public init(
        name: String,
        kind: CredentialPayloadKind? = nil,
        value: CredentialComponentValue?,
        delivery: CredentialComponentDelivery,
        masked: Bool = true
    ) {
        self.name = name
        self.kind = kind ?? Self.kind(for: value)
        self.value = value
        self.delivery = delivery
        self.masked = masked
    }

    private static func kind(for value: CredentialComponentValue?) -> CredentialPayloadKind {
        if case .file = value { return .file }
        return .text
    }
}

public struct BundleCredentialInput: Equatable, Sendable {
    public var name: String
    public var components: [CredentialComponentInput]
    public var usageInstructions: String
    public var privateNotes: String
    public var groupName: String?
    public var permission: CredentialPermission
    public var expiresAt: Date?

    public init(
        name: String,
        components: [CredentialComponentInput],
        usageInstructions: String = "",
        privateNotes: String = "",
        groupName: String? = nil,
        permission: CredentialPermission = .ask,
        expiresAt: Date? = nil
    ) {
        self.name = name
        self.components = components
        self.usageInstructions = usageInstructions
        self.privateNotes = privateNotes
        self.groupName = groupName
        self.permission = permission
        self.expiresAt = expiresAt
    }
}

public struct FileCredentialInput: Equatable, Sendable {
    public var name: String
    public var snapshot: FileImport.FrozenFile?
    public var usageInstructions: String
    public var privateNotes: String
    public var groupName: String?
    public var environmentVariable: String?
    public var permission: CredentialPermission
    public var expiresAt: Date?

    public init(
        name: String,
        snapshot: FileImport.FrozenFile? = nil,
        usageInstructions: String = "",
        privateNotes: String = "",
        groupName: String? = nil,
        environmentVariable: String? = nil,
        permission: CredentialPermission = .ask,
        expiresAt: Date? = nil
    ) {
        self.name = name
        self.snapshot = snapshot
        self.usageInstructions = usageInstructions
        self.privateNotes = privateNotes
        self.groupName = groupName
        self.environmentVariable = environmentVariable
        self.permission = permission
        self.expiresAt = expiresAt
    }
}
