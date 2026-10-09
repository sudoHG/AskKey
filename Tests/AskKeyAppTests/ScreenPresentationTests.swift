import XCTest
import AskKeyBroker
import AskKeyVault
@testable import AskKeyAppKit

/// v0.2 screen presentations: pending requests as sentences, access records
/// grouped by day with colored results.
@MainActor
final class ScreenPresentationTests: WorkspaceVisualContractTestSupport {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    func testEmphasizedSentenceFollowsPositionalArgumentsInAnyWordOrder() {
        let sentence = EmphasizedSentence(format: "%2$@ by %1$@ (100%%)", arguments: ["Codex", "demo-api"])
        XCTAssertEqual(sentence.plainText, "demo-api by Codex (100%)")
        XCTAssertEqual(sentence.runs.filter(\.isArgument).map(\.text), ["demo-api", "Codex"])
        let sequential = EmphasizedSentence(format: "%@ browsed", arguments: ["Cursor"])
        XCTAssertEqual(sequential.runs, [.init(text: "Cursor", argument: 0), .init(text: " browsed", argument: nil)])
    }

    func testPendingRequestReadsAsOneSentenceWithExpiry() {
        let approval = BrokerPendingApproval(
            requestID: "request-1",
            capability: "capability-1",
            request: .init(
                operationID: "op-1", credentialID: "demo", targetID: "demo",
                operation: .read, payloadDigest: "redacted", credentialName: "demo-api",
                callerName: "Demo Agent", callerPurpose: "unverified purpose"
            ),
            trustedCredentialName: "demo-api"
        )
        let presentation = PendingRequestPresentation(approval: approval)
        XCTAssertEqual(unjoined(presentation.sentence.plainText), "Demo Agent 想使用凭证「demo-api」") // i18n-literal: Expected Simplified Chinese catalog value.
        XCTAssertFalse(presentation.sentence.plainText.contains("unverified purpose"))
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            PendingRequestPresentation.expiry(deadline: now.addingTimeInterval(214), now: now),
            "3:34 后自动失效" // i18n-literal: Expected Simplified Chinese catalog value.
        )
        AppLanguage.current = "en"
        defer { AppLanguage.current = "zh-Hans" }
        XCTAssertEqual(
            unjoined(PendingRequestPresentation(approval: approval).sentence.plainText),
            "Demo Agent wants to use the credential “demo-api”"
        )
    }

    func testPendingRequestNamesTheBoundCommandWhenTheAppDerivedIt() {
        let approval = BrokerPendingApproval(
            requestID: "request-2",
            capability: "capability-2",
            request: .init(
                operationID: "op-2", credentialID: "demo", targetID: "demo",
                operation: .read, payloadDigest: "redacted", credentialName: "demo-api",
                callerName: "Demo Agent",
                display: .init(
                    commandLine: "./deploy.sh --env staging",
                    workingDirectory: "~/project",
                    executableBasename: "deploy.sh",
                    environmentVariables: nil,
                    temporaryFileVariables: nil
                )
            ),
            trustedCredentialName: "demo-api"
        )
        let sentence = PendingRequestPresentation(approval: approval).sentence
        XCTAssertEqual(unjoined(sentence.plainText), "Demo Agent 想使用凭证「demo-api」运行 ./deploy.sh --env staging") // i18n-literal: Expected Simplified Chinese catalog value.
        XCTAssertEqual(sentence.runs.last, .init(text: "./deploy.sh --env staging", argument: 2))
    }

    /// Names are joined with invisible word joiners so they wrap as a whole.
    private func unjoined(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func testAccessRecordsGroupByDayNewestFirstWithColoredResults() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let today = calendar.startOfDay(for: now)
        let records: [CredentialAccessEvent] = [
            .init(timestamp: today.addingTimeInterval(-3 * 3600), credentialID: "ssh", operation: .create,
                  result: .allowed, callerHint: "Codex", declaredPurpose: nil),
            .init(timestamp: today.addingTimeInterval(17 * 3600 + 52 * 60), credentialID: "api", operation: .runtimeRead,
                  result: .allowed, callerHint: "Claude Code", declaredPurpose: nil),
            .init(timestamp: today.addingTimeInterval(18 * 3600 + 18 * 60), credentialID: "api", operation: .runtimeRead,
                  result: .denied, callerHint: "Demo Agent", declaredPurpose: nil, executableBasename: "/tmp/deploy.sh"),
            .init(timestamp: today.addingTimeInterval(-3 * 86_400), credentialID: nil, operation: .catalog,
                  result: .failed, callerHint: nil, declaredPurpose: nil),
        ]
        let names = ["api": "demo-api", "ssh": "staging-ssh"]
        let presentation = AccessRecordPresentation(
            records: records,
            credentialName: { $0.flatMap { names[$0] } ?? "?" },
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "zh-Hans")
        )
        XCTAssertEqual(presentation.sections.map(\.title).prefix(2), ["今天", "昨天"]) // i18n-literal: Expected Simplified Chinese catalog value.
        XCTAssertEqual(presentation.sections.count, 3)
        let todayRows = presentation.sections[0].rows
        XCTAssertEqual(todayRows.map(\.time), ["18:18", "17:52"])
        XCTAssertEqual(todayRows.map(\.sentence.plainText), [
            "Demo Agent 请求用 demo-api 运行 deploy.sh", // i18n-literal: Expected Simplified Chinese catalog value.
            "Claude Code 使用了 demo-api", // i18n-literal: Expected Simplified Chinese catalog value.
        ])
        XCTAssertEqual(todayRows.map(\.resultTitle), ["已拒绝", "已允许"]) // i18n-literal: Expected Simplified Chinese catalog value.
        XCTAssertEqual(todayRows.map(\.resultRole), [.warning, .accent])
        let yesterday = presentation.sections[1].rows
        XCTAssertEqual(yesterday.map(\.sentence.plainText), ["Codex 新建凭证 staging-ssh"]) // i18n-literal: Expected Simplified Chinese catalog value.
        XCTAssertEqual(yesterday.map(\.resultTitle), ["已批准"]) // i18n-literal: Expected Simplified Chinese catalog value.
        let older = presentation.sections[2].rows
        XCTAssertEqual(older.map(\.sentence.plainText), ["本地调用方 查看了凭证列表"]) // i18n-literal: Expected Simplified Chinese catalog value.
        XCTAssertEqual(older.map(\.resultRole), [.warning])
    }

    func testTimedAllowOffIsAPickerChoiceOutsideTheMinuteChoices() {
        XCTAssertFalse(FrozenTimedAllowanceSettingsPresentation.choices.contains(
            FrozenTimedAllowanceSettingsPresentation.offTag
        ))
        XCTAssertFalse(FrozenTimedAllowanceSettingsPresentation.menuChoices(current: 0).contains(
            FrozenTimedAllowanceSettingsPresentation.offTag
        ))
    }
}
