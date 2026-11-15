import Foundation
import XCTest
import AskKeyVault
@testable import AskKeyAppKit

/// An access record a paired iPhone decided names that device in one detail
/// line, with the approval panel's wording (#329, ADR 0014). Every name and
/// value is synthetic.
@MainActor
final class AccessRecordDevicePresentationTests: AskKeyAppTestCase {
    private var previousLanguage = "en"

    override func setUp() {
        super.setUp()
        previousLanguage = AppLanguage.current
    }

    override func tearDown() {
        AppLanguage.current = previousLanguage
        super.tearDown()
    }

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(_ result: CredentialAccessEvent.Result, device: String?, offset: TimeInterval = 0,
                       operation: CredentialAccessEvent.Operation = .runtimeRead) -> CredentialAccessEvent {
        CredentialAccessEvent(timestamp: now.addingTimeInterval(-offset), credentialID: "synthetic", operation: operation,
                              result: result, callerHint: "Synthetic Agent", declaredPurpose: nil,
                              executableBasename: operation == .runtimeRead ? "deploy.sh" : nil, deviceName: device)
    }

    private func rows(_ records: [CredentialAccessEvent]) -> [AccessRecordPresentation.Row] {
        AccessRecordPresentation(records: records, credentialName: { _ in "Synthetic API" }, now: now)
            .sections.flatMap(\.rows)
    }

    func testRemoteAllowAndDenyNameTheDeviceInBothLanguages() {
        let expected: [String: [String?]] = [
            "en": ["Approved on “Synthetic iPhone”", "Denied on “Synthetic iPhone”", nil, nil],
            "zh-Hans": ["已在“Synthetic iPhone”上批准", "已在“Synthetic iPhone”上拒绝", nil, nil], // i18n-literal: Expected Simplified Chinese catalog value.
        ]
        for (language, details) in expected {
            AppLanguage.current = language
            let rows = rows([
                event(.allowed, device: "Synthetic iPhone"),
                event(.denied, device: "Synthetic iPhone", offset: 60),
                event(.allowed, device: nil, offset: 120),
                event(.denied, device: nil, offset: 180),
            ])
            XCTAssertEqual(rows.map(\.detail), details, language)
            // The sentence and the colored result read as they do for a local decision.
            XCTAssertEqual(rows[0].sentence, rows[2].sentence, language)
            XCTAssertEqual(rows[1].sentence, rows[3].sentence, language)
            XCTAssertEqual(rows.map(\.resultRole), [.accent, .warning, .accent, .warning], language)
            XCTAssertEqual(rows[0].resultTitle, rows[2].resultTitle, language)
            XCTAssertEqual(rows[1].resultTitle, rows[3].resultTitle, language)
        }
    }

    /// The Vault writes the name on each read a remote timed allowance covers
    /// (`DeviceApproverFlagTests`); every such record shows the same line.
    func testEveryNamedAllowShowsTheSameLine() {
        AppLanguage.current = "en"
        let rows = rows([
            event(.allowed, device: "Synthetic iPhone", offset: 0),
            event(.allowed, device: "Synthetic iPhone", offset: 300),
        ])
        XCTAssertEqual(rows.map(\.detail), Array(repeating: "Approved on “Synthetic iPhone”", count: 2))
    }

    func testOnlyAnAllowOrADenyNamesADevice() {
        AppLanguage.current = "en"
        let rows = rows([
            event(.expired, device: "Synthetic iPhone"),
            event(.failed, device: "Synthetic iPhone", offset: 60),
            event(.hiddenNameRejected, device: "Synthetic iPhone", offset: 120),
        ])
        XCTAssertEqual(rows.map(\.detail), [nil, nil, nil])
    }

    /// The record carries the name, not the device: the line shows the stored
    /// name whatever the device is called now.
    func testTheStoredNameIsShownCleaned() {
        AppLanguage.current = "en"
        XCTAssertEqual(AccessRecordPresentation.remoteDecision(event(.allowed, device: "Old Phone Name")),
                       "Approved on “Old Phone Name”")
        // An empty stored name still marks the decision as remote, as the panel does.
        XCTAssertEqual(AccessRecordPresentation.remoteDecision(event(.allowed, device: "")), "Approved on “”")
        XCTAssertEqual(AccessRecordPresentation.remoteDecision(event(.denied, device: " \n\t ")), "Denied on “”")
        // Control and bidirectional formatting characters never reach the screen.
        XCTAssertEqual(AccessRecordPresentation.remoteDecision(event(.denied, device: "\u{202E}Synthetic\nPhone\u{2066}")),
                       "Denied on “SyntheticPhone”")
        let long = String(repeating: "n", count: 200)
        let detail = AccessRecordPresentation.remoteDecision(event(.allowed, device: long))
        XCTAssertEqual(detail, "Approved on “\(String(repeating: "n", count: 64))”")
    }
}
