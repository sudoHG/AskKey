import AppKit
import AskKeyBroker
import AskKeyDevicesTestSupport
import AskKeyTestSupport
import SwiftUI
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyDevices

/// Renders every remote-approval state of the Mac App offscreen, in English
/// and Simplified Chinese, as 2x PNGs (#313, #336): the pending-requests
/// list in the real management window; Settings → Devices at the window's
/// content width with an iPhone that approves, one paired before #336
/// without approval, and Remove's confirmation; every step of the pairing
/// sheet with its approval statements at its own size (a SwiftUI sheet can't
/// be captured offscreen); and the approval panel through the production
/// panel factory, with its footer before and after the send (#350, worded
/// as in #356). No window is ordered in. Set
/// `REMOTE_APPROVAL_RENDER_DIRECTORY` to keep the PNGs, and also
/// `REMOTE_APPROVAL_WINDOW_RENDERS=1` on a desktop session to render the
/// Devices section in the real Settings window, scrolled to it.
@MainActor
final class RemoteApprovalRenderTests: AskKeyAppTestCase {
    private var directory: URL!
    private var keepsRenders = false
    /// On the CI runner a programmatic scroll of the offscreen Settings
    /// window draws an empty content column (184335b), so the scrolled
    /// window is rendered only when asked for.
    private var rendersWindow: Bool {
        keepsRenders && ProcessInfo.processInfo.environment["REMOTE_APPROVAL_WINDOW_RENDERS"] == "1"
    }
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
            names += try await renderPairingSheet(tag: tag)
            let harness = try DeviceCoordinatorHarness()
            defer { try? harness.close() }
            await harness.coordinator.launch()
            try await harness.pairPhone()
            DeviceServicesHost.install(harness.coordinator)
            names += try await renderDevices(harness, language: language, tag: tag)
            names += try renderPanel(tag: tag)
            names += try renderPendingList(harness, language: language, tag: tag)
            names += try renderFooters(tag: tag)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(Set(files), Set(names.map { $0 + ".png" }))
        XCTAssertEqual(names.count, rendersWindow ? 38 : 36)
    }

    // MARK: Settings → Devices

    /// The Devices section at the management window's content width: an
    /// iPhone that approves, Remove's confirmation, and an iPhone paired
    /// before #336 without approval next to it. A programmatic scroll of the
    /// offscreen Settings window drew nothing on the CI runner, so the real
    /// window's capture is taken only when asked for; CI's desktop
    /// screenshot flow captures the window (30/35, 43/45).
    private func renderDevices(_ harness: DeviceCoordinatorHarness, language: String, tag: String) async throws -> [String] {
        let model = DevicesSettingsModel(coordinator: harness.coordinator)
        let width = WorkspaceVisualContract.windowWidth - WorkspaceVisualContract.sidebarWidth
        var names: [String] = []
        func section(_ name: String) throws {
            try renderAlone(DevicesSettingsSection(model: model)
                .padding(Theme.Spacing.xxl)
                .frame(width: width)
                .background(Theme.windowBackground), as: name)
            names.append(name)
        }
        try await drain(harness)
        let row = try XCTUnwrap(harness.coordinator.devices.first)
        XCTAssertTrue(row.isApprover, "pairing made the iPhone an approver")
        try section("01-\(tag)-devices-iphone-approves")
        model.requestRemoval(row)
        try section("03-\(tag)-devices-remove-confirmation")
        model.cancelRemoval()
        let older = SimulatedPairingPhone(transport: harness.transport, clock: harness.clock)
        try await harness.addUnflaggedEntry(for: older, name: "Older iPhone")
        try await drain(harness)
        XCTAssertEqual(harness.coordinator.devices.map(\.isApprover), [true, false])
        try section("02-\(tag)-devices-iphone-cannot-approve")
        if rendersWindow { names.append(try renderSettingsWindow(language: language, tag: tag)) }
        return names
    }

    /// Settings in the real management window, built as
    /// `ensureManagementWindow` builds it, scrolled to the Devices section.
    private func renderSettingsWindow(language: String, tag: String) throws -> String {
        let fixture = try NoticeLayoutFixtures.Model(language: language, state: .management, recovery: false, broker: false)
        defer { fixture.close() }
        let navigation = ManagementNavigation()
        navigation.route = .settings
        let window = ManagementWindowConfiguration.makeWindow(rootView: SettingsView(navigation: navigation)
            .environment(fixture.vault)
            .environment(\.locale, fixture.vault.appLocale))
        defer { window.close() }
        ManagementWindowConfiguration.apply(to: window)
        window.appearance = NSAppearance(named: .aqua)
        settle(window)
        XCTAssertFalse(window.isVisible)
        let scroll = try settingsScrollView(in: try XCTUnwrap(window.contentView))
        let document = try XCTUnwrap(scroll.documentView)
        let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? bottom : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(window)
        let name = "16-\(tag)-settings-window-devices"
        try export(try XCTUnwrap(window.contentView?.superview), as: name, contentFrom: WorkspaceVisualContract.sidebarWidth)
        return name
    }

    private func settingsScrollView(in root: NSView) throws -> NSScrollView {
        var pending = [root]
        var found: [NSScrollView] = []
        while let view = pending.popLast() {
            if let scroll = view as? NSScrollView,
               scroll.convert(scroll.bounds, to: nil).midX > WorkspaceVisualContract.sidebarWidth {
                found.append(scroll)
            }
            pending.append(contentsOf: view.subviews)
        }
        return try XCTUnwrap(found.max { $0.bounds.height < $1.bounds.height })
    }

    // MARK: Pairing sheet

    /// Every step of the pairing sheet: the QR code with the install reminder
    /// and the approval statement, the code matched with what a request
    /// sends, system authentication, waiting for the iPhone, and paired.
    private func renderPairingSheet(tag: String) async throws -> [String] {
        let harness = try DeviceCoordinatorHarness()
        defer { try? harness.close() }
        await harness.coordinator.launch()
        let coordinator = harness.coordinator
        let model = DevicesSettingsModel(coordinator: coordinator)
        var names: [String] = []
        func sheet(_ number: Int, _ label: String) throws {
            let name = String(format: "%02d-%@-pairing-%@", number, tag, label)
            names.append(name)
            try renderAlone(DevicePairingSheet(model: model), as: name)
        }
        await model.pairDevice()
        guard case .qrCode(let text, _) = try XCTUnwrap(model.sheet).stage else { throw SyntheticRemoteFailure() }
        XCTAssertEqual(model.sheet?.showsInstallReminder, true)
        try sheet(4, "qr-code")
        try await harness.phone.scan(text)
        await coordinator.refresh()
        try sheet(5, "waiting")
        try await harness.phone.poll()
        await coordinator.refresh()
        try sheet(6, "code-entry")
        let shown = await harness.phone.shownCode()
        // The code matched; the person has not confirmed yet.
        harness.script.authenticationResults = [.cancelled]
        model.codeEntry = try XCTUnwrap(shown)
        await model.confirm()
        coordinator.pairingFeedback = nil
        XCTAssertNotNil(model.sheet?.requestContents, "the sheet says what a request sends")
        try sheet(7, "code-accepted")
        coordinator.isAuthenticatingPairing = true
        try sheet(8, "authenticating")
        coordinator.isAuthenticatingPairing = false
        await model.confirm()
        guard case .waitingForIPhoneConfirmation = coordinator.pairing else { throw SyntheticRemoteFailure() }
        try sheet(9, "waiting-for-iphone")
        try await harness.phone.confirm()
        try await harness.phone.poll()
        await coordinator.refresh()
        guard case .paired = coordinator.pairing else { throw SyntheticRemoteFailure() }
        try sheet(10, "paired")
        await model.closeSheet()
        return names
    }

    // MARK: Approval panel

    /// Details with where the request went, and an approver's decision, in
    /// the production panel. The card's front is the same as without them.
    private func renderPanel(tag: String) throws -> [String] {
        let sent = Date()
        let deviceID = try XCTUnwrap(DeviceID(rawValue: Data(repeating: 9, count: 16)))
        func status(delivered: Bool) -> RemoteApprovalStatus {
            RemoteApprovalStatus(approvers: [.init(deviceID: deviceID, displayName: "Synthetic iPhone", sentAt: sent,
                                                   deliveredAt: delivered ? sent.addingTimeInterval(2) : nil)])
        }
        let cases: [(String, RemoteApprovalPanelState, Bool)] = [
            // Saved and still open, so the footer has the sent hint (#350).
            ("11", RemoteApprovalPanelState(requestID: "synthetic", status: status(delivered: false), footer: .sent), true),
            ("12", RemoteApprovalPanelState(requestID: "synthetic", status: status(delivered: true), footer: .sent), true),
            ("13", outcome(approved: true, status: status(delivered: true)), false),
            ("14", outcome(approved: false, status: status(delivered: true)), false),
        ]
        let labels = ["11": "panel-details-not-delivered", "12": "panel-details-delivered",
                      "13": "panel-approved-on-iphone", "14": "panel-denied-on-iphone"]
        var names: [String] = []
        for (number, remote, expanded) in cases {
            let name = "\(number)-\(tag)-\(labels[number]!)"
            try renderPanel(remote: remote, expanded: expanded, expiresAt: Date(timeIntervalSinceNow: 300), as: name)
            names.append(name)
        }
        return names
    }

    /// The footer with a paired iPhone (#350) in the maintainer's wording
    /// (#356): the send countdown at 18 seconds, the expiry after the send,
    /// and the expiry when no approver can take the request, never with an
    /// Esc hint. Details stay collapsed, so the render shows the whole front
    /// next to the footer.
    private func renderFooters(tag: String) throws -> [String] {
        let deviceID = try XCTUnwrap(DeviceID(rawValue: Data(repeating: 9, count: 16)))
        let sent = RemoteApprovalStatus(approvers: [.init(deviceID: deviceID, displayName: "Synthetic iPhone",
                                                          sentAt: Date(), deliveredAt: nil)])
        var names: [String] = []
        // The footer ticks just after each whole second before its anchor, so
        // an anchor 0.05 s short of a whole second keeps the number for almost
        // a second, longer than a render takes.
        // A render that took longer is taken again, so the PNG shows `number`.
        func footer(_ label: String, expiresIn: TimeInterval, shows number: String,
                    state: (Date) -> RemoteApprovalPanelState) throws {
            let name = "\(label.prefix(2))-\(tag)-\(label.dropFirst(3))"
            for _ in 0..<3 {
                let now = Date()
                let remote = state(now)
                let expiresAt = now.addingTimeInterval(expiresIn)
                let schedule = RemoteApprovalFooterSchedule(anchor: RemoteApprovalFooter.anchor(remote.footer, expiresAt: expiresAt))
                let tick = try XCTUnwrap(schedule.entries(from: now, mode: .normal).next())
                let shown = RemoteApprovalFooter.text(remote.footer, expiresAt: expiresAt, now: tick)
                XCTAssertTrue(shown.contains(number), "\(label) shows \(shown)")
                XCTAssertFalse(shown.contains("Esc"), "\(label) shows \(shown)")
                try renderPanel(remote: remote, expanded: false, expiresAt: expiresAt, as: name)
                if Date().timeIntervalSince(now) < 0.9 {
                    names.append(name)
                    return
                }
            }
            XCTFail("\(name) took longer than 0.9 s to render three times")
        }
        try footer("17-panel-footer-send-in-18s", expiresIn: 297.95, shows: "18") {
            RemoteApprovalPanelState(requestID: "synthetic", footer: .waiting(sendAt: $0.addingTimeInterval(17.95)))
        }
        try footer("18-panel-footer-after-send", expiresIn: 279.95, shows: "4:39") { _ in
            RemoteApprovalPanelState(requestID: "synthetic", status: sent, footer: .sent)
        }
        try footer("19-panel-footer-no-approver", expiresIn: 299.95, shows: "4:59") { _ in
            RemoteApprovalPanelState(requestID: "synthetic")
        }
        return names
    }

    private func renderPanel(remote: RemoteApprovalPanelState, expanded: Bool, expiresAt: Date, as name: String) throws {
        let request = ApprovalCardFixtures.request(.read, display: ApprovalCardFixtures.display())
        let prompt = FrozenAgentApprovalPrompt(request: request, trustedCredentialName: "Staging API",
            expiresAt: expiresAt, timedAllowanceEnabled: true, remote: remote,
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
        try export(frame, as: name)
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
        try export(try XCTUnwrap(window.contentView?.superview), as: name, contentFrom: WorkspaceVisualContract.sidebarWidth)
        return [name]
    }

    // MARK: Coordinator

    /// The Devices section's window starts a poll when it appears. A refresh
    /// that comes while a finished poll has not been cleared yet returns
    /// without polling, so the flows wait for that work and repeat a refresh
    /// until the iPhone's message was processed.
    private func drain(_ harness: DeviceCoordinatorHarness) async throws {
        try await Task.sleep(for: .milliseconds(50))
        await harness.coordinator.devicesOpened()
        try await harness.waitUntil { harness.coordinator.pollTask == nil }
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

    /// Writes the PNG and fails when the part right of `contentFrom` points
    /// is a single color, as an offscreen window that drew nothing would be.
    private func export(_ view: NSView, as name: String, contentFrom: CGFloat = 0) throws {
        let bitmap = try Self.render(view)
        var colors = Set<String>()
        let scale = CGFloat(bitmap.pixelsWide) / max(view.bounds.width, 1)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 12) {
            for x in stride(from: Int(contentFrom * scale), to: bitmap.pixelsWide, by: 12) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                colors.insert(String(format: "%.2f %.2f %.2f", color.redComponent, color.greenComponent, color.blueComponent))
            }
        }
        XCTAssertGreaterThan(colors.count, 8, "\(name) drew nothing")
        XCTAssertGreaterThan(colors.count, 1, "\(name) is a single color")
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
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
