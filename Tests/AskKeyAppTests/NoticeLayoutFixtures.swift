import AppKit
import SwiftUI
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

@MainActor
enum NoticeLayoutFixtures {
    @MainActor
    final class Model {
        let vault: VaultViewModel
        private let suite = "NoticeLayoutTests-\(UUID().uuidString)"
        private let defaults: UserDefaults

        init(language: String, state: SettingsEntryState, recovery: Bool, broker: Bool) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(language, forKey: "languageMode")
            defaults.set("light", forKey: "appearanceMode")
            defaults.set(state != .onboarding, forKey: "hasCompletedOnboarding")
            let policy = AgentAccessPolicyTestState()
            policy.state = .init(policy: recovery ? .failClosed : .defaults, needsRecovery: recovery)
            let credential = ManagedTextCredential(
                id: "synthetic-notice-layout", name: "Synthetic API", value: nil,
                usageInstructions: "Synthetic layout fixture", privateNotes: nil,
                groupName: nil, environmentVariable: nil, permission: .ask, expiresAt: nil,
                payloadKind: .bundle, originalFilename: nil, byteSize: nil, contentDigest: nil,
                fileBytes: nil, components: [.init(name: "API_KEY", value: nil)]
            )
            let credentials = state == .locked || state == .management ? [credential] : []
            vault = VaultViewModel(
                runtimeFileCleanupFailures: { false },
                accessRecords: .empty,
                eraseLocalLibrary: { _, _, _ in XCTFail("Rendering must not erase a library") },
                unlockVault: { XCTFail("Rendering must not unlock a library") },
                beginManagementSession: { _ in XCTFail("Rendering must not authenticate") },
                beginOnboardingManagementSession: { XCTFail("Rendering must not start onboarding") },
                authenticateDeviceOwner: { _ in XCTFail("Rendering must not authenticate"); return nil },
                preferences: AppPreferences(defaults: defaults),
                loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
                agentAccessPolicyOperations: policy.operations,
                pauseAgentAccess: { _ in XCTFail("Rendering must not change policy") },
                resumeAgentAccess: { _ in XCTFail("Rendering must not change policy") },
                credentialMutations: .readOnly { (credentials, [], [], false) }
            )
            vault.isLocked = state != .management
            vault.hasManagementSession = state == .management
            vault.refreshAgentAccessPauseState()
            vault.brokerRecoveryAvailable = broker
            vault.brokerFailureMessage = broker
                ? "Ask Key could not start Agent access because it cannot write the secure staging folder. Fix folder permissions, then retry."
                : nil
            XCTAssertEqual(vault.settingsEntryState, state)
        }

        func close() {
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @MainActor
    final class Host {
        let window: NSWindow
        let view: NSView

        init(model: Model, popover: Bool = false) {
            _ = NSApplication.shared
            if popover {
                let hosting = NSHostingView(rootView: VaultPopover(onOpenManagement: {
                    XCTFail("Rendering must not open management")
                }).environment(model.vault))
                let size = hosting.fittingSize
                hosting.sizingOptions = []
                window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = hosting
            } else {
                window = ManagementWindowConfiguration.makeWindow(
                    rootView: SettingsView().environment(model.vault)
                        .environment(\.locale, model.vault.appLocale)
                        .frame(width: WorkspaceVisualContract.windowWidth,
                               height: WorkspaceVisualContract.windowHeight)
                        .ignoresSafeArea(.container, edges: .top)
                )
            }
            view = window.contentView!
            window.appearance = NSAppearance(named: .aqua)
            // Never order the window in: layout and bitmap caching are in-process.
            for _ in 0..<8 {
                window.layoutIfNeeded()
                view.layoutSubtreeIfNeeded()
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
            XCTAssertFalse(window.isVisible)
        }

        func close() { window.close() }

        func render(includingChrome: Bool = true) throws -> NSBitmapImageRep {
            let frameView = includingChrome ? try XCTUnwrap(view.superview) : view
            frameView.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
            frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            XCTAssertFalse(window.isVisible)
            return bitmap
        }

        func export(_ name: String) throws {
            guard ProcessInfo.processInfo.environment["NOTICE_LAYOUT_RENDER_DIRECTORY"] != nil else { return }
            try NoticeLayoutFixtures.export(render(), name: name)
        }
    }

    static func notice<V: View>(_ notice: V, model: Model, width: CGFloat, popover: Bool = false) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: notice
            .environment(model.vault)
            .environment(\.locale, model.vault.appLocale)
            .preferredColorScheme(.light)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .background(popover ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Theme.windowBackground)))
        host.appearance = NSAppearance(named: .aqua)
        host.frame.size = host.fittingSize
        host.sizingOptions = []
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    static func export(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["NOTICE_LAYOUT_RENDER_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
