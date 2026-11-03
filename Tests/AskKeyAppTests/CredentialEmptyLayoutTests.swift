import AppKit
import SwiftUI
import XCTest
import AskKeyBroker
import AskKeyVault
@testable import AskKeyAppKit

@MainActor
final class CredentialEmptyLayoutTests: AskKeyAppTestCase {
    func testEmptyStatesFillTheViewportWithAndWithoutAnAllowanceInBothLanguages() throws {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        for language in ["en", "zh-Hans"] {
            for scenario in CredentialEmptyLayoutHost.Scenario.allCases {
                for allowance in [false, true] {
                    let host = try CredentialEmptyLayoutHost(language: language, scenario: scenario, allowance: allowance)
                    defer { host.close() }
                    let scroll = try host.scrollView()
                    let document = try XCTUnwrap(scroll.documentView)
                    let context = "\(language) \(scenario) allowance=\(allowance)"
                    XCTAssertEqual(document.bounds.height, scroll.contentView.bounds.height, accuracy: 1, context)
                    XCTAssertGreaterThan(document.bounds.height, 300, context)
                    XCTAssertEqual(host.model.activeTimedAllowances().count, allowance ? 1 : 0, context)
                    XCTAssertFalse(host.window.isVisible, context)
                }
            }
        }
    }

    func testNonEmptyListKeepsItsNaturalHeight() throws {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        for allowance in [false, true] {
            let host = try CredentialEmptyLayoutHost(language: "en", scenario: .library, allowance: allowance, populated: true)
            defer { host.close() }
            let scroll = try host.scrollView()
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertLessThan(document.bounds.height, scroll.contentView.bounds.height / 2)
            XCTAssertFalse(host.window.isVisible)
        }
    }
}

@MainActor
final class CredentialEmptyLayoutHost {
    enum Scenario: String, CaseIterable {
        case library, group, search
    }

    let model: VaultViewModel
    let window: NSWindow
    private let defaults: UserDefaults
    private let suite = "CredentialEmptyLayout-\(UUID().uuidString)"

    init(language: String, scenario: Scenario, allowance: Bool, populated: Bool = false) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(language, forKey: "languageMode")
        defaults.set("light", forKey: "appearanceMode")
        defaults.set(true, forKey: "hasCompletedOnboarding")
        let credential = ManagedTextCredential(
            id: "synthetic-layout", name: "Synthetic API", value: nil, usageInstructions: "Synthetic fixture",
            privateNotes: nil, groupName: nil, environmentVariable: "API_KEY", permission: .ask, expiresAt: nil,
            payloadKind: .text, originalFilename: nil, byteSize: nil, contentDigest: nil, fileBytes: nil, components: []
        )
        let credentials = scenario == .library && !populated ? [] : [credential]
        let allowances = allowance ? [BrokerTimedAllowance(members: [
            .init(credentialID: credential.id, name: credential.name, metadataDigest: String(repeating: "a", count: 64))
        ], expiresAt: Date().addingTimeInterval(1_800))] : []
        var mutations = CredentialWorkspaceMutations.readOnly { (credentials, [], ["Empty group"], false) }
        mutations.activeTimedAllowances = { allowances }
        let policy = AgentAccessPolicyTestState()
        model = VaultViewModel(
            runtimeFileCleanupFailures: { false }, accessRecords: .empty,
            eraseLocalLibrary: { _, _, _ in XCTFail("Layout must not erase a library") },
            unlockVault: { XCTFail("Layout must not unlock a library") },
            beginManagementSession: { _ in XCTFail("Layout must not authenticate") },
            authenticateDeviceOwner: { _ in XCTFail("Layout must not authenticate"); return .cancelled },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            agentAccessPolicyOperations: policy.operations,
            credentialMutations: mutations
        )
        model.isLocked = false
        model.hasManagementSession = true
        model.reloadCredentials()
        let root = SettingsView()
        root.navigation.section = scenario == .group ? .named("Empty group") : .all
        root.navigation.interaction.searchText = scenario == .search ? "no matching credential" : ""
        _ = NSApplication.shared
        window = ManagementWindowConfiguration.makeWindow(rootView: root.environment(model))
        window.appearance = NSAppearance(named: .aqua)
        for _ in 0..<8 {
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertFalse(window.isVisible)
    }

    func scrollView() throws -> NSScrollView {
        var pending = [try XCTUnwrap(window.contentView)]
        var matches: [NSScrollView] = []
        while let view = pending.popLast() {
            if let scroll = view as? NSScrollView,
               scroll.convert(scroll.bounds, to: nil).midX > WorkspaceVisualContract.sidebarWidth {
                matches.append(scroll)
            }
            pending.append(contentsOf: view.subviews)
        }
        XCTAssertEqual(matches.count, 1)
        return try XCTUnwrap(matches.first)
    }

    func close() {
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }
}
