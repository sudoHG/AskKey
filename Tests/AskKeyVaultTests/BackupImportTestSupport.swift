import Foundation
import XCTest
@testable import AskKeyVault

/// The App's English rename suffix: "(from backup)", then "(from backup 2)" and so on.
func backupRenameSuffix(_ number: Int) -> String {
    number == 1 ? "(from backup)" : "(from backup \(number))"
}

/// Everything a person can see of a library: every credential with its
/// revealed values, the Recycle Bin and the groups.
struct BackupImportLibraryView: Equatable {
    let active: [ManagedTextCredential]
    let recycled: [ManagedTextCredential]
    let groups: [String]

    /// Needs an active management session.
    init(_ vault: Vault) throws {
        active = try vault.listTextCredentials().map { try vault.revealTextCredential(id: $0.id, using: .allow) }
        recycled = try vault.listRecycledTextCredentials().sorted { $0.name < $1.name }
        groups = try vault.listCredentialGroups()
    }

    func credential(named name: String, file: StaticString = #filePath, line: UInt = #line) throws -> ManagedTextCredential {
        try XCTUnwrap((active + recycled).first { $0.name == name }, name, file: file, line: line)
    }
}

/// Counts catalog-change notifications posted while it is alive.
final class CatalogChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = 0
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .askKeyCredentialSnapshotDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            lock.lock(); observed += 1; lock.unlock()
        }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return observed
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }
}

class BackupImportTestCase: XCTestCase {
    private var libraries: [AgentAccessPolicyLibrary] = []

    override func tearDownWithError() throws {
        for library in libraries { try library.close() }
        libraries = []
    }

    func makeLibrary(now: @escaping () -> Date = Date.init) throws -> AgentAccessPolicyLibrary {
        let library = try AgentAccessPolicyLibrary(now: now)
        libraries.append(library)
        return library
    }

    /// A library holding `credentials`, created through the App's operations,
    /// with an active management session.
    func makeLibrary(with credentials: [SyntheticCredential], groups: [String] = [],
                     now: @escaping () -> Date = Date.init) throws -> AgentAccessPolicyLibrary {
        let library = try makeLibrary(now: now)
        try library.vault.beginManagementSession(using: .allow)
        for credential in credentials { try credential.create(in: library.vault) }
        for group in groups { try library.vault.createCredentialGroup(group, using: .allow) }
        return library
    }

    func plan(_ export: BackupExport, into vault: Vault,
              renameSuffix: (Int) -> String = backupRenameSuffix) throws -> BackupImportPlan {
        try vault.planBackupImport(export.fileBytes, recoveryKey: export.recoveryKey.groupedText,
                                   renameSuffix: renameSuffix)
    }

    func renames(_ additions: [BackupImportAddition]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: additions.map { ($0.backupName, $0.name) })
    }
}

/// A synthetic credential for building source and target libraries.
struct SyntheticCredential {
    enum Material {
        case text(String, mapping: String? = nil)
        case file(filename: String, bytes: Data, mapping: String? = nil)
        case bundle([CredentialComponentInput])
    }

    var name: String
    var material: Material
    var usage = ""
    var notes = ""
    var group: String?
    var permission: CredentialPermission = .ask
    var expiresAt: Date?
    var recycled = false

    static func text(_ name: String, _ value: String, notes: String = "", group: String? = nil,
                     permission: CredentialPermission = .ask, recycled: Bool = false) -> SyntheticCredential {
        .init(name: name, material: .text(value), notes: notes, group: group, permission: permission, recycled: recycled)
    }

    func create(in vault: Vault) throws {
        let created: ManagedTextCredential
        switch material {
        case .text(let value, let mapping):
            created = try vault.createTextCredential(.init(
                name: name, value: value, usageInstructions: usage, privateNotes: notes, groupName: group,
                environmentVariable: mapping, permission: permission, expiresAt: expiresAt), using: .allow)
        case .file(let filename, let bytes, let mapping):
            created = try vault.createFileCredential(.init(
                name: name, snapshot: try FileImport.FrozenFile(originalFilename: filename, bytes: bytes),
                usageInstructions: usage, privateNotes: notes, groupName: group, environmentVariable: mapping,
                permission: permission, expiresAt: expiresAt), using: .allow)
        case .bundle(let components):
            created = try vault.createBundleCredential(.init(
                name: name, components: components, usageInstructions: usage, privateNotes: notes, groupName: group,
                permission: permission, expiresAt: expiresAt), using: .allow)
        }
        if recycled { try vault.deleteTextCredential(id: created.id, using: .allow) }
    }
}
