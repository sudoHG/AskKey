import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

/// Titles, read-card sections and buttons in English and Simplified Chinese.
@MainActor
final class ApprovalPromptContentTests: AskKeyAppTestCase {
    private typealias Fixtures = ApprovalCardFixtures

    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func content(_ operation: BrokerApprovalOperation, display: BrokerApprovalOperationRequest.Display? = nil,
                         valueOnly: Bool = false, steps: Int? = nil) -> ApprovalPromptContent {
        ApprovalPromptContent(request: Fixtures.request(operation, display: display), credentialName: "Staging API",
                              valueOnlyChange: valueOnly, organizationSteps: steps)
    }

    func testTitlesNameTheObjectInBothLanguages() {
        Fixtures.withLanguages { language in
            let titles = [
                content(.read), content(.create), content(.modify, valueOnly: true), content(.modify),
                content(.delete), content(.organize, steps: 4), content(.organize, steps: 1), content(.organize),
            ].map { plain($0.title) }
            if language == "en" {
                XCTAssertEqual(titles, [
                    "Claude Code wants to use the credential “Staging API”",
                    "Claude Code wants to create the credential “Staging API”",
                    "Claude Code wants to replace the value of “Staging API”",
                    "Claude Code wants to change the credential “Staging API”",
                    "Claude Code wants to delete the credential “Staging API”",
                    "Claude Code wants to reorganize your groups (4 steps)",
                    "Claude Code wants to reorganize your groups (1 step)",
                    "Claude Code wants to reorganize your groups",
                ])
            } else {
                XCTAssertEqual(titles, [
                    "Claude Code 想使用凭证「Staging API」", // i18n-literal: Assert the Simplified Chinese approval title.
                    "Claude Code 想新建凭证「Staging API」", // i18n-literal: Assert the Simplified Chinese approval title.
                    "Claude Code 想替换凭证「Staging API」的值", // i18n-literal: Assert the Simplified Chinese approval title.
                    "Claude Code 想修改凭证「Staging API」", // i18n-literal: Assert the Simplified Chinese approval title.
                    "Claude Code 想删除凭证「Staging API」", // i18n-literal: Assert the Simplified Chinese approval title.
                    "Claude Code 想调整分组（共 4 步）", // i18n-literal: Assert the Simplified Chinese approval title.
                    "Claude Code 想调整分组（共 1 步）", // i18n-literal: Assert the Simplified Chinese approval title.
                    "Claude Code 想调整分组", // i18n-literal: Assert the Simplified Chinese approval title.
                ])
            }
        }
    }

    func testNamesKeepTheirQuotesAndWrapAsAWhole() {
        Fixtures.withLanguages { language in
            let quoted = ApprovalCopy.quoted("Staging API")
            XCTAssertEqual(plain(quoted), language == "en" ? "“Staging API”" : "「Staging API」") // i18n-literal: Chinese corner brackets.
            XCTAssertFalse(quoted.contains(" "), "spaces inside a name never break")
            XCTAssertEqual(quoted.filter { $0 == "\u{2060}" }.count, "Staging API".count + 1)
            XCTAssertEqual(plain(ApprovalCopy.group(nil)), language == "en" ? "“Ungrouped”" : "「未分组」") // i18n-literal: Chinese ungrouped name.
        }
    }

    func testReadCardShowsTheFullCommandWhatItReceivesAndTheUnverifiedPurpose() {
        let longCommand = "./deploy.sh " + (1...30).map { "--flag-\($0) value" }.joined(separator: " ")
        Fixtures.withLanguages { language in
            let read = content(.read, display: Fixtures.display(command: longCommand))
            XCTAssertEqual(read.command, longCommand, "the command is never shortened in the middle")
            XCTAssertEqual(read.purpose, "Deploy the staging site")
            XCTAssertEqual(read.receives.map { plain($0.plainText) }, [language == "en"
                ? "“Staging API” · as environment variable STAGING_API_TOKEN"
                : "「Staging API」· 作为环境变量 STAGING_API_TOKEN"]) // i18n-literal: Assert the Simplified Chinese delivery row.
            XCTAssertEqual(read.receives.first?.segments.filter(\.code).map(\.text), ["STAGING_API_TOKEN"])
            XCTAssertEqual(read.detailRows.map(\.label), language == "en"
                ? ["Runs in", "Requested by"] : ["运行目录", "请求方"]) // i18n-literal: Assert Simplified Chinese detail labels.
            XCTAssertEqual(read.detailRows.map(\.value), ["~/web", language == "en"
                ? "Claude Code (name provided by the requester; Ask Key can't verify it)"
                : "Claude Code（名称由请求方提供，请旨无法核实）"]) // i18n-literal: Assert the Simplified Chinese requester row.
            XCTAssertEqual(read.detailRows.first?.monospaced, true)
            let headings = ["Command to run", "If you allow, this command receives", "Stated purpose (not verified)", "Details"]
                .map { appLocalized($0) }
            XCTAssertEqual(headings, language == "en"
                ? ["Command to run", "If you allow, this command receives", "Stated purpose (not verified)", "Details"] : [
                "要运行的命令", "批准后这个命令会拿到", "对方说的用途（未核实）", "详细信息", // i18n-literal: Assert Simplified Chinese read headings.
            ])
        }
    }

    func testReadDeliveryRowsCoverFilesMultiItemCredentialsAndNoDelivery() {
        Fixtures.withLanguages { language in
            let file = content(.read, display: Fixtures.display(environment: [], files: ["STAGING_CERT_FILE"]))
            let bundle = content(.read, display: Fixtures.display(environment: nil, files: nil))
            let nothing = content(.read, display: Fixtures.display(environment: [], files: []))
            let rows = [file, bundle, nothing].map { $0.receives.map { plain($0.plainText) } }
            if language == "en" {
                XCTAssertEqual(rows, [
                    ["“Staging API” · as a temporary file (path in STAGING_CERT_FILE, removed within 5 minutes)"],
                    ["The items of “Staging API” that are set to be given to programs (names are shown after you approve)"],
                    ["Nothing from this credential is given to the command"],
                ])
            } else {
                XCTAssertEqual(rows, [
                    ["「Staging API」· 作为临时文件（路径在 STAGING_CERT_FILE，最多 5 分钟后删除）"], // i18n-literal: Assert the Simplified Chinese file row.
                    ["「Staging API」里设为交给程序的所有项（具体名称批准后才能看到）"], // i18n-literal: Assert the Simplified Chinese bundle row.
                    ["不交给这个命令任何值"], // i18n-literal: Assert the Simplified Chinese no-delivery row.
                ])
            }
            XCTAssertTrue(content(.delete, display: Fixtures.display()).receives.isEmpty)
            XCTAssertNil(content(.create, display: Fixtures.display()).command, "write cards never show a run target")
        }
    }

    func testButtonsStateTheirConsequenceInBothLanguages() {
        Fixtures.withLanguages { language in
            let titles = [
                FrozenApprovalActions.titles(operation: .read, timedAllowanceEnabled: true),
                FrozenApprovalActions.titles(operation: .read, timedAllowanceEnabled: false),
                FrozenApprovalActions.titles(operation: .create, timedAllowanceEnabled: true),
                FrozenApprovalActions.titles(operation: .modify, timedAllowanceEnabled: true),
                FrozenApprovalActions.titles(operation: .modify, timedAllowanceEnabled: true, valueOnlyChange: true),
                FrozenApprovalActions.titles(operation: .delete, timedAllowanceEnabled: true),
                FrozenApprovalActions.titles(operation: .organize, timedAllowanceEnabled: true, steps: 4),
                FrozenApprovalActions.titles(operation: .organize, timedAllowanceEnabled: true, steps: 1),
            ]
            if language == "en" {
                XCTAssertEqual(titles, [
                    ["Allow Once", "Allow for 30 Minutes", "Deny"], ["Allow Once", "Deny"],
                    ["Create Credential", "Deny"], ["Save Changes", "Deny"], ["Replace Value", "Deny"],
                    ["Move to Trash", "Deny"], ["Apply 4 Steps", "Deny"], ["Apply 1 Step", "Deny"],
                ])
                XCTAssertEqual(FrozenApprovalActions.timedScope(minutes: 30),
                    "For 30 minutes, any agent or command run by this macOS user can read this credential without asking. Changes are never included.")
            } else {
                XCTAssertEqual(titles, [
                    ["允许本次", "30 分钟内都允许", "拒绝"], ["允许本次", "拒绝"], // i18n-literal: Assert Simplified Chinese read buttons.
                    ["新建凭证", "拒绝"], ["保存修改", "拒绝"], ["替换值", "拒绝"], // i18n-literal: Assert Simplified Chinese write buttons.
                    ["移到回收站", "拒绝"], ["执行这 4 步", "拒绝"], ["执行这 1 步", "拒绝"], // i18n-literal: Assert Simplified Chinese write buttons.
                ])
                XCTAssertEqual(FrozenApprovalActions.timedScope(minutes: 30),
                    "30 分钟内，这个 macOS 用户下的任何 Agent 或命令读取这个凭证都不再询问；不包括修改。") // i18n-literal: Assert the Simplified Chinese timed scope.
            }
            XCTAssertEqual(FrozenApprovalActions.primary(operation: .delete).role, .destructive)
            XCTAssertEqual(FrozenApprovalActions.primary(operation: .organize, steps: 2, destructive: true).role, .destructive)
            XCTAssertEqual(FrozenApprovalActions.primary(operation: .organize, steps: 2).role, .primary)
            XCTAssertEqual(FrozenApprovalActions.primary(operation: .create).role, .primary)
        }
    }

    func testCancelledAuthenticationRetriesTheOriginalChoice() {
        Fixtures.withLanguages { language in
            let read = FrozenApprovalActions.primary(operation: .read)
            let trash = FrozenApprovalActions.primary(operation: .delete)
            let retries = [
                FrozenApprovalActions.retry(.once, primary: read, minutes: 30),
                FrozenApprovalActions.retry(.timedAllow(duration: nil), primary: read, minutes: 30),
                FrozenApprovalActions.retry(.once, primary: trash, minutes: 30),
            ]
            XCTAssertEqual(retries, language == "en"
                ? ["Authenticate and Allow Once", "Authenticate and Allow for 30 Minutes", "Authenticate and Move to Trash"]
                : ["重新验证，允许本次", "重新验证，30 分钟内都允许", "重新验证，移到回收站"]) // i18n-literal: Assert Simplified Chinese retry buttons.
            XCTAssertEqual(content(.read).cancelledAuthenticationNote, language == "en"
                ? "You cancelled authentication. The credential was not delivered, and the request is still pending."
                : "你取消了验证，凭证没有交付，请求仍在等待。") // i18n-literal: Assert the Simplified Chinese cancelled note.
        }
    }

    func testFooterAndOverflowCopyInBothLanguages() {
        Fixtures.withLanguages { language in
            let footer = appLocalizedFormat("Expires in %@", "4:59") + " · " + appLocalized("Esc to decide later in Pending requests")
            let hints = [
                ApprovalOverflow.hint(unit: .steps, hiddenHeight: 120, hiddenMarkers: 3),
                ApprovalOverflow.hint(unit: .steps, hiddenHeight: 20, hiddenMarkers: 1),
                ApprovalOverflow.hint(unit: .lines(height: 15), hiddenHeight: 46, hiddenMarkers: 0),
                ApprovalOverflow.hint(unit: .lines(height: 15), hiddenHeight: 10, hiddenMarkers: 0),
                ApprovalOverflow.hint(unit: .sections, hiddenHeight: 80, hiddenMarkers: 2),
                ApprovalOverflow.hint(unit: .sections, hiddenHeight: 8, hiddenMarkers: 0),
                ApprovalOverflow.hint(unit: .steps, hiddenHeight: 0.5, hiddenMarkers: 0),
            ]
            if language == "en" {
                XCTAssertEqual(footer, "Expires in 4:59 · Esc to decide later in Pending requests")
                XCTAssertEqual(hints, ["3 more steps — scroll to see them", "1 more step — scroll to see it",
                    "3 more lines — scroll to see them", "1 more line — scroll to see it",
                    "2 more sections below — scroll to see them", "More below — scroll to see it", nil])
            } else {
                XCTAssertEqual(footer, "4:59 后自动失效 · Esc 先收起，稍后在「待处理请求」里决定") // i18n-literal: Assert the Simplified Chinese footer.
                XCTAssertEqual(hints, ["还有 3 步，向下滚动查看", "还有 1 步，向下滚动查看", // i18n-literal: Assert Simplified Chinese overflow hints.
                    "还有 3 行，向下滚动查看", "还有 1 行，向下滚动查看", // i18n-literal: Assert Simplified Chinese overflow hints.
                    "下面还有 2 部分，向下滚动查看", "下面还有内容，向下滚动查看", nil]) // i18n-literal: Assert Simplified Chinese overflow hints.
            }
        }
    }
}
