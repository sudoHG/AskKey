import Foundation

enum AskKeyAppSource {
    static let paths = [
        "Sources/AskKeyAppKit/App/AgentApprovalGatedRequest.swift",
        "Sources/AskKeyAppKit/App/AgentApprovalPresentationPlan.swift",
        "Sources/AskKeyAppKit/App/AgentApprovalPresentationCoordinator.swift",
        "Sources/AskKeyAppKit/App/AgentApprovalPanelActions.swift",
        "Sources/AskKeyAppKit/App/AgentApprovalPanelPlacement.swift",
        "Sources/AskKeyAppKit/App/AgentApprovalPrivacyPolicy.swift",
        "Sources/AskKeyAppKit/App/AgentApprovalRequestSelection.swift",
        "Sources/AskKeyAppKit/App/AgentApprovalScreenState.swift",
        "Sources/AskKeyAppKit/App/ApprovalPromptContent.swift",
        "Sources/AskKeyAppKit/App/AppDelegate+Approval.swift",
        "Sources/AskKeyAppKit/App/AppDelegate+BrokerLifecycle.swift",
        "Sources/AskKeyAppKit/App/AppDelegate+StatusItem.swift",
        "Sources/AskKeyAppKit/App/AppDelegate+Termination.swift",
        "Sources/AskKeyAppKit/App/AppDelegate+WindowManagement.swift",
        "Sources/AskKeyAppKit/App/AppDelegate.swift",
        "Sources/AskKeyAppKit/App/AppLaunchPresentation.swift",
        "Sources/AskKeyAppKit/App/AppLaunchSource.swift",
        "Sources/AskKeyAppKit/App/AppRuntimeState.swift",
        "Sources/AskKeyAppKit/App/AskKeyApp.swift",
        "Sources/AskKeyAppKit/App/FrozenAgentApprovalPrompt.swift",
        "Sources/AskKeyAppKit/App/FrozenApprovalActions.swift",
        "Sources/AskKeyAppKit/App/FrozenApprovalMaterial.swift",
        "Sources/AskKeyAppKit/App/ApprovalDetailsView.swift",
        "Sources/AskKeyAppKit/App/FrozenWriteRevealCopy.swift",
        "Sources/AskKeyAppKit/App/HostingWindowSizing.swift",
        "Sources/AskKeyAppKit/App/LockedApprovalReminderDeliveryPolicy.swift",
        "Sources/AskKeyAppKit/App/LockedApprovalReminderDeliveryResult.swift",
        "Sources/AskKeyAppKit/App/ManagementSessionLifecycle.swift",
        "Sources/AskKeyAppKit/App/ManagementWindow.swift",
        "Sources/AskKeyAppKit/App/ManagementWindowConfiguration.swift",
        "Sources/AskKeyAppKit/App/NSHostingView+WindowSizing.swift",
        "Sources/AskKeyAppKit/App/Notification.Name+AgentApproval.swift",
    ]

    static func read(from root: URL) throws -> String {
        try paths.map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
    }
}
