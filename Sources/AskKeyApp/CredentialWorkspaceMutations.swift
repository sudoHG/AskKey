import Foundation
import AskKeyCore

struct CredentialWorkspaceMutations {
    var loadWorkspace: () throws -> (
        credentials: [ManagedTextCredential],
        recycled: [ManagedTextCredential],
        groups: [String],
        accessRecordWriteFailure: Bool
    )
    var createCredentialGroup: (String) throws -> Void
    var deleteCredentialGroup: (String) throws -> Void
    var updateCredentialGroup: (_ id: String, _ groupName: String?) throws -> Void
    var updateCredentialPermission: (_ id: String, _ permission: CredentialPermission) throws -> Void
    var updateCredentialMetadata: (
        _ id: String,
        _ name: String,
        _ usageInstructions: String,
        _ groupName: String?,
        _ permission: CredentialPermission,
        _ expiresAt: Date?
    ) throws -> Void
    var restoreRecycled: (String) throws -> Void
    var permanentlyDeleteRecycled: (String, ManagementAuthenticator) throws -> Void
    var createText: (TextCredentialInput) throws -> Void
    var createBundle: (BundleCredentialInput) throws -> Void
    var updateBundle: (String, BundleCredentialInput) throws -> Void
    var replaceImportedBundle: (String, [CredentialComponentInput], ManagementAuthenticator) throws -> Void
    var updateText: (String, TextCredentialInput) throws -> Void
    var createFile: (FileCredentialInput) throws -> Void
    var updateFile: (String, FileCredentialInput) throws -> Void
    var deleteText: (String) throws -> Void
    var revealText: (String, ManagementAuthenticator) throws -> ManagedTextCredential
    var timedAllowanceDeadline: (String) -> Date?
    var revokeTimedAllowance: (String) -> Bool
    var storedCredentialCount: () throws -> Int
    var accessRecords: CredentialAccessRecordMutations

    func counting(_ count: @escaping () throws -> Int) -> CredentialWorkspaceMutations {
        var copy = self
        copy.storedCredentialCount = count
        return copy
    }

    static let live = CredentialWorkspaceMutations(
        loadWorkspace: {
            _ = try Vault.shared.purgeRecycledTextCredentials(olderThan: Date(), using: .allow)
            return (
                try Vault.shared.listTextCredentials(),
                try Vault.shared.listRecycledTextCredentials(),
                try Vault.shared.listCredentialGroups(),
                try Vault.shared.hasCredentialAccessRecordWriteFailure()
            )
        },
        createCredentialGroup: { try Vault.shared.createCredentialGroup($0, using: .allow) },
        deleteCredentialGroup: { try Vault.shared.deleteCredentialGroup($0, using: .allow) },
        updateCredentialGroup: { id, groupName in
            try Vault.shared.updateCredentialGroup(id: id, groupName: groupName, using: .allow)
        },
        updateCredentialPermission: { id, permission in
            try Vault.shared.updateCredentialPermission(id: id, permission: permission, using: .allow)
        },
        updateCredentialMetadata: { id, name, usageInstructions, groupName, permission, expiresAt in
            try Vault.shared.updateCredentialMetadata(
                id: id,
                name: name,
                usageInstructions: usageInstructions,
                groupName: groupName,
                permission: permission,
                expiresAt: expiresAt,
                using: .allow
            )
        },
        restoreRecycled: { try Vault.shared.restoreRecycledTextCredential(id: $0, using: .allow) },
        permanentlyDeleteRecycled: { id, authenticator in
            try Vault.shared.permanentlyDeleteRecycledTextCredential(id: id, using: authenticator)
        },
        createText: { _ = try Vault.shared.createTextCredential($0, using: .allow) },
        createBundle: { _ = try Vault.shared.createBundleCredential($0, using: .allow) },
        updateBundle: { id, input in
            _ = try Vault.shared.updateBundleCredential(id: id, input, using: .allow)
        },
        replaceImportedBundle: { id, components, authenticator in
            _ = try Vault.shared.replaceImportedBundleCredential(
                id: id,
                components: components,
                using: authenticator
            )
        },
        updateText: { id, input in
            _ = try Vault.shared.updateTextCredential(id: id, input, using: .allow)
        },
        createFile: { _ = try Vault.shared.createFileCredential($0, using: .allow) },
        updateFile: { id, input in
            _ = try Vault.shared.updateFileCredential(id: id, input, using: .allow)
        },
        deleteText: { try Vault.shared.deleteTextCredential(id: $0, using: .allow) },
        revealText: { id, authenticator in
            try Vault.shared.revealTextCredential(id: id, using: authenticator)
        },
        timedAllowanceDeadline: { Vault.shared.approvalRequests.timedAllowanceDeadline(credentialID: $0) },
        revokeTimedAllowance: { Vault.shared.approvalRequests.revokeTimedAllowance(credentialID: $0) },
        storedCredentialCount: { try Vault.shared.storedCredentialCount() },
        accessRecords: .live
    )

    static func readOnly(
        _ loadWorkspace: @escaping () throws -> (
            credentials: [ManagedTextCredential],
            recycled: [ManagedTextCredential],
            groups: [String],
            accessRecordWriteFailure: Bool
        )
    ) -> CredentialWorkspaceMutations {
        func refuse() throws {
            throw VaultError.managementAuthenticationRequired
        }
        func refuseValue<T>() throws -> T {
            throw VaultError.managementAuthenticationRequired
        }
        return CredentialWorkspaceMutations(
            loadWorkspace: loadWorkspace,
            createCredentialGroup: { _ in try refuse() },
            deleteCredentialGroup: { _ in try refuse() },
            updateCredentialGroup: { _, _ in try refuse() },
            updateCredentialPermission: { _, _ in try refuse() },
            updateCredentialMetadata: { _, _, _, _, _, _ in try refuse() },
            restoreRecycled: { _ in try refuse() },
            permanentlyDeleteRecycled: { _, _ in try refuse() },
            createText: { _ in try refuse() },
            createBundle: { _ in try refuse() },
            updateBundle: { _, _ in try refuse() },
            replaceImportedBundle: { _, _, _ in try refuse() },
            updateText: { _, _ in try refuse() },
            createFile: { _ in try refuse() },
            updateFile: { _, _ in try refuse() },
            deleteText: { _ in try refuse() },
            revealText: { _, _ in try refuseValue() },
            timedAllowanceDeadline: { _ in nil },
            revokeTimedAllowance: { _ in false },
            storedCredentialCount: {
                let snapshot = try loadWorkspace()
                return snapshot.credentials.count + snapshot.recycled.count
            },
            accessRecords: .readOnly { [] }
        )
    }
}

struct CredentialAccessRecordMutations {
    var list: () throws -> [CredentialAccessEvent]
    var clear: (ManagementAuthenticator) throws -> Void

    static let live = CredentialAccessRecordMutations(
        list: { try Vault.shared.listCredentialAccessRecords() },
        clear: { try Vault.shared.clearCredentialAccessRecords(using: $0) }
    )

    static let empty = CredentialAccessRecordMutations(
        list: { [] },
        clear: { _ in }
    )

    static func readOnly(
        _ list: @escaping () throws -> [CredentialAccessEvent]
    ) -> CredentialAccessRecordMutations {
        CredentialAccessRecordMutations(
            list: list,
            clear: { _ in throw VaultError.managementAuthenticationRequired }
        )
    }
}
