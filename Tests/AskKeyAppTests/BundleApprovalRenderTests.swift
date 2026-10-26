import AppKit
import SwiftUI
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit
@testable import AskKeyVault

/// Hidden production panels fed by real, synthetic-Vault approval metadata.
/// Export is opt-in; neither the App nor any on-screen window is launched.
@MainActor
final class BundleApprovalRenderTests: AskKeyAppTestCase {
    func testBundleReadApprovalPanelsInBothLanguages() throws {
        _ = NSApplication.shared
        let previousIcon = NSApp.applicationIconImage
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApp.applicationIconImage = try XCTUnwrap(NSImage(contentsOf: root.appendingPathComponent("assets/AppIcon.icon/Assets/AppIcon.png")))
        defer { NSApp.applicationIconImage = previousIcon }
        try ApprovalCardFixtures.withLanguages { language in
            for variant in ["mapped", "undelivered", "long-list"] {
                let library = try AgentAccessPolicyTestLibrary(
                    approvalRequests: BrokerApprovalStateMachine(authenticate: { _ in true }))
                defer { try? library.close() }
                try library.vault.beginManagementSession(using: .allow)
                let components = Self.components(variant)
                _ = try library.vault.createBundleCredential(
                    .init(name: "Release Tools", components: components), using: .allow)
                let run = BrokerTextRunRequest(operationID: "synthetic-\(language)-\(variant)",
                    command: ["./deploy.sh", "--environment", "staging"], credentialNames: ["Release Tools"],
                    workingDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("staging").path,
                    callerName: "Codex", callerPurpose: "Deploy the synthetic staging service")
                guard case .approvalRequired = try library.vault.brokerTextCredentials(for: run, cancellation: .init()) else {
                    return XCTFail("Expected a real synthetic-Vault approval")
                }
                let request = try XCTUnwrap(library.vault.approvalRequests.pendingRequests().first?.request)
                let display = try XCTUnwrap(request.display)
                XCTAssertEqual(display.environmentVariables?.count, variant == "long-list" ? 24 : 3)
                XCTAssertEqual(display.temporaryFileVariables, ["RELEASE_CERT_FILE"])
                XCTAssertFalse(String(describing: display).contains("LOCAL_RECOVERY_CODE"))
                XCTAssertFalse(String(describing: display).contains("synthetic-value"))
                for expanded in [false, true] {
                    let prompt = FrozenAgentApprovalPrompt(request: request, trustedCredentialName: "Release Tools",
                        expiresAt: Date(timeIntervalSinceNow: 300), timedAllowanceEnabled: true,
                        detailsExpanded: expanded, finish: { _ in XCTFail("Rendering must never decide") })
                    let panel = Self.panel(prompt)
                    defer { panel.contentViewController = nil; panel.close() }
                    let content = try XCTUnwrap(panel.contentView)
                    for _ in 0..<8 {
                        panel.layoutIfNeeded()
                        content.layoutSubtreeIfNeeded()
                        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
                    }
                    XCTAssertFalse(panel.isVisible)
                    XCTAssertEqual(content.bounds.width, FrozenAgentApprovalPrompt.width, accuracy: 0.5)
                    // fullSizeContentView includes the native title-bar safe area.
                    let promptHeight = content.bounds.height - content.safeAreaInsets.top - content.safeAreaInsets.bottom
                    XCTAssertLessThanOrEqual(promptHeight, FrozenAgentApprovalPrompt.maximumHeight + 0.5)
                    XCTAssertGreaterThan(promptHeight, 200)
                    if expanded, variant == "long-list" {
                        XCTAssertEqual(promptHeight, FrozenAgentApprovalPrompt.maximumHeight, accuracy: 0.5)
                    }
                    let frame = try XCTUnwrap(content.superview)
                    let bitmap = try NoticeLayoutFixtures.render(frame)
                    XCTAssertFalse(panel.isVisible)
                    try Self.export(bitmap, name: "\(language)-\(variant)-\(expanded ? "details" : "collapsed")")
                }
            }
        }
    }

    /// The production factory and AppDelegate's hosting/chrome configuration;
    /// omit only presentation, timers and request-decision side effects.
    private static func panel(_ prompt: FrozenAgentApprovalPrompt) -> NSPanel {
        let panel = AgentApprovalPanelFactory.make(
            contentSize: NSSize(width: FrozenAgentApprovalPrompt.width, height: 360))
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingController(rootView: prompt)
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)
        return panel
    }

    private static func components(_ variant: String) -> [CredentialComponentInput] {
        var components = variant == "long-list" ? (1...24).map {
            CredentialComponentInput(name: "Service \($0)", value: .text("synthetic-value-\($0)"),
                delivery: .environmentVariable(String(format: "STAGING_SERVICE_%02d_ACCESS_TOKEN", $0)))
        } : [
            .init(name: "Token", value: .text("synthetic-value"), delivery: .environmentVariable("RELEASE_TOKEN")),
            .init(name: "User", value: .text("synthetic-value"), delivery: .environmentVariable("RELEASE_USER")),
            .init(name: "Host", value: .text("synthetic-value"), delivery: .environmentVariable("RELEASE_HOST")),
        ]
        components.append(.init(name: "Certificate", value: .file(filename: "synthetic.pem", bytes: Data("synthetic-value".utf8)),
                                delivery: .temporaryFile("RELEASE_CERT_FILE")))
        if variant == "undelivered" {
            components.append(.init(name: "LOCAL_RECOVERY_CODE", value: .text("synthetic-value"), delivery: .none))
        }
        return components
    }

    private static func export(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["BUNDLE_APPROVAL_RENDER_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
