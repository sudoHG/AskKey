import XCTest
import AppKit
import SwiftUI
import AskKeyCore
@testable import AskKeyApp

@MainActor
final class ReviewICloudRecoveryTests: XCTestCase {
    func testFirstRunCanInspectWithoutAuthenticationAndRestoreWithOneConfirmation() async throws {
        let fixture = RecoveryFixture()
        let model = fixture.model
        XCTAssertEqual(model.settingsEntryState, .onboarding)
        XCTAssertEqual(model.inspectICloudBackup(recoveryKey: "synthetic-key"), [fixture.generation])
        XCTAssertEqual(fixture.actions, ["inspect"])
        let result = await model.restoreICloudBackup(recoveryKey: "synthetic-key", generationID: fixture.generation.id)
        XCTAssertEqual(result, fixture.generation)
        XCTAssertEqual(fixture.actions, ["inspect", "authenticate", "unlock", "begin-management", "restore"])
        XCTAssertEqual(model.credentials.map(\.name), ["Restored"])
        XCTAssertEqual(model.onboardingCredentialCount, 1)
        XCTAssertEqual(model.settingsEntryState, .management)
    }

    func testCancellingFirstRunAuthenticationLeavesLibraryUntouched() async {
        let fixture = RecoveryFixture()
        fixture.allowAuthentication = false
        let result = await fixture.model.restoreICloudBackup(recoveryKey: "synthetic-key", generationID: fixture.generation.id)
        XCTAssertNil(result)
        XCTAssertEqual(fixture.actions, ["authenticate"])
        XCTAssertEqual(fixture.count, 0)
        XCTAssertTrue(fixture.model.isLocked)
        XCTAssertFalse(fixture.model.hasManagementSession)
        XCTAssertFalse(fixture.model.hasCompletedOnboarding)
    }

    func testExistingLockedLibraryCannotUseFirstRunRecoveryEvenWithStaleUICount() async {
        let fixture = RecoveryFixture()
        let model = fixture.model
        fixture.count = 1
        XCTAssertEqual(model.onboardingCredentialCount, 0)
        XCTAssertTrue(fixture.model.inspectICloudBackup(recoveryKey: "synthetic-key").isEmpty)
        let result = await fixture.model.restoreICloudBackup(recoveryKey: "synthetic-key", generationID: fixture.generation.id)
        XCTAssertNil(result)
        XCTAssertEqual(fixture.actions, [])
    }
    func testFirstRunRechecksEmptyLibraryWhenManagementStartsDuringAuthentication() async {
        let fixture = RecoveryFixture()
        let model = fixture.model
        fixture.duringAuthentication = {
            model.isLocked = false
            model.hasManagementSession = true
            fixture.count = 1
        }
        let result = await model.restoreICloudBackup(recoveryKey: "synthetic-key", generationID: fixture.generation.id)
        XCTAssertNil(result)
        XCTAssertEqual(fixture.actions, ["authenticate"])
    }

    func testTakeoverDoesNotClaimAutomaticBackupResumedWhenStatusReadFails() async {
        let fixture = RecoveryFixture()
        let model = fixture.model
        model.isLocked = false
        model.hasManagementSession = true
        fixture.statusReadFails = true
        let result = await model.takeOwnershipOfICloudBackup(recoveryKey: "synthetic-key", generationID: fixture.generation.id)
        XCTAssertFalse(result)
        XCTAssertEqual(fixture.actions, ["authenticate", "takeover"])
        XCTAssertEqual(model.iCloudBackupStatusCopy,
            "This Mac owns future backups, but automatic backup status could not be confirmed. Check the backup settings before continuing.")
    }

    func testTakeoverReportsAutomaticBackupStillDisabled() async {
        let fixture = RecoveryFixture()
        let model = fixture.model
        model.isLocked = false
        model.hasManagementSession = true
        fixture.backupEnabled = false
        let result = await model.takeOwnershipOfICloudBackup(recoveryKey: "synthetic-key", generationID: fixture.generation.id)
        XCTAssertTrue(result)
        XCTAssertFalse(model.iCloudBackupEnabled)
        XCTAssertEqual(model.iCloudBackupStatusCopy,
            "This Mac owns future backups. Automatic backup is currently off.")
    }

    func testRestoredBackupCompletesOnboardingWhenWorkspaceRefreshFails() async {
        let fixture = RecoveryFixture()
        let model = fixture.model
        model.credentials = [fixture.credential]
        fixture.workspaceReadFails = true
        let result = await model.restoreICloudBackup(recoveryKey: "synthetic-key", generationID: fixture.generation.id)
        XCTAssertNil(result)
        XCTAssertTrue(fixture.actions.contains("restore"))
        XCTAssertTrue(model.credentials.isEmpty)
        XCTAssertTrue(model.hasCompletedOnboarding)
        XCTAssertEqual(model.settingsEntryState, .management)
        XCTAssertEqual(model.iCloudBackupStatusCopy,
            "The backup was restored, but the local view could not refresh. Restart the app to check it; do not restore again.")
    }

    func testRestoredBackupDoesNotClaimRefreshedWhenCountOrAccessRecordsFail() async {
        for failingRead in ["count", "access"] {
            let fixture = RecoveryFixture()
            let model = fixture.model
            fixture.failingReadAfterRestore = failingRead
            let result = await model.restoreICloudBackup(recoveryKey: "synthetic-key", generationID: fixture.generation.id)
            XCTAssertNil(result, failingRead)
            XCTAssertTrue(model.hasCompletedOnboarding, failingRead)
            XCTAssertEqual(model.settingsEntryState, .management, failingRead)
            XCTAssertEqual(model.iCloudBackupStatusCopy,
                "The backup was restored, but the local view could not refresh. Restart the app to check it; do not restore again.", failingRead)
        }
    }

    func testTakeoverControlRequiresItsConfirmationAndSystemAuthentication() async throws {
        _ = NSApplication.shared
        let fixture = RecoveryFixture()
        let model = fixture.model
        model.isLocked = false
        model.hasManagementSession = true
        var key = "synthetic-key"
        var generations = [fixture.generation]
        var selected: String? = fixture.generation.id
        let panel = ICloudBackupRecoveryPanel(
            recoveryKey: Binding(get: { key }, set: { key = $0 }),
            generations: Binding(get: { generations }, set: { generations = $0 }),
            selectedGenerationID: Binding(get: { selected }, set: { selected = $0 }))
        let host = NSHostingView(rootView: panel.environment(model).padding(20).background(Color.white))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["ASKKEY_REVIEW_UI_CAPTURE_DIRECTORY"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("恢复操作.png"))
            }
        }
        // The rendered takeover button is the last row, 32 pt from the panel bottom.
        try clickFromBottom(x: 75, y: 32, in: host, window: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.actions, [])
        try clickFromBottom(x: 100, y: 32, in: host, window: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.actions, ["authenticate", "takeover"])
    }

    func testEmptyLibrarySidebarOpensRecoveryWithoutAuthentication() async throws {
        _ = NSApplication.shared
        let fixture = RecoveryFixture()
        let host = NSHostingView(rootView: SettingsView().environment(fixture.model))
        host.frame = CGRect(x: 0, y: 0, width: 1060, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(findRecoveryKey(in: host))
        for y in stride(from: 10.0, through: 230.0, by: 4.0) {
            try clickFromBottom(x: 190, y: y, in: host, window: window)
            try await Task.sleep(for: .milliseconds(10))
            if findRecoveryKey(in: host) != nil { break }
        }
        XCTAssertNotNil(findRecoveryKey(in: host))
        XCTAssertEqual(fixture.actions, [])
    }

    func testSettingsAppearancePreservesPartialRestoreFeedback() async throws {
        _ = NSApplication.shared
        let fixture = RecoveryFixture()
        let model = fixture.model
        let host = NSHostingView(rootView: SettingsView().environment(model))
        host.frame = CGRect(x: 0, y: 0, width: 1060, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        for y in stride(from: 10.0, through: 230.0, by: 4.0) {
            try clickFromBottom(x: 190, y: y, in: host, window: window)
            try await Task.sleep(for: .milliseconds(10))
            if findRecoveryKey(in: host) != nil { break }
        }
        XCTAssertNotNil(findRecoveryKey(in: host))
        fixture.workspaceReadFails = true
        let readsBeforeRestore = fixture.backupStatusReadCount
        let result = await model.restoreICloudBackup(recoveryKey: "synthetic-key", generationID: fixture.generation.id)
        XCTAssertNil(result)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        // This must exercise the real settings page's onAppear refresh, not just
        // check the model before SwiftUI performs its route transition.
        XCTAssertGreaterThan(fixture.backupStatusReadCount, readsBeforeRestore)
        XCTAssertTrue(model.hasCompletedOnboarding)
        XCTAssertEqual(model.iCloudBackupStatusCopy,
            "The backup was restored, but the local view could not refresh. Restart the app to check it; do not restore again.")
    }

    private func findRecoveryKey(in view: NSView) -> NSSecureTextField? {
        if let field = view as? NSSecureTextField,
           ["Paste Recovery Key", "粘贴恢复密钥"].contains(field.placeholderString ?? "") { return field }
        for child in view.subviews {
            if let field = findRecoveryKey(in: child) { return field }
        }
        return nil
    }

    private func clickFromBottom(x: CGFloat, y: CGFloat, in host: NSView, window: NSWindow) throws {
        let point = host.convert(NSPoint(x: x, y: host.isFlipped ? host.bounds.height - y : y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

}

@MainActor
private final class RecoveryFixture {
    var actions: [String] = []
    var count = 0
    var allowAuthentication = true
    var duringAuthentication: (() -> Void)?
    var statusReadFails = false
    var backupEnabled = true
    var backupStatusReadCount = 0
    var workspaceReadFails = false
    var failingReadAfterRestore: String?
    struct SyntheticReadFailure: Error {}
    let generation = ICloudBackupGeneration(id: "synthetic-generation", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    let credential = ManagedTextCredential(id: "synthetic", name: "Restored", value: nil,
        usageInstructions: "", privateNotes: nil, groupName: nil, environmentVariable: nil,
        permission: .ask, expiresAt: nil, payloadKind: .text, originalFilename: nil, byteSize: nil,
        contentDigest: nil, fileBytes: nil, components: [])
    lazy var model: VaultViewModel = {
        let defaults = UserDefaults(suiteName: "ReviewRecovery-\(UUID())")!
        return VaultViewModel(runtimeFileCleanupFailures: { false }, accessRecords: .readOnly { [unowned self] in
            if failingReadAfterRestore == "access" && actions.contains("restore") { throw SyntheticReadFailure() }
            return []
        },
            inspectICloudBackup: { [unowned self] key in
                XCTAssertEqual(key, "synthetic-key")
                actions.append("inspect")
                return [generation]
            },
            restoreICloudBackup: { [unowned self] key, id, auth in
                XCTAssertEqual(key, "synthetic-key")
                XCTAssertEqual(id, generation.id)
                XCTAssertTrue(auth.confirm(reason: "restore"))
                actions.append("restore")
                count = 1
                return generation
            },
            takeOwnershipOfICloudBackup: { [unowned self] key, id, auth in
                XCTAssertEqual(key, "synthetic-key")
                XCTAssertEqual(id, generation.id)
                XCTAssertTrue(auth.confirm(reason: "takeover"))
                actions.append("takeover")
            },
            iCloudBackupEnabled: { [unowned self] in
                backupStatusReadCount += 1
                if statusReadFails { throw SyntheticReadFailure() }
                return backupEnabled
            },
            unlockVault: { [unowned self] in actions.append("unlock") },
            beginManagementSession: { [unowned self] _ in actions.append("begin-management") },
            authenticateDeviceOwner: { [unowned self] _ in
                actions.append("authenticate")
                duringAuthentication?()
                return allowAuthentication ? .allow : nil
            },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            isAgentAccessPaused: { false },
            credentialMutations: CredentialWorkspaceMutations.readOnly { [unowned self] in
                if workspaceReadFails { throw SyntheticReadFailure() }
                return (count == 0 ? [] : [credential], [], [], false)
            }.counting { [unowned self] in
                if failingReadAfterRestore == "count" && actions.contains("restore") { throw SyntheticReadFailure() }
                return count
            })
    }()
}
