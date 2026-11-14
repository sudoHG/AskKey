import AppKit
import AskKeyBroker
import AskKeyDevicesTestSupport
import AskKeyTestSupport
import SwiftUI
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyDevices

/// Renders every new remote-approval state of the Mac App offscreen, in
/// English and Simplified Chinese, as 2x PNGs (#313): Settings → Devices with
/// approval off and on and the pending-requests list in the real management
/// window, each step of the approver sheet and the pairing sheet's install
/// reminder at their own size (a SwiftUI sheet can't be captured offscreen),
/// and the approval panel through the production panel factory. No window is
/// ordered in. Set `REMOTE_APPROVAL_RENDER_DIRECTORY` to keep the PNGs.
@MainActor
final class RemoteApprovalRenderTests: AskKeyAppTestCase {
    private var directory: URL!
    private var keepsRenders = false
    private var previousIcon: NSImage?

    override func setUp() async throws {
        if let path = ProcessInfo.processInfo.environment["REMOTE_APPROVAL_RENDER_DIRECTORY"] {
            directory = URL(fileURLWithPath: path, isDirectory: true)
            keepsRenders = true
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AskKeyRemoteApprovalRenders-\(UUID().uuidString)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        previousIcon = NSApp.applicationIconImage
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApp.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("assets/AppIcon.icon/Assets/AppIcon.png"))
    }

    override func tearDown() async throws {
        NSApp.applicationIconImage = previousIcon
        // This process has no CloudKit entitlement: leave a coordinator that
        // is not configured, as the other Devices tests expect.
        let library = try AgentAccessPolicyTestLibrary()
        DeviceServicesHost.install(DeviceCoordinator(environment: DeviceCoordinatorEnvironment(
            vault: library.vault, backend: nil, inboxState: VaultDeviceInboxStateStore(vault: library.vault),
            authenticate: { _ in .cancelled }, isManagementSessionActive: { false }, automaticPolling: false)))
        try? library.close()
        if !keepsRenders { try? FileManager.default.removeItem(at: directory) }
    }

    func testRemoteApprovalStatesRenderInBothLanguages() async throws {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        var names: [String] = []
        for language in ["en", "zh-Hans"] {
            AppLanguage.current = language
            let tag = language == "en" ? "en" : "zh"
            let harness = try DeviceCoordinatorHarness()
            defer { try? harness.close() }
            await harness.coordinator.launch()
            try await harness.pairPhone()
            DeviceServicesHost.install(harness.coordinator)
            names += try await renderDevices(harness, language: language, tag: tag)
            names += try await renderApproverSheet(harness, tag: tag)
            names += try renderPanel(tag: tag)
            names += try renderPendingList(harness, language: language, tag: tag)
            names += try await renderPairingReminder(tag: tag)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(Set(files), Set(names.map { $0 + ".png" }))
        XCTAssertEqual(names.count, 32)
    }

    // MARK: Settings → Devices

    /// The Devices section in the real management window, scrolled down to it.
    private func renderDevices(_ harness: DeviceCoordinatorHarness, language: String, tag: String) async throws -> [String] {
        let fixture = try NoticeLayoutFixtures.Model(language: language, state: .management, recovery: false, broker: false)
        defer { fixture.close() }
        var names: [String] = []
        for enabled in [false, true] {
            if enabled { try await harness.enableApprover(harness.phone) }
            let navigation = ManagementNavigation()
            navigation.route = .settings
            let window = ManagementWindowConfiguration.makeWindow(
                rootView: SettingsView(navigation: navigation)
                    .environment(fixture.vault)
                    .environment(\.locale, fixture.vault.appLocale)
            )
            defer { window.close() }
            window.appearance = NSAppearance(named: .aqua)
            settle(window)
            try scrollToBottom(window)
            settle(window)
            XCTAssertFalse(window.isVisible)
            XCTAssertEqual(window.frame.size, ManagementWindowConfiguration.frameSize)
            let name = "\(enabled ? "02" : "01")-\(tag)-devices-approval-\(enabled ? "on" : "off")"
            try export(try XCTUnwrap(window.contentView?.superview), as: name)
            names.append(name)
        }
        XCTAssertTrue(try XCTUnwrap(harness.coordinator.devices.first).isApprover)
        // Off again for the sheet's steps; turning it off asks for nothing.
        let model = DevicesSettingsModel(coordinator: harness.coordinator)
        await model.setApprover(try XCTUnwrap(harness.coordinator.devices.first), enabled: false)
        XCTAssertFalse(try XCTUnwrap(harness.coordinator.devices.first).isApprover)
        return names
    }

    // MARK: Approver sheet

    private func renderApproverSheet(_ harness: DeviceCoordinatorHarness, tag: String) async throws -> [String] {
        let coordinator = harness.coordinator
        let model = DevicesSettingsModel(coordinator: coordinator)
        let mac = try XCTUnwrap(harness.macDeviceID)
        var names: [String] = []
        func sheet(_ number: Int, _ label: String) throws -> NSView {
            let name = String(format: "%02d-%@-approver-sheet-%@", number, tag, label)
            names.append(name)
            return try renderAlone(ApproverConfirmationSheet(model: model), as: name)
        }
        func wrong(_ code: ApproverCode) -> String { String(format: "%06d", ((Int(code.digits) ?? 0) + 1) % 1_000_000) }
        func type(_ code: String, on phone: SimulatedPairingPhone) async throws {
            try await phone.confirmApprover(typing: code, for: mac)
            await coordinator.refresh()
        }
        let row = try XCTUnwrap(coordinator.devices.first { $0.id == harness.phone.deviceID })
        await model.setApprover(row, enabled: true)
        _ = try sheet(3, "intro")
        coordinator.approverConfirmation = .authenticating(device: row)
        _ = try sheet(4, "authenticating")
        coordinator.approverConfirmation = nil

        await model.continueApprover()
        let code = try XCTUnwrap(coordinator.approverCode)
        _ = try sheet(5, "code")
        try await type(wrong(code), on: harness.phone)
        _ = try sheet(6, "wrong-code")
        try await type(wrong(code), on: harness.phone)
        try await type(wrong(code), on: harness.phone)
        _ = try sheet(7, "too-many-wrong-codes")

        await model.startApproverAgain()
        harness.clock.advance(by: DeviceCoordinator.approverCodeLifetime + 1)
        _ = await coordinator.approverLoopStep()
        _ = try sheet(8, "expired")

        let spare = SimulatedPairingPhone(transport: harness.transport, clock: harness.clock)
        try await harness.pair(spare, name: "Spare iPhone")
        await model.startApproverAgain()
        try await type(try XCTUnwrap(coordinator.approverCode).formatted, on: spare)
        _ = try sheet(9, "entered-on-other-device")

        await model.startApproverAgain()
        try await type(try XCTUnwrap(coordinator.approverCode).formatted, on: harness.phone)
        guard case .enabled = coordinator.approverConfirmation else { throw SyntheticRemoteFailure() }
        _ = try sheet(10, "enabled")
        model.closeApproverSheet()
        return names
    }

    // MARK: Approval panel

    /// Details with where the request went, and an approver's decision, in
    /// the production panel. The card's front is the same as without them.
    private func renderPanel(tag: String) throws -> [String] {
        let request = ApprovalCardFixtures.request(.read, display: ApprovalCardFixtures.display())
        let sent = Date()
        let deviceID = try XCTUnwrap(DeviceID(rawValue: Data(repeating: 9, count: 16)))
        func status(delivered: Bool) -> RemoteApprovalStatus {
            RemoteApprovalStatus(approvers: [.init(deviceID: deviceID, displayName: "Synthetic iPhone", sentAt: sent,
                                                   deliveredAt: delivered ? sent.addingTimeInterval(2) : nil)])
        }
        let cases: [(String, RemoteApprovalPanelState, Bool)] = [
            ("11", RemoteApprovalPanelState(requestID: "synthetic", status: status(delivered: false)), true),
            ("12", RemoteApprovalPanelState(requestID: "synthetic", status: status(delivered: true)), true),
            ("13", outcome(approved: true, status: status(delivered: true)), false),
            ("14", outcome(approved: false, status: status(delivered: true)), false),
        ]
        let labels = ["11": "panel-details-not-delivered", "12": "panel-details-delivered",
                      "13": "panel-approved-on-iphone", "14": "panel-denied-on-iphone"]
        var names: [String] = []
        for (number, remote, expanded) in cases {
            let prompt = FrozenAgentApprovalPrompt(request: request, trustedCredentialName: "Staging API",
                expiresAt: Date(timeIntervalSinceNow: 300), timedAllowanceEnabled: true, remote: remote,
                detailsExpanded: expanded, finish: { _ in XCTFail("Rendering must never decide") })
            let plain = FrozenAgentApprovalPrompt(request: request, trustedCredentialName: "Staging API",
                expiresAt: nil, timedAllowanceEnabled: true, finish: { _ in })
            XCTAssertEqual(prompt.presentation.content, plain.presentation.content, "the card's front is unchanged")
            XCTAssertEqual(prompt.presentation.buttons.map(\.identifier), plain.presentation.buttons.map(\.identifier))
            let panel = AppDelegate.makeFrozenApprovalPanel(prompt, visibleFrame: { _ in NSRect(x: 0, y: 0, width: 1440, height: 900) })
            panel.appearance = NSAppearance(named: .aqua)
            defer { panel.contentViewController = nil; panel.close() }
            let content = try XCTUnwrap(panel.contentView)
            settle(panel)
            XCTAssertFalse(panel.isVisible)
            let frame = try XCTUnwrap(content.superview)
            _ = try Self.render(frame) // warm lazy image drawing
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            let name = "\(number)-\(tag)-\(labels[number]!)"
            try export(frame, as: name)
            names.append(name)
        }
        return names
    }

    private func outcome(approved: Bool, status: RemoteApprovalStatus) -> RemoteApprovalPanelState {
        let state = RemoteApprovalPanelState(requestID: "synthetic", status: status)
        state.record(RemoteAppliedDecision(requestID: "synthetic", deviceName: "Synthetic iPhone", approved: approved), now: Date())
        return state
    }

    // MARK: Pending requests

    /// The list in the real management window; the first request went to
    /// the iPhone, the second stayed on the Mac.
    private func renderPendingList(_ harness: DeviceCoordinatorHarness, language: String, tag: String) throws -> [String] {
        let fixture = try NoticeLayoutFixtures.Model(language: language, state: .management, recovery: false, broker: false)
        defer { fixture.close() }
        let first = ApprovalCardFixtures.request(.read, display: ApprovalCardFixtures.display())
        let second = BrokerApprovalOperationRequest(
            operationID: "synthetic-second", credentialID: "synthetic-credential-2", targetID: "synthetic-credential-2",
            operation: .read, payloadDigest: String(repeating: "b", count: 64), credentialName: "Release Tools",
            callerName: "Codex", display: ApprovalCardFixtures.display(command: "./release.sh --dry-run"))
        let deviceID = try XCTUnwrap(DeviceID(rawValue: Data(repeating: 9, count: 16)))
        harness.coordinator.remoteApprovals = [first.operationID: RemoteApprovalStatus(approvers: [
            .init(deviceID: deviceID, displayName: "Synthetic iPhone", sentAt: Date(), deliveredAt: nil),
        ])]
        defer { harness.coordinator.remoteApprovals = [:] }
        XCTAssertTrue(harness.coordinator.wasSentToApprover(first.operationID))
        XCTAssertFalse(harness.coordinator.wasSentToApprover(second.operationID))
        let window = ManagementWindowConfiguration.makeWindow(rootView:
            CredentialManagementView(initialRoute: .pendingRequests, previewMode: true, previewPendingRequests: [first, second])
                .environment(fixture.vault)
                .environment(\.locale, fixture.vault.appLocale)
                .preferredColorScheme(.light))
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        settle(window)
        XCTAssertFalse(window.isVisible)
        let name = "15-\(tag)-pending-sent-to-iphone"
        try export(try XCTUnwrap(window.contentView?.superview), as: name)
        return [name]
    }

    // MARK: Pairing sheet

    private func renderPairingReminder(tag: String) async throws -> [String] {
        let harness = try DeviceCoordinatorHarness()
        defer { try? harness.close() }
        await harness.coordinator.launch()
        let model = DevicesSettingsModel(coordinator: harness.coordinator)
        await model.pairDevice()
        XCTAssertEqual(model.sheet?.showsInstallReminder, true)
        let name = "16-\(tag)-pairing-install-reminder"
        _ = try renderAlone(DevicePairingSheet(model: model), as: name)
        await model.closeSheet()
        return [name]
    }

    // MARK: Rendering

    private func settle(_ window: NSWindow) {
        let view = window.contentView!
        for _ in 0..<8 {
            window.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    /// Scrolls the content column's scroll view to its end, where Devices sits.
    private func scrollToBottom(_ window: NSWindow) throws {
        var pending: [NSView] = [try XCTUnwrap(window.contentView)]
        var found: NSScrollView?
        while let view = pending.popLast() {
            if let scrollView = view as? NSScrollView,
               scrollView.convert(scrollView.bounds, to: nil).midX > WorkspaceVisualContract.sidebarWidth {
                found = scrollView
                break
            }
            pending.append(contentsOf: view.subviews)
        }
        let scrollView = try XCTUnwrap(found, "the Settings page scrolls")
        let document = try XCTUnwrap(scrollView.documentView)
        let clip = scrollView.contentView
        let end = max(0, document.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: document.isFlipped ? end : 0))
        scrollView.reflectScrolledClipView(clip)
    }

    /// A view at its own fitting size, without a window, like a sheet's content.
    @discardableResult
    private func renderAlone<V: View>(_ view: V, as name: String) throws -> NSView {
        let hosting = NSHostingView(rootView: view.environment(\.locale, AppLanguage.store.locale))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.bounds.height, 60, name)
        try export(hosting, as: name)
        return hosting
    }

    private func export(_ view: NSView, as name: String) throws {
        let png = try XCTUnwrap(Self.render(view).representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5_000, "\(name) did not render")
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }

    /// Twice the view's size in pixels, whatever screen this process has.
    static func render(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * 2)), pixelsHigh: Int(ceil(size.height * 2)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
}
