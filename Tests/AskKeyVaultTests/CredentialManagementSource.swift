import Foundation

enum CredentialManagementSource {
    static let paths = [
        "Sources/AskKeyAppKit/Views/AccessRecords/FrozenAccessRecordsCopy.swift",
        "Sources/AskKeyAppKit/Views/AccessRecords/FrozenClock.swift",
        "Sources/AskKeyAppKit/Views/AccessRecords/FrozenPendingRequestsCopy.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialComponentDraft.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialEditorAvailability.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialEditorComponentLoader.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialEditorComponentValidation.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialEditorInputVisibility.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialEditorInteractionPresentation.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialEditorPresentation.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialEditorUnavailablePage.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialEditorView+Components.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialEditorView+Files.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialEditorView+Saving.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialEditorView.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialEmptyPresentation.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialListPresentation.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialManagementView+AccessRecords.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialManagementView+Components.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialManagementView+Inspector.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialManagementView+List.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialManagementView+PendingRequests.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialManagementView+RecycleBin.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialManagementView.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialSearchPresentation.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialSidebarSelection.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialTemplate+Matching.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialTemplate.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialWorkspaceRoute+Sidebar.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialWorkspaceRoute.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialWorkspaceSection.swift",
        "Sources/AskKeyAppKit/Views/Credentials/CredentialWorkspaceSidebar.swift",
        "Sources/AskKeyAppKit/Views/Credentials/FrozenCollectionCopy.swift",
        "Sources/AskKeyAppKit/Views/Credentials/FrozenCredentialDetailCopy.swift",
        "Sources/AskKeyAppKit/Views/Credentials/FrozenEditorCopy.swift",
        "Sources/AskKeyAppKit/Views/Credentials/FrozenEditorMoreSettingsPresentation.swift",
        "Sources/AskKeyAppKit/Views/Credentials/FrozenFileImportMapping.swift",
        "Sources/AskKeyAppKit/Views/Credentials/FrozenFileImportPage.swift",
        "Sources/AskKeyAppKit/Views/Credentials/FrozenImportConflictChoice.swift",
        "Sources/AskKeyAppKit/Views/Credentials/FrozenImportConflictPresentation.swift",
        "Sources/AskKeyAppKit/Views/Credentials/FrozenImportCopy.swift",
        "Sources/AskKeyAppKit/Views/Credentials/FrozenImportTableLayout.swift",
        "Sources/AskKeyAppKit/Views/Credentials/RecycleBinPresentation.swift",
        "Sources/AskKeyAppKit/Views/Onboarding/FrozenTemplateChooserPage.swift",
        "Sources/AskKeyAppKit/Views/Settings/FrozenEraseConfirmationPresentation.swift",
        "Sources/AskKeyAppKit/Views/Settings/FrozenHotkeySettingsPresentation.swift",
        "Sources/AskKeyAppKit/Views/Settings/FrozenReadAuthenticationPresentation.swift",
        "Sources/AskKeyAppKit/Views/Settings/FrozenSettingsContract.swift",
        "Sources/AskKeyAppKit/Views/Settings/FrozenSettingsPage.swift",
        "Sources/AskKeyAppKit/Views/Settings/FrozenTimedAllowanceSettingsPresentation.swift",
        "Sources/AskKeyAppKit/Views/Shared/CredentialPermission+Presentation.swift",
        "Sources/AskKeyAppKit/Views/Shared/FrozenCountdown.swift",
        "Sources/AskKeyAppKit/Views/Shared/FrozenDangerActions.swift",
        "Sources/AskKeyAppKit/Views/Shared/FrozenDangerButtonStyle.swift",
        "Sources/AskKeyAppKit/Views/Shared/FrozenPrimaryButtonStyle.swift",
        "Sources/AskKeyAppKit/Views/Shared/FrozenSegmentedControl.swift",
        "Sources/AskKeyAppKit/Views/Shared/WorkspaceEmptyState.swift",
    ]

    static func read(from root: URL, relative: String) throws -> String {
        let files = relative == "Sources/AskKeyAppKit/Views/CredentialManagementView.swift"
            ? paths : [relative]
        return try files.map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
    }
}
