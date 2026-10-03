import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault
import AskKeyBroker
import AskKeyTestSupport

@MainActor
class WorkspaceVisualContractTestSupport: AskKeyAppTestCase {
    override func setUp() {
        super.setUp()
        AppLanguage.current = "zh-Hans"
    }

    @MainActor
    func manager(
        _ viewModel: VaultViewModel,
        section: CredentialWorkspaceSection = .all,
        route: CredentialWorkspaceRoute = .library,
        selectedID: String? = nil,
        pendingRequests: [BrokerApprovalOperationRequest] = [],
        readAuthenticationConfirmation: Bool = false,
        editorExpanded: Bool = false,
        importValues: [(name: String, value: String)] = [],
        settingsErase: Bool = false,
        credentialDeleteConfirmation: String? = nil,
        groupDeleteConfirmation: String? = nil,
        accessRecordClearConfirmation: Bool = false
    ) -> some View {
        CredentialManagementView(
            initialSection: section, initialRoute: route,
            selectedCredentialID: selectedID, previewMode: true,
            previewPendingRequests: pendingRequests,
            previewReadAuthenticationConfirmation: readAuthenticationConfirmation,
            previewEditorExpanded: editorExpanded,
            previewImportValues: importValues,
            previewSettingsErase: settingsErase,
            previewCredentialDeleteConfirmation: credentialDeleteConfirmation,
            previewGroupDeleteConfirmation: groupDeleteConfirmation,
            previewAccessRecordClearConfirmation: accessRecordClearConfirmation
        )
        .environment(viewModel)
    }

    @MainActor
    func makeSwiftUILikeManagementWindow(viewModel: VaultViewModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.isReleasedWhenClosed = false
        window.title = "请旨"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(
            rootView: SettingsView()
                .environment(viewModel)
                .frame(
                    width: WorkspaceVisualContract.windowWidth,
                    height: WorkspaceVisualContract.windowHeight
                )
        )
        window.setContentSize(ManagementWindowConfiguration.frameSize)
        return window
    }

    @MainActor
    func pumpWindowLayout(_ window: NSWindow, times: Int = 24) {
        for _ in 0..<times {
            window.contentView?.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.016))
        }
    }

    @MainActor
    func makePreviewViewModel(defaults: UserDefaults? = nil) -> VaultViewModel {
        let suite = "WorkspaceVisualContractTests-\(UUID().uuidString)"
        let defaults = defaults ?? UserDefaults(suiteName: suite) ?? .standard
        defaults.set("zh-Hans", forKey: "languageMode")
        defaults.set("light", forKey: "appearanceMode")
        return VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            eraseLocalLibrary: { _, _, _ in },
            authenticateDeviceOwner: { _ in .allow },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { true }, setEnabled: { _ in }),
            credentialMutations: .readOnly { ([], [], [], false) }
        )
    }

    func credential(
        id: String,
        name: String,
        group: String?,
        deletedAt: Date? = nil
    ) -> ManagedTextCredential {
        let componentNames: [String]
        if name.contains("部署") { // i18n-literal: Match Chinese synthetic deployment names in visual fixtures.
            componentNames = ["SSH_HOST"]
        } else if name.contains("数据库") { // i18n-literal: Match Chinese synthetic database names in visual fixtures.
            componentNames = ["DB_HOST", "DB_PASSWORD"]
        } else {
            componentNames = ["API_KEY", "API_ENDPOINT"]
        }
        return ManagedTextCredential(
            id: id, name: name, value: nil, usageInstructions: "仅用于批准的发布流程", // i18n-literal: Preserve the Chinese visual fixture's synthetic usage text.
            privateNotes: nil, groupName: group, environmentVariable: nil,
            permission: .ask, expiresAt: nil, payloadKind: .bundle,
            originalFilename: nil, byteSize: nil, contentDigest: nil, fileBytes: nil,
            components: componentNames.map { ManagedCredentialComponent(name: $0, value: nil) },
            deletedAt: deletedAt
        )
    }

    func pendingApproval(operationID: String) -> BrokerPendingApproval {
        .init(
            requestID: "request-\(operationID)",
            capability: "capability-\(operationID)",
            request: .init(
                operationID: operationID,
                credentialID: "credential",
                targetID: "credential",
                operation: .read,
                payloadDigest: "redacted"
            )
        )
    }

    func evidenceDirectory() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("AskKeyWorkspaceUI-\(UUID().uuidString)", isDirectory: true)
    }

    @MainActor
    func render<V: View>(
        _ view: V,
        as name: String,
        in directory: URL,
        size: CGSize = .init(width: 980, height: 620)
    ) throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height).background(Color.white)
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        XCTAssertGreaterThan(data.count, 5_000, "\(name) did not render useful evidence")
    }
}
