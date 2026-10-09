import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

/// Every card is one sentence, one short line and its buttons, in English and
/// Simplified Chinese; everything else is in Details.
@MainActor
final class ApprovalPromptContentTests: AskKeyAppTestCase {
    private typealias Fixtures = ApprovalCardFixtures
    private typealias Card = ApprovalCardFixtures.Card

    private struct Expected {
        let title: String
        let subtitle: String?
        let buttons: [String]
    }

    private let english: [Card: Expected] = [
        .readDefault: .init(title: "“Claude Code” wants to use “Staging API”", subtitle: "to run ./deploy.sh --env staging",
                            buttons: ["Allow Once", "Allow for 30 Minutes", "Deny"]),
        .readWithoutTimed: .init(title: "“Claude Code” wants to use “Staging API”", subtitle: "to run ./deploy.sh --env staging",
                                 buttons: ["Allow Once", "Deny"]),
        .create: .init(title: "“Claude Code” wants to create the credential “Release Check”",
                       subtitle: "In the new group “Release Tools”", buttons: ["Create", "Deny"]),
        .createTwoItems: .init(title: "“Claude Code” wants to create the credential “Staging SSH”",
                               subtitle: "In the group “Staging”", buttons: ["Create", "Deny"]),
        .createUngrouped: .init(title: "“Claude Code” wants to create the credential “Deploy Host”", subtitle: nil,
                                buttons: ["Create", "Deny"]),
        .modifyValue: .init(title: "“Claude Code” wants to replace the value of “Release Check”",
                            subtitle: "The old value can't be recovered", buttons: ["Replace", "Deny"]),
        .modifySomeValues: .init(title: "“Claude Code” wants to replace TOKEN in “Release Check”",
                                 subtitle: "The old value can't be recovered", buttons: ["Replace", "Deny"]),
        .modifyMetadata: .init(title: "“Claude Code” wants to change “Release Check”",
                               subtitle: "Changes the instructions (some instruction text is deleted)", buttons: ["Change", "Deny"]),
        .modifyInstructionsAndGroup: .init(title: "“Claude Code” wants to change “Release Check”",
                                           subtitle: "Changes the instructions and the group", buttons: ["Change", "Deny"]),
        .modifyAdded: .init(title: "“Claude Code” wants to change “Release Check”", subtitle: "Adds 1 item",
                            buttons: ["Change", "Deny"]),
        .modifyRemoved: .init(title: "“Claude Code” wants to change “Release Check”",
                              subtitle: "Removes 1 item; the removed value can't be recovered", buttons: ["Change", "Deny"]),
        .modifyMixed: .init(title: "“Claude Code” wants to change “Release Check”",
                            subtitle: "Replaces 1 value, changes the group; the old value can't be recovered",
                            buttons: ["Change", "Deny"]),
        .delete: .init(title: "“Claude Code” wants to delete “Release Check”",
                       subtitle: "Moves to the Recycle Bin; restorable for 30 days", buttons: ["Delete", "Deny"]),
        .organize: .init(title: "“Claude Code” wants to organize your groups",
                         subtitle: "4 steps, affecting 2 hidden credentials", buttons: ["Apply", "Deny"]),
        .organizeExistingAndMerge: .init(title: "“Claude Code” wants to organize your groups",
                                         subtitle: "2 steps, one of which merges groups, affecting 1 hidden credential",
                                         buttons: ["Apply", "Deny"]),
        .organizeTwelveSteps: .init(title: "“Claude Code” wants to organize your groups",
                                    subtitle: "12 steps, affecting 3 hidden credentials", buttons: ["Apply", "Deny"]),
    ]

    // i18n-literal: Simplified Chinese card copy from the #177 table.
    private let chinese: [Card: Expected] = [
        .readDefault: .init(title: "“Claude Code”想使用“Staging API”", subtitle: "用于运行 ./deploy.sh --env staging", // i18n-literal: Chinese read card.
                            buttons: ["允许本次", "允许 30 分钟", "拒绝"]), // i18n-literal: Chinese read buttons.
        .readWithoutTimed: .init(title: "“Claude Code”想使用“Staging API”", subtitle: "用于运行 ./deploy.sh --env staging", // i18n-literal: Chinese read card.
                                 buttons: ["允许本次", "拒绝"]), // i18n-literal: Chinese read buttons.
        .create: .init(title: "“Claude Code”想新建凭证“Release Check”", subtitle: "放进新分组“Release Tools”", // i18n-literal: Chinese create card.
                       buttons: ["新建", "拒绝"]), // i18n-literal: Chinese create buttons.
        .createTwoItems: .init(title: "“Claude Code”想新建凭证“Staging SSH”", subtitle: "放进“Staging”", // i18n-literal: Chinese create card.
                               buttons: ["新建", "拒绝"]), // i18n-literal: Chinese create buttons.
        .createUngrouped: .init(title: "“Claude Code”想新建凭证“Deploy Host”", subtitle: nil, // i18n-literal: Chinese create card.
                                buttons: ["新建", "拒绝"]), // i18n-literal: Chinese create buttons.
        .modifyValue: .init(title: "“Claude Code”想替换“Release Check”的值", subtitle: "旧值将无法找回", // i18n-literal: Chinese value card.
                            buttons: ["替换", "拒绝"]), // i18n-literal: Chinese value buttons.
        .modifySomeValues: .init(title: "“Claude Code”想替换“Release Check”的 TOKEN", subtitle: "旧值将无法找回", // i18n-literal: Chinese value card.
                                 buttons: ["替换", "拒绝"]), // i18n-literal: Chinese value buttons.
        .modifyMetadata: .init(title: "“Claude Code”想修改“Release Check”", subtitle: "更改使用说明（删掉了部分说明）", // i18n-literal: Chinese change card.
                               buttons: ["修改", "拒绝"]), // i18n-literal: Chinese change buttons.
        .modifyInstructionsAndGroup: .init(title: "“Claude Code”想修改“Release Check”", subtitle: "更改使用说明和分组", // i18n-literal: Chinese change card.
                                           buttons: ["修改", "拒绝"]), // i18n-literal: Chinese change buttons.
        .modifyAdded: .init(title: "“Claude Code”想修改“Release Check”", subtitle: "新增 1 项", // i18n-literal: Chinese change card.
                            buttons: ["修改", "拒绝"]), // i18n-literal: Chinese change buttons.
        .modifyRemoved: .init(title: "“Claude Code”想修改“Release Check”", subtitle: "移除 1 项，移除的值将无法找回", // i18n-literal: Chinese change card.
                              buttons: ["修改", "拒绝"]), // i18n-literal: Chinese change buttons.
        .modifyMixed: .init(title: "“Claude Code”想修改“Release Check”", subtitle: "替换 1 项的值，更改分组，旧值将无法找回", // i18n-literal: Chinese change card.
                            buttons: ["修改", "拒绝"]), // i18n-literal: Chinese change buttons.
        .delete: .init(title: "“Claude Code”想删除“Release Check”", subtitle: "移到回收站，30 天内可恢复", // i18n-literal: Chinese delete card.
                       buttons: ["删除", "拒绝"]), // i18n-literal: Chinese delete buttons.
        .organize: .init(title: "“Claude Code”想整理分组", subtitle: "共 4 步，会动到 2 个隐藏的凭证", // i18n-literal: Chinese organize card.
                         buttons: ["执行", "拒绝"]), // i18n-literal: Chinese organize buttons.
        .organizeExistingAndMerge: .init(title: "“Claude Code”想整理分组", // i18n-literal: Chinese organize card.
                                         subtitle: "共 2 步，其中一步会合并分组，会动到 1 个隐藏的凭证", // i18n-literal: Chinese organize card.
                                         buttons: ["执行", "拒绝"]), // i18n-literal: Chinese organize buttons.
        .organizeTwelveSteps: .init(title: "“Claude Code”想整理分组", subtitle: "共 12 步，会动到 3 个隐藏的凭证", // i18n-literal: Chinese organize card.
                                    buttons: ["执行", "拒绝"]), // i18n-literal: Chinese organize buttons.
    ]

    func testEveryCardShowsItsTitleSubtitleAndButtonsInBothLanguages() {
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        Fixtures.withLanguages { language in
            for (card, expected) in language == "en" ? english : chinese {
                let copy = Fixtures.copy(card)
                XCTAssertEqual(copy.title, expected.title, "\(language) \(card.rawValue)")
                XCTAssertEqual(copy.subtitle, expected.subtitle, "\(language) \(card.rawValue)")
                XCTAssertEqual(copy.buttons, expected.buttons, "\(language) \(card.rawValue)")
            }
        }
    }

    func testIrreversibleActionsAreRedAndNeverTheDefault() {
        let destructive: Set<Card> = [.modifyValue, .modifySomeValues, .modifyRemoved, .modifyMixed, .organizeExistingAndMerge]
        for card in Card.allCases {
            let buttons = Fixtures.prompt(card).presentation.buttons
            XCTAssertEqual(buttons.first?.role, destructive.contains(card) ? .destructive : .primary, card.rawValue)
            XCTAssertEqual(buttons.first?.decision, .once)
            XCTAssertEqual(buttons.last?.role, .secondary, "Deny is never red")
            XCTAssertEqual(buttons.filter { $0.role == .primary }.count, destructive.contains(card) ? 0 : 1, card.rawValue)
        }
    }

    func testCancelledAuthenticationKeepsTheSameButtonsAndAddsOneGrayLine() {
        Fixtures.withLanguages { language in
            let read = Fixtures.prompt(.readDefault).presentation.buttons
            for decision in [BrokerApprovalDecision.timedAllow(duration: nil), .once] {
                let cancelled = FrozenAgentApprovalPrompt(request: Fixtures.request(.read, display: Fixtures.display()),
                    timedAllowanceEnabled: true, cancelledAuthenticationDecision: decision, finish: { _ in })
                XCTAssertEqual(cancelled.presentation.buttons, read, "\(language): same buttons in the same order")
                XCTAssertEqual(cancelled.presentation.buttons.first?.decision, .once, "the default never becomes the timed option")
                XCTAssertEqual(cancelled.presentation.buttons.first?.role, .primary)
            }
            var write = Fixtures.prompt(.modifyMixed)
            let buttons = write.presentation.buttons
            write.cancelledAuthenticationDecision = .once
            XCTAssertEqual(write.presentation.buttons, buttons)
            XCTAssertEqual(appLocalized("Authentication cancelled. Nothing was handed over."), language == "en"
                ? "Authentication cancelled. Nothing was handed over." : "已取消验证，未交出任何内容") // i18n-literal: Chinese cancelled note.
        }
    }

    func testReadDetailsHoldTheRequesterPurposeDeliveryAndTimedScope() {
        Fixtures.withLanguages { language in
            let read = ApprovalPromptContent(request: Fixtures.request(.read, display: Fixtures.display()), credentialName: "Staging API")
            XCTAssertTrue(read.commandFits(prefix: appLocalized("to run"), width: FrozenAgentApprovalPrompt.contentWidth))
            let rows = read.detailRows(commandFits: true)
            if language == "en" {
                XCTAssertEqual(rows.map(\.label), ["Command gets", "Runs in", "Requested by", "Stated purpose"])
                XCTAssertEqual(rows.map(\.value), ["Environment variable STAGING_API_TOKEN", "~/web",
                    "Claude Code (name provided by the requester; Ask Key can't verify it)",
                    "Deploy the staging site (not verified)"])
                XCTAssertEqual(FrozenApprovalActions.timedScope(minutes: 30),
                    "For 30 minutes, any agent or command in your Mac account can read this credential without asking. Changing or deleting it still needs your approval.")
            } else {
                XCTAssertEqual(rows.map(\.label), ["命令会拿到", "运行目录", "请求方", "对方说的用途"]) // i18n-literal: Chinese detail labels.
                XCTAssertEqual(rows.map(\.value), ["环境变量 STAGING_API_TOKEN", "~/web", // i18n-literal: Chinese detail values.
                    "Claude Code（名称由请求方提供，请旨无法核实）", "Deploy the staging site（未核实）"]) // i18n-literal: Chinese detail values.
                XCTAssertEqual(FrozenApprovalActions.timedScope(minutes: 30),
                    "30 分钟内，你这个 Mac 账户下的任何 Agent 或命令读取这个凭证都不再询问；修改或删除它仍要你批准。") // i18n-literal: Chinese timed scope.
            }
            XCTAssertEqual(rows.map(\.monospaced), [false, true, false, false])
        }
    }

    func testReadDetailsDescribeFilesBundlesAndLongCommands() {
        Fixtures.withLanguages { language in
            func receives(_ display: BrokerApprovalOperationRequest.Display) -> String {
                ApprovalPromptContent.receives(display)
            }
            let values = [
                receives(Fixtures.display(environment: ["DEPLOY_HOST"], files: ["SSH_KEY_FILE"])),
                receives(Fixtures.display(environment: nil, files: nil)),
                receives(Fixtures.display(environment: [], files: [])),
            ]
            XCTAssertEqual(values, language == "en" ? [
                "Environment variable DEPLOY_HOST\nTemporary file (path in SSH_KEY_FILE, removed within 5 minutes)",
                "The items set to be given to programs (names are shown after you approve)",
                "Nothing from this credential is given to the command",
            ] : [
                "环境变量 DEPLOY_HOST\n临时文件（路径在 SSH_KEY_FILE，最多 5 分钟后删除）", // i18n-literal: Chinese delivery rows.
                "设为交给程序的所有项（具体名称批准后才能看到）", // i18n-literal: Chinese bundle row.
                "不交给这个命令任何值", // i18n-literal: Chinese no-delivery row.
            ])
            let command = "./deploy.sh " + (1...30).map { "--flag-\($0) value" }.joined(separator: " ")
            let long = ApprovalPromptContent(request: Fixtures.request(.read, display: Fixtures.display(command: command)),
                                             credentialName: "Staging API")
            XCTAssertFalse(long.commandFits(prefix: appLocalized("to run"), width: FrozenAgentApprovalPrompt.contentWidth))
            let rows = long.detailRows(commandFits: false)
            XCTAssertEqual(rows.first?.label, language == "en" ? "Command" : "命令") // i18n-literal: Chinese command label.
            XCTAssertEqual(rows.first?.value, command, "Details show the whole command")
            XCTAssertTrue(rows.first?.monospaced == true)
            XCTAssertNil(ApprovalPromptContent(request: Fixtures.request(.create, display: Fixtures.display()),
                                               credentialName: "Staging API").commandSummary, "write cards never show a run target")
        }
    }

    func testNamesAreQuotedInBothLanguagesAndNeverShortened() {
        let name = String(repeating: "Long Credential Name ", count: 12)
        Fixtures.withLanguages { language in
            XCTAssertEqual(ApprovalCopy.quoted("Staging API"), "“Staging API”")
            XCTAssertEqual(ApprovalCopy.group(nil), language == "en" ? "“Ungrouped”" : "“未分组”") // i18n-literal: Chinese ungrouped name.
            let title = ApprovalPromptContent(request: Fixtures.request(.read, name: name), credentialName: name).title
            XCTAssertTrue(title.contains("“" + name + "”"))
        }
    }

    func testFooterInBothLanguages() {
        Fixtures.withLanguages { language in
            let footer = appLocalizedFormat("Expires in %@", "4:11") + " · " + appLocalized("Esc to decide later")
            XCTAssertEqual(footer, language == "en" ? "Expires in 4:11 · Esc to decide later" : "4:11 后失效 · Esc 稍后处理") // i18n-literal: Chinese footer.
            XCTAssertEqual(appLocalized("Details"), language == "en" ? "Details" : "详细信息") // i18n-literal: Chinese Details link.
        }
    }

    func testPendingListSaysTheCardTitle() {
        Fixtures.withLanguages { language in
            let sentences = [
                Fixtures.request(.read, display: Fixtures.display()), Fixtures.request(.read),
                Fixtures.request(.create), Fixtures.request(.modify), Fixtures.request(.delete), Fixtures.request(.organize),
            ].map { request in
                PendingRequestPresentation(approval: BrokerPendingApproval(requestID: "request", capability: "capability",
                    request: request, trustedCredentialName: "Staging API")).sentence.plainText
            }
            XCTAssertEqual(sentences, language == "en" ? [
                "“Claude Code” wants to use “Staging API” to run ./deploy.sh --env staging",
                "“Claude Code” wants to use “Staging API”",
                "“Claude Code” wants to create the credential “Staging API”",
                "“Claude Code” wants to change “Staging API”",
                "“Claude Code” wants to delete “Staging API”",
                "“Claude Code” wants to organize your groups",
            ] : [
                "“Claude Code”想使用“Staging API”运行 ./deploy.sh --env staging", // i18n-literal: Chinese pending sentence.
                "“Claude Code”想使用“Staging API”", // i18n-literal: Chinese pending sentence.
                "“Claude Code”想新建凭证“Staging API”", // i18n-literal: Chinese pending sentence.
                "“Claude Code”想修改“Staging API”", // i18n-literal: Chinese pending sentence.
                "“Claude Code”想删除“Staging API”", // i18n-literal: Chinese pending sentence.
                "“Claude Code”想整理分组", // i18n-literal: Chinese pending sentence.
            ])
        }
    }
}
