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
                    try host.assertCentredEmptyState(allowance: allowance, context: context)
                    XCTAssertFalse(host.window.isVisible, context)
                }
            }
        }
    }

    func testNewAllowanceAppearsOnTheNextRefreshWithoutAnotherViewChange() throws {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        for language in ["en", "zh-Hans"] {
            for scenario in [CredentialEmptyLayoutHost.Scenario.group, .search] {
                let host = try CredentialEmptyLayoutHost(language: language, scenario: scenario, allowance: false)
                defer { host.close() }
                try host.assertCentredEmptyState(allowance: false, context: "before grant")
                host.grantAllowance()
                // Only the non-observable Broker projection changes. The mounted
                // one-second timeline must discover it without navigation or search.
                let deadline = Date().addingTimeInterval(1.2)
                while Date() < deadline { host.layout() }
                try host.assertCentredEmptyState(allowance: true, context: "\(language) \(scenario) after grant")
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
    private let section: CredentialWorkspaceSection
    private let query: String
    private let syntheticAllowance: BrokerTimedAllowance
    private let allowanceStore: CredentialEmptyAllowanceStore

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
        syntheticAllowance = BrokerTimedAllowance(members: [
            .init(credentialID: credential.id, name: credential.name, metadataDigest: String(repeating: "a", count: 64))
        ], expiresAt: Date().addingTimeInterval(1_800))
        let store = CredentialEmptyAllowanceStore()
        store.records = allowance ? [syntheticAllowance] : []
        allowanceStore = store
        var mutations = CredentialWorkspaceMutations.readOnly { (credentials, [], ["Empty group"], false) }
        mutations.activeTimedAllowances = { store.records }
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
        section = scenario == .group ? .named("Empty group") : .all
        query = scenario == .search ? "no matching credential" : ""
        let root = SettingsView()
        root.navigation.section = section
        root.navigation.interaction.searchText = query
        _ = NSApplication.shared
        window = ManagementWindowConfiguration.makeWindow(rootView: root.environment(model))
        window.appearance = NSAppearance(named: .aqua)
        layout()
        XCTAssertFalse(window.isVisible)
    }

    func layout() {
        for _ in 0..<8 {
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertFalse(window.isVisible)
    }

    func grantAllowance() { allowanceStore.records = [syntheticAllowance] }

    func assertCentredEmptyState(allowance: Bool, context: String) throws {
        let scroll = try scrollView()
        let document = try XCTUnwrap(scroll.documentView)
        let viewport = scroll.convert(scroll.bounds, to: nil)
        let actual = try NoticeLayoutFixtures.render(XCTUnwrap(window.contentView))
        let raster = try NoticeRaster(actual)
        let width = document.bounds.width
        let template = try renderTemplate(WorkspaceEmptyState(
            title: CredentialEmptyPresentation.title(section: section, searchText: query),
            message: CredentialEmptyPresentation.message(section: section, searchText: query),
            systemImage: "archivebox",
            actionTitle: CredentialEmptyPresentation.action(section: section, searchText: query)
        ), width: width)
        // Exclude hidden-window edges symmetrically; the content's measured
        // vertical centre stays the same, including its title, icon and action.
        let emptyPixels = try crop(template, to: CGRect(origin: .zero, size: template.size).insetBy(dx: 20, dy: 20))
        let emptyMatch = try raster.find(NoticeRaster(emptyPixels), atX: viewport.minX + 20)
        let emptyFrame = try XCTUnwrap(emptyMatch, "Missing empty-state pixels: \(context)")

        let card = try renderTemplate(FrozenTimedAllowanceList(
            allowances: [syntheticAllowance], now: Date(), revoke: { _ in XCTFail("Must not revoke") }
        ), width: width - 2 * Theme.Spacing.xxl)
        // Match the heading and the top of the member/action row. Exclude the
        // ticking countdown so a second boundary cannot change the reference.
        let cardTop = try crop(card, to: CGRect(x: 2, y: 2, width: card.size.width - 4, height: 48))
        let cardMatch = try raster.find(NoticeRaster(cardTop), atX: viewport.minX + Theme.Spacing.xxl + 2)
        XCTAssertEqual(cardMatch != nil, allowance, "timed-allowance-list presence: \(context)")
        let contentTop: CGFloat
        if allowance {
            let match = try XCTUnwrap(cardMatch, "Missing timed-allowance-list: \(context)")
            XCTAssertEqual(match.maxY + 2, viewport.maxY, accuracy: 1, context)
            contentTop = match.maxY + 2 - card.size.height - Theme.Spacing.md
            XCTAssertLessThanOrEqual(emptyFrame.maxY, contentTop, context)
        } else {
            contentTop = viewport.maxY
        }
        XCTAssertEqual(emptyFrame.midY, (viewport.minY + contentTop) / 2, accuracy: 1,
                       "Empty state must be centred below the card: \(context)")
        XCTAssertFalse(window.isVisible)
    }

    private func crop(_ bitmap: NSBitmapImageRep, to rect: CGRect) throws -> NSBitmapImageRep {
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let image = try XCTUnwrap(bitmap.cgImage?.cropping(to: rect.applying(CGAffineTransform(scaleX: scale, y: scale))))
        let result = NSBitmapImageRep(cgImage: image)
        result.size = rect.size
        return result
    }

    private func renderTemplate<V: View>(_ content: V, width: CGFloat) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: content
            .environment(model).environment(\.locale, model.appLocale)
            .tint(Theme.accent).preferredColorScheme(.light)
            .frame(width: width).fixedSize(horizontal: false, vertical: true)
            .background(Theme.windowBackground))
        host.appearance = NSAppearance(named: .aqua)
        host.frame.size = host.fittingSize
        host.sizingOptions = []
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.close() }
        return try NoticeLayoutFixtures.render(host)
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

@MainActor
private final class CredentialEmptyAllowanceStore {
    var records: [BrokerTimedAllowance] = []
}
