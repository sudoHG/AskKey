import AskKeyDevices
import SwiftUI
import XCTest
@testable import AskKeyiOSKit

/// Renders every screen state from the app's own SwiftUI views with fixed
/// states, in English and Simplified Chinese, for review. `build-ios.sh
/// test` passes the output directory; CI uploads it.
@MainActor
final class ScreenRenderTests: XCTestCase {
    private static let languages = ["en", "zh-Hans"]
    private static let mac = "Studio Mac"
    private static let pairedAt = Date(timeIntervalSince1970: 1_793_000_000)
    /// An iPhone screen in points; taller content makes a taller image.
    private static let screenSize = CGSize(width: 393, height: 852)

    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["SCREEN_RENDER_DIRECTORY"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyiOSScreens", isDirectory: true)
    }

    private func render<Screen: View>(_ name: String, _ screen: Screen,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var images: [Data] = []
        for language in Self.languages {
            let content = screen
                .frame(width: Self.screenSize.width)
                .frame(minHeight: Self.screenSize.height, alignment: .top)
                .background(Color(uiColor: .systemGroupedBackground))
                .environment(\.locale, Locale(identifier: language))
                .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage, "\(name) did not render", file: file, line: line)
            XCTAssertGreaterThanOrEqual(image.size.height, Self.screenSize.height, file: file, line: line)
            let data = try XCTUnwrap(image.pngData(), file: file, line: line)
            try data.write(to: outputDirectory.appendingPathComponent("\(name)-\(language).png"))
            images.append(data)
        }
        XCTAssertNotEqual(images[0], images[1], "\(name) looks the same in both languages", file: file, line: line)
    }

    func testWelcome() throws {
        try render("01-welcome", WelcomeContent(step: .intro, onContinue: {}))
        try render("02-welcome-network-failure", WelcomeContent(step: .failed(.networkUnavailable), onContinue: {}))
    }

    func testScanner() throws {
        try render("03-scanner-camera-unavailable",
                   ScannerContent(camera: .unavailable, problem: nil, isSending: false, onDismissProblem: {},
                                  onCancel: {}) { EmptyView() })
        try render("04-scanner-expired-code",
                   ScannerContent(camera: .unavailable, problem: .expired, isSending: false, onDismissProblem: {},
                                  onCancel: {}) { EmptyView() })
    }

    func testPairingCode() throws {
        let display = PairingCodeDisplay(digits: "123 456", macName: Self.mac, confirmed: false)
        try render("05-pairing-no-code-yet",
                   PairingCodeContent(display: nil, isConfirming: false, problem: nil, onConfirm: {}, onCancel: {}))
        try render("06-pairing-code",
                   PairingCodeContent(display: display, isConfirming: false, problem: nil, onConfirm: {}, onCancel: {}))
        try render("07-pairing-face-id-cancelled",
                   PairingCodeContent(display: display, isConfirming: false, problem: .cancelled, onConfirm: {},
                                      onCancel: {}))
        try render("08-pairing-confirmed",
                   PairingCodeContent(display: PairingCodeDisplay(digits: "123 456", macName: Self.mac, confirmed: true),
                                      isConfirming: false, problem: nil, onConfirm: {}, onCancel: {}))
    }

    func testPairingOutcome() throws {
        try render("09-pairing-failed-no-challenge",
                   PairingResultContent(outcome: .failed(.noChallenge), onDone: {}))
        try render("10-pairing-paired", PairingResultContent(outcome: .paired(macName: Self.mac), onDone: {}))
    }

    func testPairedMacs() throws {
        let row = PairedMacRow(id: "mac", name: Self.mac, pairedAt: Self.pairedAt, lastReachedAt: nil, isApprover: true)
        try render("11-paired-macs-one-mac",
                   PairedMacsContent(rows: [row], accountNotice: nil, listNotice: nil, records: [], onPair: {},
                                     onSelect: { _ in }, onDismissNotice: {}))
        let reached = PairedMacRow(id: "mac", name: Self.mac, pairedAt: Self.pairedAt,
                                   lastReachedAt: Self.pairedAt.addingTimeInterval(600), isApprover: true)
        let records = [
            DeliveryRecord(recordName: "a", arrivedAt: Self.pairedAt.addingTimeInterval(300), source: .polling),
            DeliveryRecord(recordName: "b", arrivedAt: Self.pairedAt.addingTimeInterval(600), source: .push),
        ]
        try render("12-paired-macs-reached",
                   PairedMacsContent(rows: [reached], accountNotice: nil,
                                     listNotice: .removed(name: "Office Mac", macWasTold: true), records: records,
                                     onPair: {}, onSelect: { _ in }, onDismissNotice: {}))
        try render("13-paired-macs-empty-signed-out",
                   PairedMacsContent(rows: [], accountNotice: .signedOut, listNotice: .removedByMac(name: Self.mac),
                                     records: [], onPair: {}, onSelect: { _ in }, onDismissNotice: {}))
    }

    func testUnusableIdentity() throws {
        try render("14-unusable-identity", UnusableIdentityContent(isResetting: false, resetFailed: false, onReset: {}))
    }

    // MARK: Approver (#314)

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let display = RequestDisplay(
        requesterName: "Codex", purpose: "Deploy the preview site", credentialName: "GitHub Token",
        commandLine: "./deploy.sh --prod --region eu-west-1 --notes 'release candidate for the docs site'",
        workingDirectory: "~/src/app", executableName: "deploy.sh",
        deliveryRows: [ApprovalDeliveryRow(kind: .environmentVariable, label: "", variable: "GITHUB_TOKEN")],
        offers: .all, timedDuration: 1_800)

    private static func card(_ display: RequestDisplay = display, decision: ApprovalDecisionCode? = nil,
                             isSent: Bool = false, outcome: RequestOutcome? = nil, isGone: Bool = false,
                             isChecking: Bool = false, secondsLeft: TimeInterval = 272) -> RequestCard {
        RequestCard(id: UUID().uuidString, macID: "mac", macName: mac, macPairedAt: pairedAt, display: display,
                    countdownEnd: now.addingTimeInterval(secondsLeft), decision: decision, isSent: isSent, outcome: outcome,
                    isGone: isGone, isChecking: isChecking)
    }

    private func renderCard(_ name: String, _ card: RequestCard, details: Bool = false,
                            problem: DecisionProblem? = nil) throws {
        try render(name, RequestCardContent(card: card, now: Self.now, problem: problem, showsDetails: details,
                                            onDecide: { _ in }, onDismiss: {})
            .padding(20))
    }

    /// The second Mac was paired before #336 without approval: its row is
    /// the only one marked.
    func testRequestsHome() throws {
        let rows = [PairedMacRow(id: "mac", name: Self.mac, pairedAt: Self.pairedAt,
                                 lastReachedAt: Self.pairedAt.addingTimeInterval(600), isApprover: true),
                    PairedMacRow(id: "office", name: "Office Mac", pairedAt: Self.pairedAt, lastReachedAt: nil)]
        try render("15-requests-home",
                   PairedMacsContent(rows: rows, accountNotice: nil, listNotice: nil, records: [], hasRequests: true,
                                     onPair: {}, onSelect: { _ in }, onDismissNotice: {}) {
                       RequestCardContent(card: Self.card(), now: Self.now, onDecide: { _ in }, onDismiss: {})
                   })
    }

    func testRequestCard() throws {
        try renderCard("16-request-card", Self.card())
        try renderCard("17-request-details", Self.card(), details: true)
        let shortened = RequestDisplay(requesterName: "", purpose: "", credentialName: "Prod Database",
                                   commandLine: "psql " + String(repeating: "--set=x ", count: 40) + "…",
                                   workingDirectory: "", executableName: "psql",
                                   deliveryRows: [ApprovalDeliveryRow(kind: .environmentVariable, label: "Password",
                                                                      variable: "PGPASSWORD"),
                                                  ApprovalDeliveryRow(kind: .temporaryFile, label: "Client certificate",
                                                                      variable: "PGSSLCERT")],
                                   shortened: [.commandLine], offers: .denyOnly)
        try renderCard("18-request-deny-only-shortened", Self.card(shortened), details: true)
        let unavailable = RequestDisplay(requesterName: "Claude Code", purpose: "", credentialName: "NAS Admin",
                                         commandLine: "ssh admin@nas.local", workingDirectory: "~", executableName: "ssh",
                                         deliveryRows: [], deliveryMetadataUnavailable: true, offers: .denyOnly)
        try renderCard("19-request-delivery-unavailable", Self.card(unavailable), details: true)
        try renderCard("20-request-face-id-cancelled", Self.card(), problem: .cancelled)
    }

    func testRequestProgress() throws {
        try renderCard("21-request-sending", Self.card(decision: .allowOnce))
        try renderCard("22-request-waiting", Self.card(decision: .timedAllowance, isSent: true))
    }

    func testRequestOutcomes() throws {
        let outcomes: [(String, RequestOutcome, ApprovalDecisionCode?)] = [
            ("23-outcome-allowed-once", .allowedOnce, .allowOnce),
            ("24-outcome-allowed-timed", .allowedTimed(seconds: 1_800), .timedAllowance),
            ("25-outcome-denied", .denied, .deny),
            ("26-outcome-decided-on-mac", .decidedOnMac, nil),
            ("27-outcome-decided-elsewhere", .decidedElsewhere, nil),
            ("28-outcome-expired", .expired, nil),
            ("29-outcome-cancelled", .cancelled, nil),
            ("30-outcome-not-applied", .notApplied, .allowOnce),
        ]
        for (name, outcome, decision) in outcomes {
            try renderCard(name, Self.card(decision: decision, isSent: decision != nil, outcome: outcome))
        }
        try renderCard("31-request-timed-out-check-mac", Self.card(decision: .allowOnce, isSent: true, secondsLeft: 0))
        try renderCard("32-request-mac-restarted", Self.card(isGone: true))
    }

    func testOpenedRequest() throws {
        try render("33-opened-request",
                   OpenedRequestContent(card: Self.card(), onClose: {}) { card in
                       RequestCardContent(card: card, now: Self.now, onDecide: { _ in }, onDismiss: {})
                   })
    }

    /// #337: a tapped notification's request before its card.
    func testOpeningRequest() throws {
        for (name, phase) in [("41-opened-request-loading", OpeningPhase.loading),
                              ("42-opened-request-unavailable", OpeningPhase.unavailable)] {
            try render(name, OpenedRequestContent(card: nil, opening: phase, onClose: {}) { card in
                RequestCardContent(card: card, now: Self.now, onDecide: { _ in }, onDismiss: {})
            })
        }
        try render("43-opened-request-checking", OpenedRequestContent(card: Self.card(isChecking: true), onClose: {}) { card in
            RequestCardContent(card: card, now: Self.now, onDecide: { _ in }, onDismiss: {})
        })
    }

    /// #342: the status line, Rename and Remove; only a Mac paired before
    /// #336 without approval lacks the flag.
    func testMacDetail() throws {
        let approving = PairedMacRow(id: "mac", name: Self.mac, pairedAt: Self.pairedAt,
                                     lastReachedAt: Self.pairedAt.addingTimeInterval(600), isApprover: true)
        try render("34-mac-detail-approving", MacDetailContent(row: approving, onRename: {}, onRemove: {}))
        let withoutFlag = PairedMacRow(id: "mac", name: Self.mac, pairedAt: Self.pairedAt,
                                       lastReachedAt: Self.pairedAt.addingTimeInterval(600))
        try render("35-mac-detail-without-approval-flag", MacDetailContent(row: withoutFlag, onRename: {}, onRemove: {}))
        try render("36-mac-detail-remove-confirmation",
                   ActionSheetStandIn(title: MacRemovalText.title(Self.mac), message: MacRemovalText.message,
                                      action: MacRemovalText.confirm) {
                       MacDetailContent(row: approving, onRename: {}, onRemove: {})
                   })
        // A failed removal leaves the entry, which this process refuses.
        try render("37-mac-detail-rename-and-removal-failed",
                   MacDetailContent(row: withoutFlag, renameProblem: .duplicate("Office Mac"), removalFailed: true,
                                    onRename: {}, onRemove: {}))
    }

    func testPrivacyCover() throws {
        try render("40-privacy-cover", PrivacyCoverView())
    }
}

/// iOS draws a `confirmationDialog` itself, so `ImageRenderer` cannot capture
/// it. This stand-in lays out the dialog's own texts the way an action sheet
/// shows them, over the screen it opens from, for the wording review.
private struct ActionSheetStandIn<Background: View>: View {
    let title: Text
    let message: Text
    let action: Text
    @ViewBuilder var background: Background

    var body: some View {
        ZStack(alignment: .bottom) {
            background
                .frame(maxHeight: .infinity, alignment: .top)
            Color.black.opacity(0.2)
            VStack(spacing: 8) {
                VStack(spacing: 0) {
                    VStack(spacing: 6) {
                        title.font(.footnote.weight(.semibold))
                        message.font(.footnote)
                    }
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    Divider()
                    action
                        .font(.title3)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground)))
                Text("common.cancel", bundle: .kit)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(uiColor: .systemBackground)))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        // A fixed height, the render's screen height, keeps the sheet at the bottom.
        .frame(height: 852)
    }
}
