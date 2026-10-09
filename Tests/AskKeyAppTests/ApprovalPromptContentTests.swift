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
            // A wrapped value-only title keeps the name together with its "value of" wording.
            let valueTitle = content(.modify, valueOnly: true).title
            XCTAssertTrue(valueTitle.contains(language == "en" ? "f\u{2060}\u{00A0}\u{2060}“" : "」\u{2060}的\u{2060}值")) // i18n-literal: Chinese value suffix.
        }
    }

    func testReadCardShowsTheFullCommandWhatItReceivesAndTheUnverifiedPurpose() {
        let longCommand = "./deploy.sh " + (1...30).map { "--flag-\($0) value" }.joined(separator: " ")
        Fixtures.withLanguages { language in
            let read = content(.read, display: Fixtures.display(command: longCommand))
            XCTAssertEqual(read.command, longCommand, "the command is never shortened in the middle")
            XCTAssertEqual(read.purpose, "Deploy the staging site")
            XCTAssertEqual(plain(read.receivesHeading), language == "en"
                ? "If you allow, this command receives 1 item from “Staging API”"
                : "批准后这个命令会拿到「Staging API」里的 1 项") // i18n-literal: Assert the Simplified Chinese receives heading.
            XCTAssertEqual(read.receives.map(\.plainText), [language == "en"
                ? "→ Environment variable STAGING_API_TOKEN"
                : "→ 环境变量 STAGING_API_TOKEN"]) // i18n-literal: Assert the Simplified Chinese delivery row.
            XCTAssertEqual(read.receives.first?.segments.filter(\.code).map(\.text), ["STAGING_API_TOKEN"])
            XCTAssertEqual(read.detailRows.map(\.label), language == "en"
                ? ["Runs in", "Requested by"] : ["运行目录", "请求方"]) // i18n-literal: Assert Simplified Chinese detail labels.
            XCTAssertEqual(read.detailRows.map(\.value), ["~/web", language == "en"
                ? "Claude Code (name provided by the requester; Ask Key can't verify it)"
                : "Claude Code（名称由请求方提供，请旨无法核实）"]) // i18n-literal: Assert the Simplified Chinese requester row.
            XCTAssertEqual(read.detailRows.first?.monospaced, true)
            let headings = ["Command to run", "Stated purpose (not verified)", "Details"].map { appLocalized($0) }
            XCTAssertEqual(headings, language == "en"
                ? ["Command to run", "Stated purpose (not verified)", "Details"] : [
                "要运行的命令", "对方说的用途（未核实）", "详细信息", // i18n-literal: Assert Simplified Chinese read headings.
            ])
        }
    }

    func testReadDeliveryRowsCoverFilesMultiItemCredentialsAndNoDelivery() {
        Fixtures.withLanguages { language in
            let file = content(.read, display: Fixtures.display(environment: ["DEPLOY_HOST"], files: ["SSH_KEY_FILE"]))
            let bundle = content(.read, display: Fixtures.display(environment: nil, files: nil))
            let nothing = content(.read, display: Fixtures.display(environment: [], files: []))
            let headings = [file, bundle, nothing].map { plain($0.receivesHeading) }
            let rows = [file, bundle, nothing].map { $0.receives.map { plain($0.plainText) } }
            if language == "en" {
                XCTAssertEqual(headings, ["If you allow, this command receives 2 items from “Staging API”",
                    "If you allow, this command receives", "If you allow, this command receives"])
                XCTAssertEqual(rows, [
                    ["→ Environment variable DEPLOY_HOST", "→ Temporary file (path in SSH_KEY_FILE, removed within 5 minutes)"],
                    ["The items of “Staging API” that are set to be given to programs (names are shown after you approve)"],
                    ["Nothing from this credential is given to the command"],
                ])
            } else {
                XCTAssertEqual(headings, ["批准后这个命令会拿到「Staging API」里的 2 项", // i18n-literal: Assert the Simplified Chinese receives heading.
                    "批准后这个命令会拿到", "批准后这个命令会拿到"]) // i18n-literal: Assert the Simplified Chinese receives heading.
                XCTAssertEqual(rows, [
                    ["→ 环境变量 DEPLOY_HOST", "→ 临时文件（路径在 SSH_KEY_FILE，最多 5 分钟后删除）"], // i18n-literal: Assert Simplified Chinese delivery rows.
                    ["「Staging API」里设为交给程序的所有项（具体名称批准后才能看到）"], // i18n-literal: Assert the Simplified Chinese bundle row.
                    ["不交给这个命令任何值"], // i18n-literal: Assert the Simplified Chinese no-delivery row.
                ])
            }
            XCTAssertFalse(rows[0].joined().contains("Staging API"), "rows never repeat the credential name")
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
                    ["Move to Recycle Bin", "Deny"], ["Apply 4 Steps", "Deny"], ["Apply 1 Step", "Deny"],
                ])
                XCTAssertEqual(FrozenApprovalActions.timedScope(minutes: 30),
                    "For 30 minutes, any agent or command in your Mac account can read this credential without asking. Changing or deleting it still needs your approval.")
            } else {
                XCTAssertEqual(titles, [
                    ["允许本次", "30 分钟内都允许", "拒绝"], ["允许本次", "拒绝"], // i18n-literal: Assert Simplified Chinese read buttons.
                    ["新建凭证", "拒绝"], ["保存修改", "拒绝"], ["替换值", "拒绝"], // i18n-literal: Assert Simplified Chinese write buttons.
                    ["移到回收站", "拒绝"], ["执行这 4 步", "拒绝"], ["执行这 1 步", "拒绝"], // i18n-literal: Assert Simplified Chinese write buttons.
                ])
                XCTAssertEqual(FrozenApprovalActions.timedScope(minutes: 30),
                    "30 分钟内，你这个 Mac 账户下的任何 Agent 或命令读取这个凭证都不再询问；修改或删除它仍要你批准。") // i18n-literal: Assert the Simplified Chinese timed scope.
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
                ? ["Authenticate and Allow Once", "Authenticate and Allow for 30 Minutes", "Authenticate and Move to Recycle Bin"]
                : ["重新验证，允许本次", "重新验证，30 分钟内都允许", "重新验证，移到回收站"]) // i18n-literal: Assert Simplified Chinese retry buttons.
            XCTAssertEqual(content(.read).cancelledAuthenticationNote, language == "en"
                ? "You cancelled authentication. Nothing was given to the command, and the request is still pending."
                : "你取消了验证，命令没有拿到任何东西，请求仍在等待。") // i18n-literal: Assert the Simplified Chinese cancelled note.
        }
    }

    func testFooterAndOverflowCopyInBothLanguages() {
        Fixtures.withLanguages { language in
            let footer = appLocalizedFormat("Expires in %@ and nothing is handed over", "4:59") + " · "
                + appLocalized("Esc to hide; decide in Pending requests before it expires")
            let hints = [
                ApprovalOverflow.hint(unit: .steps, hiddenHeight: 120, hiddenSteps: 3, hiddenNames: [appLocalized("Details")]),
                ApprovalOverflow.hint(unit: .steps, hiddenHeight: 20, hiddenSteps: 1),
                ApprovalOverflow.hint(unit: .steps, hiddenHeight: 20, hiddenNames: [appLocalized("Details")]),
                ApprovalOverflow.hint(unit: .lines(height: 15), hiddenHeight: 46),
                ApprovalOverflow.hint(unit: .lines(height: 15), hiddenHeight: 10),
                ApprovalOverflow.hint(unit: .sections, hiddenHeight: 80,
                                      hiddenNames: [appLocalized("Group"), appLocalized("Details")]),
                ApprovalOverflow.hint(unit: .sections, hiddenHeight: 8),
                ApprovalOverflow.hint(unit: .steps, hiddenHeight: 0.5),
            ]
            if language == "en" {
                XCTAssertEqual(footer, "Expires in 4:59 and nothing is handed over · Esc to hide; decide in Pending requests before it expires")
                XCTAssertEqual(appLocalized("Pending requests"), "Pending requests", "the footer uses the sidebar's item name")
                XCTAssertEqual(hints, ["3 more steps — scroll to see them", "1 more step — scroll to see it", "Below: Details",
                    "3 more lines — scroll to see them", "1 more line — scroll to see it",
                    "Below: Group, Details", "More below — scroll to see it", nil])
            } else {
                XCTAssertEqual(footer, "4:59 后自动作废，不会交出任何东西 · Esc 先收起，过期前可在「待处理请求」里决定") // i18n-literal: Assert the Simplified Chinese footer.
                XCTAssertEqual(hints, ["还有 3 步，向下滚动查看", "还有 1 步，向下滚动查看", "下面还有：详细信息", // i18n-literal: Assert Simplified Chinese overflow hints.
                    "还有 3 行，向下滚动查看", "还有 1 行，向下滚动查看", // i18n-literal: Assert Simplified Chinese overflow hints.
                    "下面还有：分组、详细信息", "下面还有内容，向下滚动查看", nil]) // i18n-literal: Assert Simplified Chinese overflow hints.
            }
        }
    }
}
