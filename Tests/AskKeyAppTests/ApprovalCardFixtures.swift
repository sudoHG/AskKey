import AppKit
import SwiftUI
import AskKeyBroker
@testable import AskKeyAppKit

/// Synthetic approval cards covering every card type. Values are never real.
@MainActor
enum ApprovalCardFixtures {
    enum Card: String, CaseIterable {
        case readDefault, readDetails, readFile, readCancelled, readWithoutTimed, readLongCommand, readBundle
        case create, createOneItem, createTwoItems, createUngrouped
        case modifyMetadata, modifyInstructionsAndGroup, modifyValue, modifySomeValues, modifyAdded, modifyRemoved, modifyMixed
        case delete, organize, organizeExistingAndMerge, organizeTwelveSteps
    }

    static func request(_ operation: BrokerApprovalOperation, name: String? = "Staging API",
                        purpose: String? = "Deploy the staging site",
                        display: BrokerApprovalOperationRequest.Display? = nil) -> BrokerApprovalOperationRequest {
        BrokerApprovalOperationRequest(
            operationID: "synthetic-\(operation.rawValue)",
            credentialID: operation == .organize ? "" : "synthetic-credential",
            targetID: operation == .organize ? "credential-library" : "synthetic-credential",
            operation: operation,
            payloadDigest: String(repeating: "a", count: 64),
            credentialName: operation == .organize ? nil : name,
            callerName: "Claude Code",
            callerPurpose: purpose,
            display: display,
            organizationCredentialIDs: operation == .organize ? [] : nil
        )
    }

    static func display(command: String = "./deploy.sh --env staging", environment: [String]? = ["STAGING_API_TOKEN"],
                        files: [String]? = []) -> BrokerApprovalOperationRequest.Display {
        .init(commandLine: command, workingDirectory: "~/web", executableBasename: "deploy.sh",
              environmentVariables: environment, temporaryFileVariables: files)
    }

    /// The digest stands in for the vault-keyed value digest; equal digests mean an equal value.
    static func component(_ name: String, bytes: Int, _ delivery: BrokerComponentDelivery,
                          kind: BrokerCatalogPayloadKind = .text, value: String? = nil) -> BrokerCredentialComponentSummary {
        .init(name: name, payloadKind: kind, byteCount: bytes, delivery: delivery, masked: true,
              valueDigest: "digest-" + (value ?? name))
    }

    static let token = component("TOKEN", bytes: 28, .environmentVariable("RELEASE_CHECK_TOKEN"))
    static let certificate = component("CERT", bytes: 1_234, .temporaryFile("RELEASE_CERT_FILE"), kind: .file)
    static let recovery = component("RECOVERY_CODE", bytes: 16, .none)
    static let user = component("USER", bytes: 12, .environmentVariable("RELEASE_USER"))

    static let createSummary = BrokerCredentialWriteSummary(credentialName: "Release Check", operation: .create,
        before: [], after: [token, certificate, recovery], beforeDigest: nil, afterDigest: "after",
        beforeUsageInstructions: nil, afterUsageInstructions: "Use only for the release smoke check. Keep values out of logs.",
        beforeGroup: nil, afterGroup: "Release Tools", createsGroup: true)

    static let createOneItemSummary = BrokerCredentialWriteSummary(credentialName: "Deploy Host", operation: .create,
        before: [], after: [component("DEPLOY_HOST", bytes: 18, .environmentVariable("DEPLOY_HOST"))],
        beforeDigest: nil, afterDigest: "after", beforeUsageInstructions: nil,
        afterUsageInstructions: "Use only for the staging deploy script.", beforeGroup: nil, afterGroup: "Staging", createsGroup: true)

    static let createTwoItemsSummary = BrokerCredentialWriteSummary(credentialName: "Staging SSH", operation: .create,
        before: [], after: [component("SSH_USER", bytes: 7, .environmentVariable("SSH_USER")),
                            component("SSH_KEY", bytes: 411, .temporaryFile("SSH_KEY_FILE"), kind: .file)],
        beforeDigest: nil, afterDigest: "after", beforeUsageInstructions: nil,
        afterUsageInstructions: "Use for SSH to the staging host only.", beforeGroup: nil, afterGroup: "Staging", createsGroup: false)

    static let createUngroupedSummary = BrokerCredentialWriteSummary(credentialName: "Deploy Host", operation: .create,
        before: [], after: [component("DEPLOY_HOST", bytes: 18, .environmentVariable("DEPLOY_HOST"))],
        beforeDigest: nil, afterDigest: "after", beforeUsageInstructions: nil, afterUsageInstructions: nil,
        beforeGroup: nil, afterGroup: nil, createsGroup: false)

    static let metadataSummary = BrokerCredentialWriteSummary(credentialName: "Release Check", operation: .modify,
        before: [token, user], after: [token, user], beforeDigest: "same", afterDigest: "same",
        beforeUsageInstructions: "Use for release checks.", afterUsageInstructions: "Use only for the nightly release check.",
        beforeGroup: "Release Tools", afterGroup: "Release Tools")

    static let valueSummary = BrokerCredentialWriteSummary(credentialName: "Release Check", operation: .modify,
        before: [component("TOKEN", bytes: 40, .environmentVariable("RELEASE_CHECK_TOKEN"))],
        after: [component("TOKEN", bytes: 52, .environmentVariable("RELEASE_CHECK_TOKEN"), value: "rotated")],
        beforeDigest: "old", afterDigest: "new", beforeUsageInstructions: "Use for release checks.",
        afterUsageInstructions: "Use for release checks.", beforeGroup: "Release Tools", afterGroup: "Release Tools")

    static let someValuesSummary = BrokerCredentialWriteSummary(credentialName: "Release Check", operation: .modify,
        before: [token, user], after: [component("TOKEN", bytes: 28, .environmentVariable("RELEASE_CHECK_TOKEN"), value: "rotated"), user],
        beforeDigest: "old", afterDigest: "new", beforeUsageInstructions: "Use for release checks.",
        afterUsageInstructions: "Use for release checks.", beforeGroup: "Release Tools", afterGroup: "Release Tools")

    static let instructionsAndGroupSummary = BrokerCredentialWriteSummary(credentialName: "Release Check", operation: .modify,
        before: [token, user], after: [token, user], beforeDigest: "same", afterDigest: "same",
        beforeUsageInstructions: "Use for release checks.", afterUsageInstructions: "Use for release checks and smoke tests.",
        beforeGroup: "Release Tools", afterGroup: "Operations")

    static let removedSummary = BrokerCredentialWriteSummary(credentialName: "Release Check", operation: .modify,
        before: [token, user], after: [token], beforeDigest: "old", afterDigest: "new",
        beforeUsageInstructions: "Use for release checks.", afterUsageInstructions: "Use for release checks.",
        beforeGroup: "Release Tools", afterGroup: "Release Tools")

    static let mixedSummary = BrokerCredentialWriteSummary(credentialName: "Release Check", operation: .modify,
        before: [component("TOKEN", bytes: 40, .environmentVariable("RELEASE_CHECK_TOKEN"))],
        after: [component("TOKEN", bytes: 52, .environmentVariable("RELEASE_CHECK_TOKEN"), value: "rotated")],
        beforeDigest: "old", afterDigest: "new", beforeUsageInstructions: "Use for release checks.",
        afterUsageInstructions: "Use for release checks.", beforeGroup: "Release Tools", afterGroup: "Operations")

    static let addedSummary = BrokerCredentialWriteSummary(credentialName: "Release Check", operation: .modify,
        before: [token, user], after: [token, user, certificate], beforeDigest: "old", afterDigest: "new",
        beforeUsageInstructions: "Use for release checks.", afterUsageInstructions: "Use for release checks.",
        beforeGroup: "Release Tools", afterGroup: "Release Tools")

    static let deleteSummary = BrokerCredentialWriteSummary(credentialName: "Release Check", operation: .delete,
        before: [token, user], after: [], beforeDigest: "current", afterDigest: nil,
        beforeUsageInstructions: "Use for release checks.", afterUsageInstructions: nil,
        beforeGroup: "Release Tools", afterGroup: nil)

    static let regularOrganization = BrokerOrganizationSummary(operations: [
        .createGroup("Staging Services"),
        .move(credential: "Staging API", from: "Old Services", to: "Staging Services"),
        .renameGroup(from: "Old Services", to: "Renamed Services", members: 3, nonvisible: 2),
        .deleteGroup(name: "Temp", members: 1, nonvisible: 0),
    ])

    static let existingAndMerge = BrokerOrganizationSummary(operations: [
        .existingGroup(name: "Existing Private Services", members: 1, nonvisible: 1),
        .mergeGroup(from: "Merge Source", to: "Existing Merge Services", members: 2, nonvisible: 1,
                    targetMembers: 2, targetNonvisible: 2),
    ])

    static let twelveSteps = BrokerOrganizationSummary(operations: (1...12).map { index in
        switch index % 4 {
        case 0: return .deleteGroup(name: "Temp \(index)", members: 2, nonvisible: 1)
        case 1: return .createGroup("Group \(index)")
        case 2: return .move(credential: "Service \(index)", from: nil, to: "Group \(index - 1)")
        default: return .renameGroup(from: "Old \(index)", to: "New \(index)", members: 1, nonvisible: 0)
        }
    })

    static func prompt(_ card: Card) -> FrozenAgentApprovalPrompt {
        let expiry = Date().addingTimeInterval(299)
        switch card {
        case .readDefault:
            return .init(request: request(.read, display: display()), expiresAt: expiry, timedAllowanceEnabled: true, finish: { _ in })
        case .readDetails:
            return .init(request: request(.read, display: display()), expiresAt: expiry, timedAllowanceEnabled: true,
                         detailsExpanded: true, finish: { _ in })
        case .readFile:
            return .init(request: request(.read, display: display(environment: [], files: ["STAGING_CERT_FILE"])),
                         expiresAt: expiry, timedAllowanceEnabled: true, finish: { _ in })
        case .readCancelled:
            return .init(request: request(.read, display: display()), expiresAt: expiry, timedAllowanceEnabled: true,
                         cancelledAuthenticationDecision: .timedAllow(duration: nil), finish: { _ in })
        case .readWithoutTimed:
            return .init(request: request(.read, display: display()), expiresAt: expiry, timedAllowanceEnabled: false, finish: { _ in })
        case .readLongCommand:
            let command = "./deploy.sh " + (1...24).map { "--flag-\($0) value-\($0)" }.joined(separator: " ")
            return .init(request: request(.read, display: display(command: command)), expiresAt: expiry,
                         timedAllowanceEnabled: true, finish: { _ in })
        case .readBundle:
            return .init(request: request(.read, display: display(environment: nil, files: nil)), expiresAt: expiry,
                         timedAllowanceEnabled: true, finish: { _ in })
        case .create:
            return write(.create, createSummary)
        case .createOneItem:
            return write(.create, createOneItemSummary, purpose: "Save the staging deploy host")
        case .createTwoItems:
            return write(.create, createTwoItemsSummary, purpose: "Save the staging SSH login")
        case .createUngrouped:
            return write(.create, createUngroupedSummary, purpose: "Save the staging deploy host")
        case .modifyMetadata:
            return write(.modify, metadataSummary)
        case .modifyInstructionsAndGroup:
            return write(.modify, instructionsAndGroupSummary)
        case .modifyValue:
            return write(.modify, valueSummary)
        case .modifySomeValues:
            return write(.modify, someValuesSummary)
        case .modifyAdded:
            return write(.modify, addedSummary)
        case .modifyRemoved:
            return write(.modify, removedSummary)
        case .modifyMixed:
            return write(.modify, mixedSummary)
        case .delete:
            return write(.delete, deleteSummary)
        case .organize:
            return organize(regularOrganization)
        case .organizeExistingAndMerge:
            return organize(existingAndMerge)
        case .organizeTwelveSteps:
            return organize(twelveSteps)
        }
    }

    static func write(_ operation: BrokerApprovalOperation, _ summary: BrokerCredentialWriteSummary,
                      purpose: String? = "Save the release smoke-check credential") -> FrozenAgentApprovalPrompt {
        .init(request: request(operation, name: summary.credentialName, purpose: purpose),
              expiresAt: Date().addingTimeInterval(299), timedAllowanceEnabled: true, writeSummary: summary,
              revealMaterial: { throw CancellationError() }, finish: { _ in })
    }

    static func organize(_ summary: BrokerOrganizationSummary,
                         purpose: String? = "Tidy the synthetic credential library") -> FrozenAgentApprovalPrompt {
        .init(request: request(.organize, purpose: purpose), expiresAt: Date().addingTimeInterval(299),
              timedAllowanceEnabled: true, organizationSummary: summary, finish: { _ in })
    }

    /// The card's title, subtitle and buttons as shown, in the current language.
    static func copy(_ card: Card) -> (title: String, subtitle: String?, buttons: [String]) {
        let presentation = prompt(card).presentation
        let content = presentation.content
        let subtitle = content.commandSummary.map { appLocalized("to run") + " " + $0 } ?? content.subtitle
        return (content.title, subtitle, presentation.buttons.map(\.title))
    }

    /// Lays the card out and lets its scroll areas publish their geometry.
    static func host(_ prompt: FrozenAgentApprovalPrompt) -> NSHostingView<FrozenAgentApprovalPrompt> {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: prompt)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            hosting.frame.size = hosting.fittingSize
        }
        return hosting
    }

    static func withLanguages(_ body: (String) throws -> Void) rethrows {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        for language in ["en", "zh-Hans"] {
            AppLanguage.current = language
            try body(language)
        }
    }
}
