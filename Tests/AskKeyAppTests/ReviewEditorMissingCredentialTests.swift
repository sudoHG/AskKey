import AppKit
import SwiftUI
import Vision
import XCTest
import AskKeyCore
@testable import AskKeyApp

/// CR-06: `editor(id)` must not become “New Credential” when the list refresh
/// can no longer find that object.
@MainActor
final class ReviewEditorMissingCredentialTests: AskKeyAppTestCase {
    override func setUp() {
        super.setUp()
        AppLanguage.systemLanguages = { ["zh-Hans"] }
        AppLanguage.apply(mode: "zh-Hans")
    }

    override func tearDown() {
        AppLanguage.systemLanguages = { Locale.preferredLanguages }
        AppLanguage.apply(mode: "en")
        super.tearDown()
    }

    func testCreateRouteStaysCreate() throws {
        let workspace = WorkspaceFixture(credentials: [])
        let host = try present(
            route: .editor(template: .custom, credentialID: nil),
            workspace: workspace
        )
        defer { host.window.orderOut(nil) }

        XCTAssertEqual(host.visibleAvailability(), "create", host.strings().joined(separator: " | "))
        XCTAssertFalse(host.showsUnavailablePage())
    }

    func testEditRouteStaysEditWhileObjectExists() throws {
        let workspace = WorkspaceFixture(credentials: [Self.synthetic])
        let host = try present(
            route: .editor(template: .custom, credentialID: Self.synthetic.id),
            workspace: workspace
        )
        defer { host.window.orderOut(nil) }

        XCTAssertEqual(host.visibleAvailability(), "edit")
        XCTAssertTrue(host.strings().contains("Synthetic"), host.strings().joined(separator: " | "))
    }

    func testEditorIDBecomesUnavailableAfterRefreshRemovesObject() throws {
        let workspace = WorkspaceFixture(credentials: [Self.synthetic])
        let host = try present(
            route: .editor(template: .custom, credentialID: Self.synthetic.id),
            workspace: workspace
        )
        defer { host.window.orderOut(nil) }

        XCTAssertEqual(host.visibleAvailability(), "edit")

        workspace.credentials = []
        XCTAssertTrue(workspace.model.refreshCredentialSummary())
        host.pump()

        XCTAssertEqual(host.visibleAvailability(), "unavailable")
        XCTAssertEqual(host.route, .editor(template: .custom, credentialID: Self.synthetic.id))
        XCTAssertTrue(host.showsUnavailablePage(), host.strings().joined(separator: " | "))
        XCTAssertNotEqual(host.visibleAvailability(), "create")
    }

    func testUnavailableEditorStopsSaveAndReturnsToLibrary() throws {
        let workspace = WorkspaceFixture(credentials: [])
        let host = try present(
            route: .editor(template: .custom, credentialID: Self.synthetic.id),
            workspace: workspace
        )
        defer { host.window.orderOut(nil) }

        XCTAssertEqual(host.visibleAvailability(), "unavailable")
        XCTAssertTrue(host.showsUnavailablePage(), host.strings().joined(separator: " | "))
        XCTAssertNil(host.findButton(titled: appLocalized("Save Credential")))
        XCTAssertNil(host.findButton(titled: appLocalized("Save Changes")))
        XCTAssertTrue(
            host.press(titled: appLocalized("Back to Library"))
                || host.press(titled: "返回凭证库")
                || host.press(titled: "Back to Library"),
            host.strings().joined(separator: " | ")
        )
        host.pump()
        XCTAssertEqual(host.route, .library)
    }

    func testLockHidesEditorThenUnlockKeepsUnavailableIfStillMissing() throws {
        let workspace = WorkspaceFixture(credentials: [Self.synthetic])
        var route = CredentialWorkspaceRoute.editor(template: .custom, credentialID: Self.synthetic.id)
        let host = try presentSettingsChain(route: &route, workspace: workspace)
        defer { host.window.orderOut(nil) }

        XCTAssertEqual(host.visibleAvailability(), "edit")

        workspace.credentials = []
        workspace.model.hasManagementSession = false
        workspace.model.isLocked = true
        workspace.model.showsLockedWorkbench = true
        workspace.model.credentials = []
        host.pump()

        let locked = host.strings()
        XCTAssertFalse(locked.contains(appLocalized("New Credential")), locked.joined(separator: " | "))
        XCTAssertFalse(locked.contains(appLocalized("Edit Credential")))
        XCTAssertTrue(
            locked.contains("lock.fill") || locked.contains(appLocalized("Unlock")) || !locked.contains(appLocalized("Save Credential")),
            locked.joined(separator: " | ")
        )

        workspace.model.showsLockedWorkbench = false
        workspace.model.isLocked = false
        workspace.model.hasManagementSession = true
        XCTAssertTrue(workspace.model.refreshCredentialSummary())
        host.pump()

        XCTAssertEqual(host.route, .editor(template: .custom, credentialID: Self.synthetic.id))
        XCTAssertEqual(host.visibleAvailability(), "unavailable")
    }

    func testCloseAndReopenKeepsEditorRouteWithoutTurningIntoCreate() throws {
        let workspace = WorkspaceFixture(credentials: [])
        var route = CredentialWorkspaceRoute.editor(template: .custom, credentialID: Self.synthetic.id)
        let first = try presentManagement(route: &route, workspace: workspace)
        XCTAssertEqual(first.visibleAvailability(), "unavailable")
        XCTAssertEqual(first.route, .editor(template: .custom, credentialID: Self.synthetic.id))
        first.window.orderOut(nil)

        let reopened = try presentManagement(route: &route, workspace: workspace)
        defer { reopened.window.orderOut(nil) }
        reopened.pump()

        XCTAssertEqual(reopened.route, .editor(template: .custom, credentialID: Self.synthetic.id))
        XCTAssertEqual(reopened.visibleAvailability(), "unavailable")
        XCTAssertTrue(reopened.showsUnavailablePage())
        XCTAssertNotEqual(reopened.visibleAvailability(), "create")
    }

    func testProductionUnavailablePageUsesOrdinarySwiftUIControls() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AskKeyApp/Views/CredentialManagementView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("EditorAvailabilityProbe"))
        XCTAssertFalse(source.contains("EditorReturnButton"))
        XCTAssertFalse(source.contains("VisibleStatusCopy"))
        XCTAssertFalse(source.contains("VisibleStatusButton"))
        XCTAssertTrue(source.contains("Button(appLocalized(\"Back to Library\")"))
        XCTAssertTrue(source.contains("Text(appLocalized(\"This Credential Is Unavailable\"))"))
    }

    func testAvailabilityResolveDoesNotTreatMissingIDAsCreate() {
        XCTAssertEqual(
            CredentialEditorAvailability.resolve(template: .api, credentialID: nil, credentials: []),
            .create(template: .api)
        )
        XCTAssertEqual(
            CredentialEditorAvailability.resolve(
                template: .custom,
                credentialID: Self.synthetic.id,
                credentials: [Self.synthetic]
            ),
            .edit(template: .custom, credential: Self.synthetic)
        )
        XCTAssertEqual(
            CredentialEditorAvailability.resolve(
                template: .custom,
                credentialID: Self.synthetic.id,
                credentials: []
            ),
            .unavailable(id: Self.synthetic.id)
        )
    }

    private static let synthetic = ManagedTextCredential(
        id: "synthetic-editor",
        name: "Synthetic",
        value: nil,
        usageInstructions: "",
        privateNotes: nil,
        groupName: nil,
        environmentVariable: nil,
        permission: .ask,
        expiresAt: nil,
        payloadKind: .text,
        originalFilename: nil,
        byteSize: nil,
        contentDigest: nil,
        fileBytes: nil,
        components: []
    )

    private func present(
        route: CredentialWorkspaceRoute,
        workspace: WorkspaceFixture
    ) throws -> HostedRoute {
        var current = route
        return try presentManagement(route: &current, workspace: workspace)
    }

    private func presentManagement(
        route: inout CredentialWorkspaceRoute,
        workspace: WorkspaceFixture
    ) throws -> HostedRoute {
        var section = CredentialWorkspaceSection.all
        let routeBox = RouteBox(route: route)
        let view = CredentialManagementView(
            selectedSection: Binding(
                get: { section },
                set: { section = $0 }
            ),
            route: Binding(
                get: { routeBox.route },
                set: { routeBox.route = $0 }
            )
        )
        .environment(workspace.model)
        .frame(width: 980, height: 620)
        let hosted = try HostedRoute(root: view, routeBox: routeBox)
        hosted.pump()
        route = routeBox.route
        return hosted
    }

    private func presentSettingsChain(
        route: inout CredentialWorkspaceRoute,
        workspace: WorkspaceFixture
    ) throws -> HostedRoute {
        let routeBox = RouteBox(route: route)
        let view = SettingsRouteChain(route: Binding(
            get: { routeBox.route },
            set: { routeBox.route = $0 }
        ))
        .environment(workspace.model)
        .frame(width: 980, height: 620)
        let hosted = try HostedRoute(root: view, routeBox: routeBox)
        hosted.pump()
        route = routeBox.route
        return hosted
    }

}

@MainActor
private final class WorkspaceFixture {
    private let store: CredentialStore
    let model: VaultViewModel

    var credentials: [ManagedTextCredential] {
        get { store.credentials }
        set { store.credentials = newValue }
    }

    init(credentials: [ManagedTextCredential]) {
        let store = CredentialStore(credentials: credentials)
        self.store = store
        let defaults = UserDefaults(suiteName: "ReviewEditorMissing-\(UUID().uuidString)")!
        defaults.set("zh-Hans", forKey: "languageMode")
        defaults.set("light", forKey: "appearanceMode")
        let model = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            eraseLocalLibrary: { _, _, _ in },
            unlockVault: {},
            beginManagementSession: { _ in },
            authenticateDeviceOwner: { _ in .allow },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            credentialMutations: store.mutations()
        )
        model.hasCompletedOnboarding = true
        model.onboardingCredentialCount = max(credentials.count, 1)
        model.hasManagementSession = true
        model.isLocked = false
        model.showsLockedWorkbench = false
        _ = model.reloadCredentials()
        self.model = model
    }
}

@MainActor
private final class CredentialStore {
    var credentials: [ManagedTextCredential]
    init(credentials: [ManagedTextCredential]) { self.credentials = credentials }

    func mutations() -> CredentialWorkspaceMutations {
        CredentialWorkspaceMutations(
            loadWorkspace: { [unowned self] in (self.credentials, [], [], false) },
            createCredentialGroup: { _ in },
            deleteCredentialGroup: { _ in },
            updateCredentialGroup: { _, _ in },
            updateCredentialPermission: { _, _ in },
            updateCredentialMetadata: { _, _, _, _, _, _ in },
            restoreRecycled: { _ in },
            permanentlyDeleteRecycled: { _, _ in },
            createText: { _ in },
            createBundle: { _ in },
            updateBundle: { _, _ in },
            replaceImportedBundle: { _, _, _ in },
            updateText: { _, _ in },
            createFile: { _ in },
            updateFile: { _, _ in },
            deleteText: { _ in },
            revealText: { id, _ in throw VaultError.credentialNotFound(id) },
            timedAllowanceDeadline: { _ in nil },
            revokeTimedAllowance: { _ in false },
            storedCredentialCount: { [unowned self] in self.credentials.count },
            accessRecords: .empty
        )
    }
}

@MainActor
private final class RouteBox {
    var route: CredentialWorkspaceRoute
    init(route: CredentialWorkspaceRoute) { self.route = route }
}

private struct SettingsRouteChain: View {
    @Environment(VaultViewModel.self) private var vault
    @Binding var route: CredentialWorkspaceRoute
    @State private var section = CredentialWorkspaceSection.all

    var body: some View {
        switch vault.settingsEntryState {
        case .management:
            CredentialManagementView(selectedSection: $section, route: $route)
        case .locked:
            VStack {
                Image(systemName: "lock.fill")
                Text(WorkspaceVisualContract.lockedCopy(
                    language: AppLanguage.resolve(mode: vault.languageMode),
                    credentialCount: max(vault.credentials.count, vault.onboardingCredentialCount),
                    pendingRequestCount: vault.pendingApprovalCount
                ).title)
                Text(appLocalized("Unlock"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("locked-workbench")
        default:
            EmptyView()
        }
    }
}

@MainActor
private final class HostedRoute {
    let window: NSWindow
    let hosting: NSHostingView<AnyView>
    let routeBox: RouteBox

    var route: CredentialWorkspaceRoute { routeBox.route }

    init<V: View>(root: V, routeBox: RouteBox) throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.frame = CGRect(x: 0, y: 0, width: 980, height: 620)
        hosting.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        self.window = window
        self.hosting = hosting
        self.routeBox = routeBox
        guard window.windowNumber > 0 else {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    func pump() {
        for _ in 0..<12 {
            hosting.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.016))
        }
    }

    func showsUnavailablePage() -> Bool {
        let visible = strings().joined(separator: "\n")
        return visible.contains(appLocalized("This Credential Is Unavailable"))
            || visible.contains("凭证不可用")
    }

    func visibleAvailability() -> String? {
        let visible = strings()
        let joined = visible.joined(separator: "\n")
        if showsUnavailablePage() { return "unavailable" }
        if joined.contains(appLocalized("New Credential")) || joined.contains("新建凭证") {
            return "create"
        }
        if joined.contains(appLocalized("Edit Credential")) || joined.contains("编辑凭证")
            || visible.contains("Synthetic") {
            return "edit"
        }
        return nil
    }

    func strings() -> [String] {
        var found: [String] = []
        func append(_ value: String?) {
            guard let value, !value.isEmpty, value != "-" else { return }
            found.append(value)
        }
        func walkViews(_ view: NSView) {
            if let field = view as? NSTextField {
                append(field.stringValue)
                append(field.placeholderString)
            }
            if let button = view as? NSButton {
                append(button.title)
                append(button.alternateTitle)
            }
            view.subviews.forEach(walkViews)
        }
        walkViews(hosting)
        found.append(contentsOf: recognizedLines().map(\.text))
        return Array(Set(found))
    }

    func findButton(titled title: String) -> NSButton? {
        func walk(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            for child in view.subviews {
                if let match = walk(child) { return match }
            }
            return nil
        }
        return walk(hosting)
    }

    func press(titled title: String) -> Bool {
        if let button = findButton(titled: title) {
            button.performClick(nil)
            return true
        }
        return clickRecognizedText(title)
    }

    private func clickRecognizedText(_ title: String) -> Bool {
        guard let line = recognizedLines().first(where: { $0.text.contains(title) }) else {
            return false
        }
        let before = routeBox.route
        let points = [
            NSPoint(x: line.frame.midX, y: line.frame.midY),
            NSPoint(x: line.frame.midX, y: hosting.bounds.height - line.frame.midY),
            NSPoint(x: line.frame.midX, y: line.frame.minY + 6),
            NSPoint(x: line.frame.midX, y: line.frame.maxY - 6),
        ]
        for point in points {
            sendClick(at: point)
            pump()
            if routeBox.route != before { return true }
        }
        return false
    }

    private func sendClick(at point: NSPoint) {
        let location = hosting.convert(point, to: nil)
        guard
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ),
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 0
            )
        else { return }
        window.sendEvent(down)
        hosting.mouseDown(with: down)
        window.sendEvent(up)
        hosting.mouseUp(with: up)
    }

    private func recognizedLines() -> [(text: String, frame: CGRect)] {
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return []
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        guard let image = representation.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let bounds = hosting.bounds
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else {
                return nil
            }
            let box = observation.boundingBox
            let frame = CGRect(
                x: box.origin.x * bounds.width,
                y: box.origin.y * bounds.height,
                width: box.size.width * bounds.width,
                height: box.size.height * bounds.height
            )
            return (text, frame)
        }
    }
}
