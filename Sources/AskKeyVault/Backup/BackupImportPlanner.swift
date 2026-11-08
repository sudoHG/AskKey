import CryptoKit
import Foundation
import AskKeyBroker

/// What two credentials must share to be identical for an import (ADR 0012):
/// component names, values, original filenames and delivery mappings, usage
/// instructions and private notes. Group, expiry, permission, timestamps,
/// payload kind and masked flags are not compared.
struct BackupImportContent: Equatable {
    struct Component: Equatable {
        let name: String
        let value: CredentialComponentValue
        let delivery: CredentialComponentDelivery
    }

    let components: [Component]
    let usageInstructions: String
    let privateNotes: String

    init(components: [CredentialComponentInput], usageInstructions: String, privateNotes: String) {
        self.components = components.map { .init(name: $0.name, value: $0.value, delivery: $0.delivery) }
        self.usageInstructions = usageInstructions
        self.privateNotes = privateNotes
    }

    init(_ credential: BackupSnapshot.Credential) {
        self.init(components: credential.components, usageInstructions: credential.usageInstructions,
                  privateNotes: credential.privateNotes)
    }
}

/// The library as one read saw it. Names are looked up through the stored
/// name index, the same check that makes names unique, so a plan never
/// assigns a name the library would refuse.
final class BackupImportLibrary {
    struct Credential {
        let name: String
        let isRecycled: Bool
        let content: BackupImportContent
    }

    /// Every group name: stored ones and those only credentials carry.
    let groups: [String]
    private let records: [Data: CredentialRecord]
    private let nameIndex: (String) -> Data
    private let describe: (CredentialRecord) throws -> Credential
    private var described: [Data: Credential] = [:]

    init(records: [CredentialRecord], groups: [String], nameIndex: @escaping (_ normalizedName: String) -> Data,
         describe: @escaping (CredentialRecord) throws -> Credential) {
        self.records = Dictionary(records.map { ($0.nameIndex, $0) }, uniquingKeysWith: { first, _ in first })
        self.groups = groups
        self.nameIndex = nameIndex
        self.describe = describe
    }

    var count: Int { records.count }

    func index(of name: String) -> Data { nameIndex(CredentialName.normalized(name)) }

    func contains(_ name: String) -> Bool { records[index(of: name)] != nil }

    /// Decrypts a matching credential once, only when its content is needed.
    func credential(named name: String) throws -> Credential? {
        let index = index(of: name)
        if let cached = described[index] { return cached }
        guard let record = records[index] else { return nil }
        let credential = try describe(record)
        described[index] = credential
        return credential
    }
}

/// Applies the ADR 0012 merge rules to a validated snapshot.
struct BackupImportPlanner {
    static let recycleBinRetention: TimeInterval = 30 * 24 * 60 * 60

    struct Outcome {
        var credentials: [BackupImportPlannedCredential] = []
        var skippedIdentical: [BackupImportMatch] = []
        var skippedInRecycleBin: [BackupImportMatch] = []
        var skippedRecycled: [String] = []
        /// Groups that exist after the import and did not before.
        var createdGroups: [String] = []
        /// The created groups no imported credential carries: the backup's
        /// empty groups, which only the stored group list can hold.
        var storedGroups: [String] = []
    }

    let library: BackupImportLibrary
    let now: Date

    static func retentionEnded(deletedAt: Date, at now: Date) -> Bool {
        // The same boundary as the Recycle Bin purge: deleted on or before the cutoff.
        deletedAt <= now.addingTimeInterval(-recycleBinRetention)
    }

    /// `renameSuffix` is the caller's suffix for a rename candidate: for 1 the
    /// plain one, for example "(from backup)", and for 2, 3 and so on the
    /// numbered one.
    func plan(_ snapshot: BackupSnapshot, renameSuffix: (Int) -> String) throws -> Outcome {
        var outcome = Outcome()
        let (groupSpelling, newGroups) = mapGroups(snapshot.groups)
        var assigned: [Data: (name: String, content: BackupImportContent)] = [:]
        func add(_ credential: BackupSnapshot.Credential, as name: String) {
            assigned[library.index(of: name)] = (name, BackupImportContent(credential))
            outcome.credentials.append(.init(source: credential, name: name, groupName: credential.groupName.map {
                groupSpelling[CredentialName.normalized($0)] ?? $0
            }))
        }

        let ordered = snapshot.credentials.sorted { CredentialName.normalized($0.name) < CredentialName.normalized($1.name) }
        // 1. Active credentials whose name is free keep it first, so another
        //    credential's rename candidate never displaces them.
        var conflicting: [BackupSnapshot.Credential] = []
        for credential in ordered where credential.deletedAt == nil {
            if library.contains(credential.name) { conflicting.append(credential) } else { add(credential, as: credential.name) }
        }
        // 2. A conflicting active credential is skipped when its name or a
        //    candidate already holds identical content; otherwise it takes the
        //    first candidate that is free in the library and in this plan.
        for credential in conflicting {
            let content = BackupImportContent(credential)
            // Each occupied name blocks at most one candidate, so distinct
            // candidates always reach a free one within this bound.
            let lastNumber = library.count + assigned.count + 1
            var resolved = false
            for number in 0...lastNumber {
                let name = number == 0 ? credential.name : try candidate(for: credential.name, suffix: renameSuffix(number))
                if let existing = try library.credential(named: name) {
                    guard existing.content == content else { continue }
                    let match = BackupImportMatch(backupName: credential.name, name: existing.name)
                    if existing.isRecycled { outcome.skippedInRecycleBin.append(match) } else { outcome.skippedIdentical.append(match) }
                } else if let planned = assigned[library.index(of: name)] {
                    guard planned.content == content else { continue }
                    outcome.skippedIdentical.append(.init(backupName: credential.name, name: planned.name))
                } else {
                    add(credential, as: name)
                }
                resolved = true
                break
            }
            guard resolved else { throw BackupImportError.invalidRenameSuffix }
        }
        // 3. A recycled credential stays recycled and is never renamed: it is
        //    skipped when its retention has ended or its name is taken.
        for credential in ordered {
            guard let deletedAt = credential.deletedAt else { continue }
            if Self.retentionEnded(deletedAt: deletedAt, at: now) || library.contains(credential.name)
                || assigned[library.index(of: credential.name)] != nil {
                outcome.skippedRecycled.append(credential.name)
            } else {
                add(credential, as: credential.name)
            }
        }
        outcome.credentials.sort { CredentialName.normalized($0.name) < CredentialName.normalized($1.name) }
        // A group with backup members exists only through the members that
        // are added, as it did in the source: a group whose members are all
        // skipped is not created, so a group that only Hidden or recycled
        // credentials carry never becomes an empty group agents can see.
        let members = Set(snapshot.credentials.compactMap { $0.groupName.map(CredentialName.normalized) })
        let carried = Set(outcome.credentials.compactMap { $0.groupName.map(CredentialName.normalized) })
        for name in newGroups {
            let normalized = CredentialName.normalized(name)
            if !members.contains(normalized) {
                outcome.createdGroups.append(name)
                outcome.storedGroups.append(name)
            } else if carried.contains(normalized) {
                outcome.createdGroups.append(name)
            }
        }
        return outcome
    }

    /// Groups match by normalized name and keep the library's spelling. Each
    /// backup group without a match is new, under its first spelling.
    private func mapGroups(_ backupGroups: [String]) -> (spelling: [String: String], new: [String]) {
        var spelling: [String: String] = [:]
        for name in library.groups.sorted() where spelling[CredentialName.normalized(name)] == nil {
            spelling[CredentialName.normalized(name)] = name
        }
        var new: [String] = []
        for name in backupGroups.sorted() where spelling[CredentialName.normalized(name)] == nil {
            spelling[CredentialName.normalized(name)] = name
            new.append(name)
        }
        return (spelling, new)
    }

    /// `<name> <suffix>`, with the name shortened so the candidate stays within
    /// the credential name limits.
    private func candidate(for name: String, suffix rawSuffix: String) throws -> String {
        let suffix = rawSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suffix.isEmpty else { throw BackupImportError.invalidRenameSuffix }
        func fits(_ candidate: String) -> Bool {
            candidate.count <= CredentialName.maximumLength && candidate.utf8.count <= BrokerLimits.maximumFieldBytes
        }
        var base = name
        while !base.isEmpty, !fits(base + " " + suffix) { base.removeLast() }
        while base.last?.isWhitespace == true { base.removeLast() }
        let candidate = base.isEmpty ? suffix : base + " " + suffix
        guard (try? CredentialName.displayName(from: candidate)) == candidate else {
            throw BackupImportError.invalidRenameSuffix
        }
        return candidate
    }
}

/// A digest of every credential row, recycled ones included, and the stored
/// groups, keyed by the App key so a plan only commits into the library and
/// state it was computed against.
enum BackupImportLibraryState {
    private struct State: Encodable {
        let records: [CredentialRecord]
        let storedGroups: [String]
    }

    static func digest(_ library: AgentOrganizationSnapshot, key: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let state = try encoder.encode(State(records: library.records.sorted { $0.id < $1.id },
                                             storedGroups: library.storedGroups.sorted()))
        let digestKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(),
                                               info: Data("AskKey backup import library state v1".utf8),
                                               outputByteCount: 32)
        return Data(HMAC<SHA256>.authenticationCode(for: state, using: digestKey))
    }
}
