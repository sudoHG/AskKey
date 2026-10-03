import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

struct CredentialManagementView: View {
    let previewMode: Bool
    let previewPendingRequests: [BrokerApprovalOperationRequest]
    private let previewReadAuthenticationConfirmation: Bool
    private let previewEditorExpanded: Bool
    private let previewImportValues: [(name: String, value: String)]
    private let previewSettingsErase: Bool
    private let previewCredentialDeleteConfirmationID: String?
    private let previewAccessRecordClearConfirmation: Bool

    @Environment(VaultViewModel.self) var vault
    @State var searchText = ""
    @Binding var selectedSection: CredentialWorkspaceSection
    @State var selectedCredentialID: String?
    @Binding var route: CredentialWorkspaceRoute
    @State var deletingCredential: ManagedTextCredential?
    @State var permanentlyDeletingCredentialID: String?
    @State var deletingGroupName: String?
    @State private var showingNewGroup = false
    @State private var newGroupName = ""
    @State var allowanceRefresh = 0
    @FocusState var searchFocused: Bool

    init(
        selectedSection: Binding<CredentialWorkspaceSection>,
        route: Binding<CredentialWorkspaceRoute>
    ) {
        previewMode = false
        previewPendingRequests = []
        previewReadAuthenticationConfirmation = false
        previewEditorExpanded = false
        previewImportValues = []
        previewSettingsErase = false
        previewCredentialDeleteConfirmationID = nil
        previewAccessRecordClearConfirmation = false
        _selectedSection = selectedSection
        _route = route
        _selectedCredentialID = State(initialValue: nil)
        _deletingGroupName = State(initialValue: nil)
    }

    init(
        initialSection: CredentialWorkspaceSection = .all,
        initialRoute: CredentialWorkspaceRoute = .library,
        selectedCredentialID: String? = nil,
        previewMode: Bool = false,
        previewPendingRequests: [BrokerApprovalOperationRequest] = [],
        previewReadAuthenticationConfirmation: Bool = false,
        previewEditorExpanded: Bool = false,
        previewImportValues: [(name: String, value: String)] = [],
        previewSettingsErase: Bool = false,
        previewCredentialDeleteConfirmation: String? = nil,
        previewGroupDeleteConfirmation: String? = nil,
        previewAccessRecordClearConfirmation: Bool = false
    ) {
        self.previewMode = previewMode
        self.previewPendingRequests = previewPendingRequests
        self.previewReadAuthenticationConfirmation = previewReadAuthenticationConfirmation
        self.previewEditorExpanded = previewEditorExpanded
        self.previewImportValues = previewImportValues
        self.previewSettingsErase = previewSettingsErase
        self.previewCredentialDeleteConfirmationID = previewCredentialDeleteConfirmation
        self.previewAccessRecordClearConfirmation = previewAccessRecordClearConfirmation
        _selectedSection = .constant(initialSection)
        _route = .constant(initialRoute)
        _selectedCredentialID = State(initialValue: selectedCredentialID)
        _deletingGroupName = State(initialValue: previewGroupDeleteConfirmation)
    }

    var body: some View {
        HStack(spacing: 0) {
            CredentialWorkspaceSidebar(
                selectedSection: $selectedSection,
                route: $route,
                allowsCredentialChanges: true,
                clearCredentialSelection: { selectedCredentialID = nil },
                createGroup: { showingNewGroup = true },
                deleteGroup: { deletingGroupName = $0 }
            )
                .frame(width: WorkspaceVisualContract.sidebarWidth)
                .fixedSize(horizontal: true, vertical: false)
            Divider().overlay(Theme.neutral(0.06))
            detail
                .frame(minWidth: 480)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBackground)
        .environment(\.locale, vault.appLocale)
        .onAppear {
            if !previewMode { vault.reloadCredentials() }
            if let id = previewCredentialDeleteConfirmationID {
                deletingCredential = vault.credentials.first { $0.id == id }
            }
            consumePendingCredentialAction()
        }
        .onChange(of: vault.pendingAddSecret) { _, _ in consumePendingCredentialAction() }
        .onChange(of: selectedSection) { _, _ in
            searchText = CredentialSearchPresentation.queryAfterChangingSection(searchText)
        }
        .alert(appLocalized("New group"), isPresented: $showingNewGroup) {
            TextField(appLocalized("Group name"), text: $newGroupName)
            Button(appLocalized("Create")) {
                let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { vault.createCredentialGroup(name) }
                newGroupName = ""
            }
            Button(appLocalized("Cancel"), role: .cancel) { newGroupName = "" }
        }
    }

    private func consumePendingCredentialAction() {
        guard vault.pendingAddSecret else { return }
        vault.pendingAddSecret = false
        route = .templateChooser
    }

    @ViewBuilder
    private var detail: some View {
        switch route {
        case .templateChooser:
            templateChooser
        case .fileImport:
            FrozenFileImportPage(
                group: selectedSection.importDestinationGroup,
                previewValues: previewImportValues,
                onCancel: { route = .library },
                onSaved: { route = .library },
                onReplaced: { route = .credentialDetail($0) }
            )
            .environment(vault)
        case .editor(let template, let credentialID):
            editorDestination(
                CredentialEditorAvailability.resolve(
                    template: template,
                    credentialID: credentialID,
                    credentials: vault.credentials
                ),
                credentialID: credentialID
            )
        case .pendingRequests:
            pendingRequestsDetail
        case .settings:
            FrozenSettingsPage(
                initialReadAuthenticationConfirmation: previewReadAuthenticationConfirmation,
                initialEraseConfirmation: previewSettingsErase,
                initialAccessRecordClearConfirmation: previewAccessRecordClearConfirmation
            )
            .environment(vault)
        case .accessRecords:
            accessRecordsDetail
        case .recycleBin:
            recycleBinDetail
        case .agentAccess:
            AgentOnboardingView()
        case .credentialDetail(let id):
            credentialDetailPage(id: id)
        case .library:
            credentialDetail
        }
    }

    @ViewBuilder
    private func editorDestination(
        _ availability: CredentialEditorAvailability,
        credentialID: String?
    ) -> some View {
        switch availability {
        case .create(let template):
            CredentialEditorView(
                credential: nil,
                preferredGroup: selectedSection.importDestinationGroup,
                initialTemplate: template,
                initialMoreExpanded: previewEditorExpanded,
                onClose: {
                    vault.reloadCredentials()
                    route = .library
                }
            )
            .environment(vault)
            .id("editor-create-\(template.rawValue)")
        case .edit(let template, let credential):
            CredentialEditorView(
                credential: credential,
                preferredGroup: selectedSection.importDestinationGroup,
                initialTemplate: template,
                initialMoreExpanded: previewEditorExpanded,
                onClose: {
                    vault.reloadCredentials()
                    route = .credentialDetail(credential.id)
                }
            )
            .environment(vault)
            .id("editor-edit-\(credential.id)")
        case .unavailable:
            CredentialEditorUnavailablePage {
                route = .library
            }
            .id("editor-unavailable-\(credentialID ?? "")")
        }
    }

    private var templateChooser: some View {
        FrozenTemplateChooserPage(
            onBack: { route = .library },
            onSelect: { route = .editor(template: $0, credentialID: nil) }
        )
    }

}
