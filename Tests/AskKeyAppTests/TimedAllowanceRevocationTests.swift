import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

@MainActor
final class TimedAllowanceRevocationTests: AskKeyAppTestCase {
    func testRecordRevocationUsesInjectedUUIDMutationAfterMembershipChanges() {
        let displayed = allowance(members: ["a", "b"])
        let remaining = allowance(id: displayed.id, members: ["b"])
        let newer = allowance(members: ["a", "c"])
        var records = [displayed]
        var revokedIDs: [UUID] = []
        var mutations = CredentialWorkspaceMutations.readOnly { ([], [], [], false) }
        mutations.activeTimedAllowances = { records }
        mutations.revokeTimedAllowance = { _ in XCTFail("List revocation must not resolve a credential"); return false }
        mutations.revokeTimedAllowanceByID = { id in
            revokedIDs.append(id)
            guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
            records.remove(at: index)
            return true
        }
        let model = makeModel(mutations)
        XCTAssertEqual(model.activeTimedAllowances(), [displayed])
        records = [remaining, newer]

        XCTAssertTrue(model.revokeTimedAllowance(id: displayed.id))

        XCTAssertEqual(revokedIDs, [displayed.id])
        XCTAssertEqual(model.activeTimedAllowances(), [newer])
        XCTAssertNil(model.errorMessage)
    }

    func testMissingRecordReturnsFalseAndRefreshesWithoutCredentialFallback() {
        let displayed = allowance(members: ["a", "b"])
        let newer = allowance(members: ["a", "b", "c"])
        var records = [displayed]
        var revokedIDs: [UUID] = []
        var mutations = CredentialWorkspaceMutations.readOnly { ([], [], [], false) }
        mutations.activeTimedAllowances = { records }
        mutations.revokeTimedAllowance = { _ in XCTFail("A missing record must not fall back to a credential"); return false }
        mutations.revokeTimedAllowanceByID = { id in revokedIDs.append(id); return false }
        let model = makeModel(mutations)
        XCTAssertEqual(model.activeTimedAllowances(), [displayed])
        records = [newer]

        XCTAssertFalse(model.revokeTimedAllowance(id: displayed.id))

        XCTAssertEqual(revokedIDs, [displayed.id])
        XCTAssertEqual(model.activeTimedAllowances(), [newer])
        XCTAssertNil(model.errorMessage)
    }

    private func allowance(id: UUID = UUID(), members: [String]) -> BrokerTimedAllowance {
        .init(id: id, groupName: "Synthetic Project", members: members.map {
            .init(credentialID: $0, name: $0.uppercased(), metadataDigest: String(repeating: "a", count: 64))
        }, expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    }

    private func makeModel(_ mutations: CredentialWorkspaceMutations) -> VaultViewModel {
        let suiteName = "TimedAllowanceRevocation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            eraseLocalLibrary: { _, _, _ in },
            unlockVault: {},
            beginManagementSession: { _ in },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            credentialMutations: mutations
        )
    }
}
