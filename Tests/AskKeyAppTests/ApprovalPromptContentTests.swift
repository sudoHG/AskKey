import AppKit
import SwiftUI
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

final class ApprovalPromptContentTests: AskKeyAppTestCase {
    private func request(
        _ operation: BrokerApprovalOperation = .read,
        purpose: String? = "Deploy staging",
        display: BrokerApprovalOperationRequest.Display? = nil
    ) -> BrokerApprovalOperationRequest {
        BrokerApprovalOperationRequest(
            operationID: "synthetic-operation",
            credentialID: "synthetic-credential",
            targetID: "synthetic-credential",
            operation: operation,
            payloadDigest: "synthetic-digest",
            credentialName: "demo-api",
            callerName: "Demo Agent",
            callerPurpose: purpose,
            display: display
        )
    }

    private func display(
        command: String = "./deploy.sh --env staging",
        environment: [String]? = ["API_KEY"],
        files: [String]? = []
    ) -> BrokerApprovalOperationRequest.Display {
        .init(
            commandLine: command,
            workingDirectory: "~/work/shop-api",
            executableBasename: "deploy.sh",
            environmentVariables: environment,
            temporaryFileVariables: files
        )
    }

    private func withLanguage(_ language: String, _ body: () throws -> Void) rethrows {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        AppLanguage.current = language
        try body()
    }

    func testReadPromptShowsTargetAndDetailsWithUnverifiedPurpose() {
        withLanguage("en") {
            let content = ApprovalPromptContent(
                request: request(display: display(files: ["CERT_FILE"])),
                credentialName: "demo-api"
            )
            XCTAssertEqual(content.title, "“Demo Agent” wants to use “demo-api”")
            XCTAssertEqual(content.commandSummary, "./deploy.sh --env staging")
            XCTAssertEqual(content.rows.map(\.label), ["Delivers", "Location", "Stated purpose"])
            XCTAssertEqual(content.rows.map(\.value), [
                "API_KEY, CERT_FILE (file)",
                "~/work/shop-api",
                "Deploy staging (self-declared, unverified)",
            ])
        }
        withLanguage("zh-Hans") {
            let content = ApprovalPromptContent(
                request: request(display: display(environment: ["API_KEY", "API_ENDPOINT"])),
                credentialName: "demo-api"
            )
            XCTAssertEqual(content.title, "“Demo Agent”想使用“demo-api”") // i18n-literal: Assert the Simplified Chinese approval copy.
            XCTAssertEqual(content.rows.map(\.label), ["交付", "位置", "说明"]) // i18n-literal: Assert the Simplified Chinese approval copy.
            XCTAssertEqual(content.rows.map(\.value), [
                "API_KEY、API_ENDPOINT", // i18n-literal: Assert the Simplified Chinese approval copy.
                "~/work/shop-api",
                "Deploy staging（自报，未核实）", // i18n-literal: Assert the Simplified Chinese approval copy.
            ])
        }
    }

    func testBundlesShowNoDeliveredNames() {
        withLanguage("en") {
            let content = ApprovalPromptContent(
                request: request(display: display(environment: nil, files: nil)),
                credentialName: "demo-api"
            )
            XCTAssertFalse(content.rows.map(\.label).contains("Delivers"))
            XCTAssertNil(ApprovalPromptContent.deliveredNames(display(environment: [], files: [])))
        }
    }

    func testFullCommandMovesIntoDetailsOnlyWhenTheLineCannotShowIt() {
        withLanguage("en") {
            let short = ApprovalPromptContent(request: request(display: display()), credentialName: "demo-api")
            XCTAssertTrue(short.commandFits(prefix: "to run", width: 268))
            XCTAssertEqual(short.detailRows(commandFits: true), short.rows)

            let longCommand = "./deploy.sh " + String(repeating: "--flag value ", count: 20)
            let long = ApprovalPromptContent(
                request: request(display: display(command: longCommand)),
                credentialName: "demo-api"
            )
            XCTAssertNotEqual(long.commandSummary, longCommand)
            XCTAssertFalse(long.commandFits(prefix: "to run", width: 268))
            let rows = long.detailRows(commandFits: false)
            XCTAssertEqual(rows.first?.label, "Command")
            XCTAssertEqual(rows.first?.value, longCommand)
            XCTAssertEqual(rows.first?.monospaced, true)
        }
    }

    func testCancelledAuthenticationCopyFollowsTheOperation() {
        withLanguage("zh-Hans") {
            let read = ApprovalPromptContent(request: request(), credentialName: "demo-api")
            XCTAssertEqual(read.cancelledAuthenticationNote, "你取消了验证，凭证没有交付，请求仍在等待。") // i18n-literal: Assert the Simplified Chinese approval copy.
            XCTAssertEqual(read.retryTitle, "重新验证并允许") // i18n-literal: Assert the Simplified Chinese approval copy.
        }
        withLanguage("en") {
            let modify = ApprovalPromptContent(request: request(.modify), credentialName: "demo-api")
            XCTAssertEqual(modify.title, "“Demo Agent” wants to modify “demo-api”")
            XCTAssertEqual(
                modify.cancelledAuthenticationNote,
                "You cancelled authentication. Nothing was changed, and the request is still pending."
            )
            XCTAssertEqual(modify.retryTitle, "Authenticate and approve")
        }
    }

    func testWriteApprovalsKeepTheirContentWithoutARunTarget() {
        withLanguage("en") {
            let content = ApprovalPromptContent(
                request: request(.delete, display: display()),
                credentialName: "demo-api"
            )
            XCTAssertEqual(content.title, "“Demo Agent” wants to delete “demo-api”")
            XCTAssertNil(content.commandSummary)
            XCTAssertEqual(content.rows.map(\.label), ["Stated purpose", "Destination"])
        }
    }

    @MainActor
    func testPromptStatesRenderAtTheAlertWidth() throws {
        _ = NSApplication.shared
        let states: [FrozenAgentApprovalPrompt] = [
            .init(request: request(display: display()), timedAllowanceEnabled: true, finish: { _ in }),
            .init(request: request(display: display()), timedAllowanceEnabled: true,
                  detailsExpanded: true, finish: { _ in }),
            .init(request: request(display: display()), timedAllowanceEnabled: true,
                  cancelledAuthenticationDecision: .once, finish: { _ in }),
        ]
        var heights: [CGFloat] = []
        for state in states {
            let hosting = NSHostingView(rootView: state)
            hosting.appearance = NSAppearance(named: .aqua)
            let size = hosting.fittingSize
            XCTAssertEqual(size.width, FrozenAgentApprovalPrompt.width)
            heights.append(size.height)
        }
        XCTAssertGreaterThan(heights[1], heights[0], "expanding Details must grow the prompt")
        XCTAssertLessThan(heights[2], heights[0] + 40, "the cancelled state drops the timed action")
    }
}
