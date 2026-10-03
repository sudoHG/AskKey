import XCTest
import AskKeyCore
@testable import AskKeyApp

/// ARC-05: management writes must follow the same injected workspace as reads.
@MainActor
final class ReviewCredentialIsolationTests: AskKeyAppTestCase {
    func testInjectedMutationsNeverReachSharedVault() throws {
        let box = MemoryCredentialBox()
        let defaults = UserDefaults(suiteName: "ReviewCredentialIsolation-\(UUID().uuidString)")!
        let model = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            eraseLocalLibrary: { _, _, _ in },
            unlockVault: {},
            beginManagementSession: { _ in },
            authenticateDeviceOwner: { _ in .allow },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            credentialMutations: box.mutations()
        )
        model.hasCompletedOnboarding = true
        model.hasManagementSession = true
        model.isLocked = false

        model.addTextCredential(TextCredentialInput(
            name: "Isolated Token",
            value: "box-only-secret",
            permission: .ask
        ))

        XCTAssertEqual(box.writes, ["createText:Isolated Token"])
        XCTAssertEqual(box.credentials.map(\.name), ["Isolated Token"])
        XCTAssertTrue(box.didUseMemoryBox)
        XCTAssertEqual(model.credentials.map(\.name), ["Isolated Token"])
        XCTAssertEqual(model.onboardingCredentialCount, 1)
    }

    func testReadOnlyInjectionRefusesWritesWithoutALiveVaultPath() {
        let defaults = UserDefaults(suiteName: "ReviewCredentialIsolation-readonly-\(UUID().uuidString)")!
        let model = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            eraseLocalLibrary: { _, _, _ in },
            unlockVault: {},
            beginManagementSession: { _ in },
            authenticateDeviceOwner: { _ in .allow },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            credentialMutations: .readOnly { ([], [], [], false) }
        )
        model.hasCompletedOnboarding = true
        model.hasManagementSession = true
        model.isLocked = false

        model.addTextCredential(TextCredentialInput(
            name: "Must Not Land On Shared Vault",
            value: "should-not-write",
            permission: .ask
        ))

        XCTAssertTrue(model.credentials.isEmpty)
        XCTAssertEqual(model.onboardingCredentialCount, 0)
        XCTAssertNotNil(model.errorMessage)
    }

    func testTimedAllowanceUsesInjectedMutations() {
        let box = MemoryCredentialBox()
        box.deadlines["cred-1"] = Date(timeIntervalSince1970: 1_800_000_000)
        let defaults = UserDefaults(suiteName: "ReviewCredentialIsolation-allow-\(UUID().uuidString)")!
        let model = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            eraseLocalLibrary: { _, _, _ in },
            unlockVault: {},
            beginManagementSession: { _ in },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            credentialMutations: box.mutations()
        )

        XCTAssertEqual(
            model.timedAllowanceDeadline(for: "cred-1"),
            Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertTrue(model.revokeTimedAllowance(for: "cred-1"))
        XCTAssertEqual(box.writes, ["revokeTimedAllowance:cred-1"])
        XCTAssertNil(model.timedAllowanceDeadline(for: "cred-1"))
    }

    func testReadOnlyAccessRecordsRefuseClearWithoutALiveVaultPath() {
        let sentinel = CredentialAccessEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            credentialID: "synthetic-access",
            operation: .runtimeRead,
            result: .allowed,
            callerHint: "synthetic",
            declaredPurpose: "isolation"
        )
        let defaults = UserDefaults(suiteName: "ReviewCredentialIsolation-access-\(UUID().uuidString)")!
        let model = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .readOnly { [sentinel] },
            eraseLocalLibrary: { _, _, _ in },
            unlockVault: {},
            beginManagementSession: { _ in },
            authenticateDeviceOwner: { _ in .allow },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            credentialMutations: .readOnly { ([], [], [], false) }
        )
        model.hasCompletedOnboarding = true
        model.hasManagementSession = true
        model.isLocked = false

        XCTAssertTrue(model.reloadCredentialAccessRecords())
        XCTAssertEqual(model.credentialAccessRecords, [sentinel])

        model.clearCredentialAccessRecords(using: .allow)

        XCTAssertEqual(model.credentialAccessRecords, [sentinel])
        XCTAssertNotNil(model.errorMessage)
    }

    func testCredentialBagCarriesAccessRecordsWhenOverrideIsOmitted() {
        let sentinel = CredentialAccessEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_001),
            credentialID: "bag-access",
            operation: .runtimeRead,
            result: .allowed,
            callerHint: "bag",
            declaredPurpose: "carry"
        )
        let box = MemoryCredentialBox()
        box.accessEvents = [sentinel]
        let defaults = UserDefaults(suiteName: "ReviewCredentialIsolation-bag-\(UUID().uuidString)")!
        let model = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            eraseLocalLibrary: { _, _, _ in },
            unlockVault: {},
            beginManagementSession: { _ in },
            authenticateDeviceOwner: { _ in .allow },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            credentialMutations: box.mutations()
        )
        model.hasCompletedOnboarding = true
        model.hasManagementSession = true
        model.isLocked = false

        XCTAssertTrue(model.reloadCredentialAccessRecords())
        XCTAssertEqual(model.credentialAccessRecords, [sentinel])

        model.clearCredentialAccessRecords(using: .allow)

        XCTAssertTrue(model.credentialAccessRecords.isEmpty)
        XCTAssertEqual(box.writes, ["clearAccess"])
        XCTAssertTrue(box.accessEvents.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testReadOnlyCredentialBagRefusesClearWithoutASeparateAccessOverride() {
        let defaults = UserDefaults(suiteName: "ReviewCredentialIsolation-bag-readonly-\(UUID().uuidString)")!
        let model = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            eraseLocalLibrary: { _, _, _ in },
            unlockVault: {},
            beginManagementSession: { _ in },
            authenticateDeviceOwner: { _ in .allow },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            credentialMutations: .readOnly { ([], [], [], false) }
        )
        model.hasCompletedOnboarding = true
        model.hasManagementSession = true
        model.isLocked = false

        model.clearCredentialAccessRecords(using: .allow)

        XCTAssertTrue(model.credentialAccessRecords.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testInjectedWorkspaceCannotReportCountFromAnotherStore() {
        let box = MemoryCredentialBox()
        let suite = "ReviewCredentialIsolation-count-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "hasCompletedOnboarding")

        let model = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            eraseLocalLibrary: { _, _, _ in },
            unlockVault: {},
            beginManagementSession: { _ in },
            authenticateDeviceOwner: { _ in .allow },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            credentialMutations: box.mutations()
        )
        XCTAssertEqual(
            model.onboardingCredentialCount,
            0,
            "the injected empty workspace must also own the count read used at initialization"
        )
        XCTAssertEqual(model.settingsEntryState, .empty)
        _ = model.refreshCredentialSummary()
        XCTAssertEqual(
            model.onboardingCredentialCount,
            0,
            "refresh must keep counting the same injected workspace"
        )

        model.hasManagementSession = true
        model.isLocked = false
        XCTAssertTrue(model.refreshCredentialSummary())
        XCTAssertEqual(model.onboardingCredentialCount, 0)

        model.addTextCredential(TextCredentialInput(
            name: "Synthetic",
            value: "not-a-real-secret",
            permission: .ask
        ))

        XCTAssertEqual(model.credentials.count, 1)
        XCTAssertEqual(
            model.onboardingCredentialCount,
            model.credentials.count,
            "one injected workspace still permits its post-write count to come from another store"
        )
    }
}

@MainActor
private final class MemoryCredentialBox {
    var credentials: [ManagedTextCredential] = []
    var recycled: [ManagedTextCredential] = []
    var groups: [String] = []
    var writes: [String] = []
    var deadlines: [String: Date] = [:]
    var accessEvents: [CredentialAccessEvent] = []
    var didUseMemoryBox = false

    func mutations() -> CredentialWorkspaceMutations {
        CredentialWorkspaceMutations(
            loadWorkspace: { [unowned self] in
                (self.credentials, self.recycled, self.groups, false)
            },
            createCredentialGroup: { [unowned self] name in
                self.record("createGroup:\(name)")
                self.groups.append(name)
            },
            deleteCredentialGroup: { [unowned self] name in
                self.record("deleteGroup:\(name)")
                self.groups.removeAll { $0 == name }
            },
            updateCredentialGroup: { [unowned self] id, groupName in
                self.record("updateGroup:\(id)")
                self.update(id) { credential in
                    ManagedTextCredential(
                        id: credential.id,
                        name: credential.name,
                        value: credential.value,
                        usageInstructions: credential.usageInstructions,
                        privateNotes: credential.privateNotes,
                        groupName: groupName,
                        environmentVariable: credential.environmentVariable,
                        permission: credential.permission,
                        expiresAt: credential.expiresAt,
                        payloadKind: credential.payloadKind,
                        originalFilename: credential.originalFilename,
                        byteSize: credential.byteSize,
                        contentDigest: credential.contentDigest,
                        fileBytes: credential.fileBytes,
                        components: credential.components,
                        deletedAt: credential.deletedAt
                    )
                }
            },
            updateCredentialPermission: { [unowned self] _, _ in
                self.record("updatePermission")
            },
            updateCredentialMetadata: { [unowned self] _, _, _, _, _, _ in
                self.record("updateMetadata")
            },
            restoreRecycled: { [unowned self] _ in self.record("restore") },
            permanentlyDeleteRecycled: { [unowned self] _, _ in self.record("permanentDelete") },
            createText: { [unowned self] input in
                self.record("createText:\(input.name)")
                self.credentials.append(
                    ManagedTextCredential(
                        id: UUID().uuidString,
                        name: input.name,
                        value: nil,
                        usageInstructions: input.usageInstructions,
                        privateNotes: nil,
                        groupName: input.groupName,
                        environmentVariable: input.environmentVariable,
                        permission: input.permission,
                        expiresAt: input.expiresAt,
                        payloadKind: .text,
                        originalFilename: nil,
                        byteSize: nil,
                        contentDigest: nil,
                        fileBytes: nil,
                        components: []
                    )
                )
            },
            createBundle: { [unowned self] _ in self.record("createBundle") },
            updateBundle: { [unowned self] _, _ in self.record("updateBundle") },
            replaceImportedBundle: { [unowned self] _, _, _ in self.record("replaceImported") },
            updateText: { [unowned self] _, _ in self.record("updateText") },
            createFile: { [unowned self] _ in self.record("createFile") },
            updateFile: { [unowned self] _, _ in self.record("updateFile") },
            deleteText: { [unowned self] id in
                self.record("deleteText:\(id)")
                self.credentials.removeAll { $0.id == id }
            },
            revealText: { [unowned self] id, _ in
                self.record("reveal:\(id)")
                guard let credential = self.credentials.first(where: { $0.id == id }) else {
                    throw VaultError.credentialNotFound(id)
                }
                return credential
            },
            timedAllowanceDeadline: { [unowned self] id in
                self.deadlines[id]
            },
            revokeTimedAllowance: { [unowned self] id in
                self.record("revokeTimedAllowance:\(id)")
                return self.deadlines.removeValue(forKey: id) != nil
            },
            storedCredentialCount: { [unowned self] in
                self.credentials.count + self.recycled.count
            },
            accessRecords: CredentialAccessRecordMutations(
                list: { [unowned self] in self.accessEvents },
                clear: { [unowned self] _ in
                    self.record("clearAccess")
                    self.accessEvents = []
                }
            )
        )
    }

    private func record(_ write: String) {
        didUseMemoryBox = true
        writes.append(write)
    }

    private func update(_ id: String, _ transform: (ManagedTextCredential) -> ManagedTextCredential) {
        guard let index = credentials.firstIndex(where: { $0.id == id }) else { return }
        credentials[index] = transform(credentials[index])
    }
}
