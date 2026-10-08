import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    func freezeAgentOrganization(_ request: AgentTextWriteRequest, digest: String,
                                 key: SymmetricKey) throws -> FrozenAgentOrganization {
        guard case .organize(let operations) = request.action, request.isBounded else {
            throw BrokerApprovalError.invalidRequest
        }
        let snapshot = try store.agentOrganizationSnapshot(key: key)
        var assignments = try snapshot.assignments(key: key)
        var storedGroupNames = Set(snapshot.storedGroups)
        var groupNames = Set(snapshot.storedGroups).union(assignments.values)
        var knownGroups = Set(groupNames.filter { group in
            let members = snapshot.records.filter { assignments[$0.id].map(CredentialName.normalized) == CredentialName.normalized(group) }
            return members.isEmpty || members.contains { $0.deletedAt == nil && $0.permission != CredentialPermission.hidden.rawValue }
        }.map(CredentialName.normalized))
        let original = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0) })
        var records = original
        var affected = Set<String>()
        var moved = Set<String>()
        var namedGroups = Set<String>()
        var summary: [BrokerOrganizationSummary.Operation] = []
        var earliestExpiry: Date?

        func name(_ raw: String) throws -> String { try CredentialName.displayName(from: raw) }
        func normalized(_ name: String) -> String { CredentialName.normalized(name) }
        func existingGroup(_ raw: String) throws -> String {
            let display = try name(raw)
            namedGroups.insert(normalized(display))
            guard let resolved = groupNames.sorted().first(where: { normalized($0) == normalized(display) }) else {
                throw VaultError.credentialUnavailable
            }
            guard knownGroups.contains(normalized(resolved)) else {
                throw VaultError.credentialUnavailable
            }
            return resolved
        }
        func members(_ group: String) -> [CredentialRecord] {
            records.values.filter { assignments[$0.id].map(normalized) == normalized(group) }.sorted { $0.id < $1.id }
        }
        func nonvisible(_ members: [CredentialRecord]) -> Int {
            members.filter { $0.deletedAt != nil || $0.permission == CredentialPermission.hidden.rawValue }.count
        }
        func assign(_ id: String, to group: String?) throws {
            guard var record = records[id] else { throw VaultError.credentialUnavailable }
            affected.insert(id)
            if let previous = assignments[id] { namedGroups.insert(normalized(previous)) }
            if let group { namedGroups.insert(normalized(group)) }
            assignments[id] = group
            record.encryptedGroupName = try group.map { try VaultCrypto.encrypt($0, using: key) }
            record.updatedAt = sharedDateFormatter.string(from: currentDate)
            records[id] = record
        }
        for operation in operations {
            switch operation {
            case .move(let rawCredential, let rawGroup):
                let credential = try name(rawCredential)
                let index = CredentialIndex.hash(normalizedName: normalized(credential), vaultKey: key)
                guard let record = records.values.first(where: { $0.nameIndex == index && $0.deletedAt == nil }),
                      record.permission != CredentialPermission.hidden.rawValue else {
                    recordHiddenCredentialGuess(callerHint: request.callerName, declaredPurpose: request.callerPurpose)
                    throw VaultError.credentialUnavailable
                }
                if let value = record.expiresAt {
                    guard let expiry = sharedDateFormatter.date(from: value), expiry > currentDate else {
                        throw VaultError.credentialUnavailable
                    }
                    earliestExpiry = earliestExpiry.map { min($0, expiry) } ?? expiry
                }
                let group = try rawGroup.map(existingGroup)
                summary.append(.move(credential: try VaultCrypto.decrypt(record.encryptedDisplayName, using: key),
                    from: assignments[record.id], to: group))
                moved.insert(record.id)
                try assign(record.id, to: group)
            case .createGroup(let raw):
                let display = try name(raw)
                namedGroups.insert(normalized(display))
                guard !knownGroups.contains(normalized(display)) else {
                    throw VaultError.credentialUnavailable
                }
                if let existing = groupNames.sorted().first(where: { normalized($0) == normalized(display) }) {
                    let existingMembers = members(existing)
                    summary.append(.existingGroup(name: existing, members: existingMembers.count, nonvisible: nonvisible(existingMembers)))
                } else {
                    groupNames.insert(display)
                    storedGroupNames.insert(display)
                    summary.append(.createGroup(display))
                }
                knownGroups.insert(normalized(display))
            case .renameGroup(let rawFrom, let rawTo):
                let from = try existingGroup(rawFrom)
                let proposed = try name(rawTo)
                namedGroups.insert(normalized(proposed))
                guard !knownGroups.contains(normalized(proposed)) else {
                    throw VaultError.credentialUnavailable
                }
                let existing = groupNames.sorted().first { normalized($0) == normalized(proposed) }
                let to = existing ?? proposed
                let affectedMembers = members(from)
                if let existing {
                    let targetMembers = members(existing)
                    summary.append(.mergeGroup(from: from, to: to, members: affectedMembers.count,
                        nonvisible: nonvisible(affectedMembers), targetMembers: targetMembers.count,
                        targetNonvisible: nonvisible(targetMembers)))
                } else {
                    summary.append(.renameGroup(from: from, to: to, members: affectedMembers.count,
                        nonvisible: nonvisible(affectedMembers)))
                    storedGroupNames.insert(to)
                }
                for record in affectedMembers { try assign(record.id, to: to) }
                groupNames = Set(groupNames.filter { normalized($0) != normalized(from) })
                storedGroupNames = Set(storedGroupNames.filter { normalized($0) != normalized(from) })
                groupNames.insert(to)
                knownGroups.remove(normalized(from))
                knownGroups.insert(normalized(to))
            case .deleteGroup(let raw):
                let group = try existingGroup(raw)
                let affectedMembers = members(group)
                summary.append(.deleteGroup(name: group, members: affectedMembers.count,
                    nonvisible: nonvisible(affectedMembers)))
                for record in affectedMembers { try assign(record.id, to: nil) }
                groupNames = Set(groupNames.filter { normalized($0) != normalized(group) })
                storedGroupNames = Set(storedGroupNames.filter { normalized($0) != normalized(group) })
                knownGroups.remove(normalized(group))
            }
        }
        let before = affected.sorted().compactMap { original[$0] }
        let after = affected.sorted().compactMap { records[$0] }
        let groups = try snapshot.groupStates(names: namedGroups, key: key)
        let finalNames = storedGroupNames.filter { namedGroups.contains(normalized($0)) }.sorted()
        let presentation = BrokerOrganizationSummary(operations: summary)
        struct ApprovalContents: Encodable {
            let requestDigest: String
            let before: [CredentialRecord]
            let after: [CredentialRecord]
            let groups: [AgentOrganizationGroupState]
            let finalGroups: [String]
            let summary: BrokerOrganizationSummary
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let approvalDigest = Self.componentDigest(try encoder.encode(ApprovalContents(requestDigest: digest,
            before: before, after: after, groups: groups, finalGroups: finalNames, summary: presentation)))
        return .init(request: request, digest: digest,
            approvalRequest: .init(operationID: request.operationID, credentialID: "", targetID: "credential-library",
                operation: .organize, payloadDigest: approvalDigest, callerName: request.callerName,
                callerPurpose: request.callerPurpose, retransmissionDigest: digest,
                organizationCredentialIDs: affected.sorted()),
            credentialExpiresAt: earliestExpiry, before: before, after: after, movedCredentialIDs: moved,
            groups: groups, finalGroupNames: finalNames, summary: presentation)
    }
}
