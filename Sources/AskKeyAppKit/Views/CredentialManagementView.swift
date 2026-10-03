import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyCore

enum CredentialWorkspaceSection: Hashable {
    case all
    case ungrouped
    case named(String)
    case accessRecords
    case recycleBin
    case agentAccess

    var importDestinationGroup: String? {
        if case .named(let name) = self { return name }
        return nil
    }

    var showsCredentialImport: Bool {
        switch self {
        case .all, .ungrouped, .named: return true
        case .accessRecords, .recycleBin, .agentAccess: return false
        }
    }
}

enum CredentialWorkspaceRoute: Equatable {
    case library
    case pendingRequests
    case accessRecords
    case agentAccess
    case recycleBin
    case templateChooser
    case editor(template: CredentialTemplate, credentialID: String?)
    case fileImport
    case credentialDetail(String)
    case settings

}

enum CredentialEditorAvailability: Equatable {
    case create(template: CredentialTemplate)
    case edit(template: CredentialTemplate, credential: ManagedTextCredential)
    case unavailable(id: String)

    static func resolve(
        template: CredentialTemplate,
        credentialID: String?,
        credentials: [ManagedTextCredential]
    ) -> CredentialEditorAvailability {
        guard let credentialID else { return .create(template: template) }
        if let credential = credentials.first(where: { $0.id == credentialID }) {
            return .edit(template: template, credential: credential)
        }
        return .unavailable(id: credentialID)
    }
}

enum CredentialSidebarSelection: Equatable {
    case credentials
    case pendingRequests
    case accessRecords
    case agentAccess
    case recycleBin
    case settings
}

extension CredentialWorkspaceRoute {
    var sidebarSelection: CredentialSidebarSelection {
        switch self {
        case .pendingRequests: return .pendingRequests
        case .accessRecords: return .accessRecords
        case .agentAccess: return .agentAccess
        case .recycleBin: return .recycleBin
        case .settings: return .settings
        default: return .credentials
        }
    }
}

struct CredentialWorkspaceSidebar: View {
    @Environment(VaultViewModel.self) private var vault
    @Binding var selectedSection: CredentialWorkspaceSection
    @Binding var route: CredentialWorkspaceRoute
    let allowsCredentialChanges: Bool
    var clearCredentialSelection: () -> Void = {}
    var createGroup: () -> Void = {}
    var deleteGroup: (String) -> Void = { _ in }

    var body: some View {
        let _ = AppLanguage.store.resolved
        VStack(alignment: .leading, spacing: 0) {
            // Leave room for the window's native title-bar controls.
            Color.clear
                .frame(height: 32)
                .accessibilityHidden(true)
                .allowsHitTesting(false)

            HStack {
                Text(appLocalized("Credential Library"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .textCase(.uppercase)
                Spacer()
                if allowsCredentialChanges {
                    Button(action: createGroup) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textMuted)
                    .help(appLocalized("New group"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

            ScrollView {
                LazyVStack(spacing: 2) {
                    groupRow(.all, title: appLocalized("All credentials"), count: vault.credentials.count)
                    ForEach(vault.credentialGroups, id: \.self) { name in
                        groupRow(
                            .named(name),
                            title: name,
                            count: vault.credentials.filter { $0.groupName == name }.count
                        )
                        .contextMenu {
                            if allowsCredentialChanges {
                                Button(appLocalized("Delete group"), role: .destructive) {
                                    select(.named(name))
                                    deleteGroup(name)
                                }
                            }
                        }
                    }
                    groupRow(
                        .ungrouped,
                        title: appLocalized(CredentialManagementCopy.ungrouped),
                        count: vault.credentials.filter(\.isUngrouped).count
                    )
                    groupRow(
                        .recycleBin,
                        title: appLocalized("Recycle Bin"),
                        count: vault.recycledCredentials.count
                    )
                }
            }

            Spacer()

            Text(appLocalized("Agent approvals"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            routeButton(
                .pendingRequests,
                title: appLocalized("Pending requests"),
                icon: "tray",
                identifier: "sidebar-pending",
                count: vault.pendingApprovalCount
            )
            routeButton(
                .accessRecords,
                title: appLocalized("Access records"),
                icon: "clock",
                identifier: "sidebar-records"
            )

            Divider().overlay(Theme.sep).padding(.horizontal, 14)

            routeButton(
                .agentAccess,
                title: appLocalized("Agent access"),
                icon: "desktopcomputer",
                identifier: "sidebar-agent"
            )
            routeButton(
                .settings,
                title: appLocalized("Settings"),
                icon: "gearshape",
                identifier: "sidebar-settings",
                bottomPadding: 8
            )
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func groupRow(
        _ section: CredentialWorkspaceSection,
        title: String,
        count: Int
    ) -> some View {
        let selected = selectedSection == section && route.sidebarSelection == sidebarSelection(for: section)
        return Button {
            select(section)
        } label: {
            HStack {
                Image(systemName: sidebarIcon(for: section))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(selected ? Theme.neutral(0.10) : Color.clear, in: .rect(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(sidebarIdentifier(for: section))
        .accessibilityValue(selected ? "selected" : "")
    }

    private func routeButton(
        _ destination: CredentialWorkspaceRoute,
        title: String,
        icon: String,
        identifier: String,
        count: Int? = nil,
        bottomPadding: CGFloat = 0
    ) -> some View {
        let selected = route.sidebarSelection == destination.sidebarSelection
        return Button {
            activateRoute(destination)
        } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if let count { Text("\(count)") }
            }
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, destination == .settings ? 12 : 8)
            .background(selected ? Theme.neutral(0.10) : Color.clear, in: .rect(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .padding(.bottom, bottomPadding)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(selected ? "selected" : "")
        .registerAction(identifier, action: { activateRoute(destination) })
    }

    private func activateRoute(_ destination: CredentialWorkspaceRoute) {
        selectRoute(destination)
        if destination == .accessRecords, vault.hasManagementSession {
            vault.reloadCredentialAccessRecords()
        }
    }

    func selectRoute(_ destination: CredentialWorkspaceRoute) {
        route = destination
        switch destination {
        case .accessRecords: selectedSection = .accessRecords
        case .agentAccess: selectedSection = .agentAccess
        default: break
        }
        clearCredentialSelection()
    }

    private func select(_ section: CredentialWorkspaceSection) {
        selectedSection = section
        clearCredentialSelection()
        switch section {
        case .accessRecords:
            route = .accessRecords
            if vault.hasManagementSession { vault.reloadCredentialAccessRecords() }
        case .recycleBin:
            route = .recycleBin
        case .agentAccess:
            route = .agentAccess
        default:
            route = .library
        }
    }

    private func sidebarSelection(for section: CredentialWorkspaceSection) -> CredentialSidebarSelection {
        switch section {
        case .recycleBin: return .recycleBin
        default: return .credentials
        }
    }

    private func sidebarIdentifier(for section: CredentialWorkspaceSection) -> String {
        switch section {
        case .all: return "sidebar-all"
        case .ungrouped: return "sidebar-ungrouped"
        case .named(let name): return "sidebar-group-\(name)"
        case .recycleBin: return "sidebar-recycle"
        case .accessRecords: return "sidebar-records"
        case .agentAccess: return "sidebar-agent"
        }
    }

    private func sidebarIcon(for section: CredentialWorkspaceSection) -> String {
        switch section {
        case .all: return "archivebox"
        case .named: return "folder"
        case .ungrouped: return "line.3.horizontal"
        case .recycleBin: return "trash"
        case .accessRecords: return "clock"
        case .agentAccess: return "desktopcomputer"
        }
    }

}

struct CredentialManagementView: View {
    private let previewMode: Bool
    private let previewPendingRequests: [BrokerApprovalOperationRequest]
    private let previewReadAuthenticationConfirmation: Bool
    private let previewEditorExpanded: Bool
    private let previewImportValues: [(name: String, value: String)]
    private let previewSettingsErase: Bool
    private let previewCredentialDeleteConfirmationID: String?
    private let previewAccessRecordClearConfirmation: Bool

    @Environment(VaultViewModel.self) private var vault
    @State private var searchText = ""
    @Binding private var selectedSection: CredentialWorkspaceSection
    @State private var selectedCredentialID: String?
    @Binding private var route: CredentialWorkspaceRoute
    @State private var deletingCredential: ManagedTextCredential?
    @State private var permanentlyDeletingCredentialID: String?
    @State private var deletingGroupName: String?
    @State private var showingNewGroup = false
    @State private var newGroupName = ""
    @State private var allowanceRefresh = 0
    @FocusState private var searchFocused: Bool

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

    private var filteredCredentials: [ManagedTextCredential] {
        vault.credentials.filter { credential in
            switch selectedSection {
            case .all: break
            case .accessRecords, .recycleBin, .agentAccess: return false
            case .ungrouped:
                if credential.groupName != nil { return false }
            case .named(let name):
                if credential.groupName != name { return false }
            }
            if searchText.isEmpty { return true }
            let query = searchText.lowercased()
            return credential.name.lowercased().contains(query)
                || (credential.groupName?.lowercased().contains(query) ?? false)
                || credential.usageInstructions.lowercased().contains(query)
        }
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
    private var credentialDetail: some View {
        if selectedCredentialID != nil {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    selectedCredentialID = nil
                } label: {
                    Label(sectionTitle, systemImage: "arrow.left")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.brand)
                .padding(.horizontal, 28)
                .padding(.top, 20)
                credentialInspector
            }
            .background(Theme.windowBackground)
        } else {
            VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sectionTitle)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(sectionSubtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
                if selectedSection.showsCredentialImport {
                    BorderedActionButton(action: {
                        route = .fileImport
                    }) {
                        Label(
                            selectedSection.importDestinationGroup == nil
                                ? appLocalized("Import from File")
                                : FrozenCollectionCopy.importAction,
                            systemImage: "square.and.arrow.down"
                        )
                    }
                }
                Button(action: {
                    route = .templateChooser
                }) {
                    Label(
                        selectedSection.importDestinationGroup == nil
                            ? appLocalized("New Credential")
                            : FrozenCollectionCopy.newCredentialAction,
                        systemImage: "plus"
                    )
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(height: Theme.controlHeight)
                        .padding(.horizontal, 10)
                        .background(Theme.brand, in: .rect(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("credential-new")
                if case .named(let name) = selectedSection {
                    if deletingGroupName == name {
                        Button(FrozenDangerActions.groupConfirmationTitle, role: .destructive) {
                            deletingGroupName = nil
                            vault.deleteCredentialGroup(name)
                            selectedSection = .ungrouped
                        }
                        .buttonStyle(FrozenDangerButtonStyle())
                        Button(appLocalized("Keep")) { deletingGroupName = nil }
                    } else {
                        Button(FrozenCollectionCopy.deleteAction, role: .destructive) {
                            deletingGroupName = name
                        }
                            .buttonStyle(.bordered)
                            .foregroundStyle(Theme.red)
                            .tint(Theme.red)
                    }
                }
            }
            if deletingGroupName != nil {
                inlineWarning(appLocalized("Deleting a group does not delete credentials. Its credentials become ungrouped."))
            }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            if FrozenCollectionCopy.showsSearch(
                section: selectedSection,
                hasCredentials: !vault.credentials.isEmpty
            ) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.textDim)
                    TextField(appLocalized("Search credentials…"), text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                }
                .padding(.horizontal, 10)
                .frame(width: 300, height: 28)
                .background(Theme.neutral(0.055), in: .rect(cornerRadius: 7))
                .padding(.horizontal, 28)
                .padding(.bottom, 14)
            }

            if filteredCredentials.isEmpty {
                emptyState
            } else {
                credentialList
            }
            }
            .background(Theme.windowBackground)
        }
    }

    private func credentialDetailPage(id: String) -> some View {
        credentialDetail.onAppear { selectedCredentialID = id }
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

    private var pendingRequestsDetail: some View {
        let storedApprovals = previewMode
            ? previewPendingRequests.map {
                BrokerPendingApproval(
                    requestID: $0.operationID,
                    capability: "preview",
                    request: $0,
                    expiresAt: Date().addingTimeInterval(300)
                )
            }
            : vault.pendingApprovals
        let approvals = storedApprovals
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appLocalized("Pending Requests"))
                        .font(.system(size: 20, weight: .bold))
                    Text(appLocalized("Agent requests open a system confirmation. Missed or deferred requests remain here."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
            }
            .padding(28)
            if approvals.isEmpty, vault.pendingApprovalCount == 0 {
                WorkspaceEmptyState(
                    title: appLocalized("No Pending Requests"),
                    message: appLocalized("New requests open a confirmation and remain here if deferred."),
                    systemImage: "checkmark"
                )
            } else {
                if !approvals.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(approvals, id: \.request.operationID) { approval in
                                let request = approval.request
                                HStack(spacing: 12) {
                                    Image(systemName: request.operation == .read ? "command" : "pencil")
                                        .frame(width: 32, height: 32)
                                        .background(Theme.neutral(0.06), in: .rect(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(request.callerName ?? appLocalized("Local Agent")) · \(requestOperationTitle(request.operation)) \(approval.displayCredentialName)")
                                            .font(.system(size: 13.5, weight: .semibold))
                                        TimelineView(.periodic(from: .now, by: 1)) { context in
                                            Text("\(request.callerPurpose ?? appLocalized("No purpose declared")) · \(appLocalized("Remaining")) \(FrozenCountdown.format(deadline: approval.expiresAt, now: context.date))")
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(Theme.textMuted)
                                        }
                                    }
                                    Spacer()
                                    pendingRequestAction(
                                        request,
                                        isDefault: request.operationID
                                            == approvals.first?.request.operationID
                                    )
                                }
                                .padding(14)
                                .background(Theme.panelBackground, in: .rect(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.neutral(0.08)))
                                .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
                            }
                        }
                        .padding(.horizontal, 28)
                    }
                } else {
                HStack(spacing: 12) {
                    Image(systemName: "tray.full")
                        .frame(width: 32, height: 32)
                        .background(Theme.neutral(0.06), in: .rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appLocalizedFormat("%lld Agent requests are waiting", vault.pendingApprovalCount))
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(appLocalized("Credential contents stay masked until you open the confirmation."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    Button(appLocalized("Open Confirmation")) {
                        NotificationCenter.default.post(name: .presentNextAgentApproval, object: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                }
                .padding(14)
                .background(Theme.panelBackground, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.neutral(0.08)))
                .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
                .padding(.horizontal, 28)
                }
            }
            Spacer()
        }
        .background(Theme.windowBackground)
    }

    private func requestOperationTitle(_ operation: BrokerApprovalOperation) -> String {
        switch operation {
        case .read: return appLocalized("requests use of")
        case .create: return appLocalized("requests creation of")
        case .modify: return appLocalized("requests a change to")
        case .delete: return appLocalized("requests deletion of")
        }
    }

    @ViewBuilder
    private func pendingRequestAction(
        _ request: BrokerApprovalOperationRequest,
        isDefault: Bool
    ) -> some View {
        let button = Button(appLocalized("Open Confirmation")) {
            NotificationCenter.default.post(
                name: .presentNextAgentApproval,
                object: request.operationID
            )
        }
        .buttonStyle(FrozenPrimaryButtonStyle())
        .accessibilityIdentifier("request-\(request.operationID)")
        if isDefault {
            button.keyboardShortcut(.defaultAction)
        } else {
            button
        }
    }

    private var sectionTitle: String {
        switch selectedSection {
        case .all: return appLocalized("All credentials")
        case .ungrouped: return appLocalized(CredentialManagementCopy.ungrouped)
        case .named(let name): return name
        default: return appLocalized(CredentialManagementCopy.credential)
        }
    }

    private var sectionSubtitle: String {
        switch selectedSection {
        case .named:
            return FrozenCollectionCopy.groupSubtitle
        case .ungrouped:
            return appLocalized("Groups are for organization only and do not change authorization.")
        default:
            return appLocalized("Each credential is delivered and authorized as one complete set.")
        }
    }

    private var accessRecordsDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appLocalized("Access records"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(FrozenAccessRecordsCopy.subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            if vault.credentialAccessRecords.isEmpty {
                WorkspaceEmptyState(
                    title: appLocalized("No Access Records Yet"),
                    message: FrozenAccessRecordsCopy.subtitle,
                    systemImage: "list.bullet.rectangle"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                    ForEach(Array(vault.credentialAccessRecords.enumerated()), id: \.offset) { _, event in
                    HStack(alignment: .top, spacing: 14) {
                        Text(FrozenClock.string(from: event.timestamp))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 52, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(accessOperationTitle(event.operation))
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(credentialName(for: event.credentialID)) · \(event.callerHint ?? appLocalized("Local Caller"))")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        credentialTag(accessResultTitle(event.result), accent: event.result == .allowed)
                    }
                    .padding(12)
                    .background(Theme.panelBackground, in: .rect(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.neutral(0.08)))
                    .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
                    }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
            }
        }
        .background(Theme.windowBackground)
        .onAppear { if !previewMode { vault.reloadCredentialAccessRecords() } }
    }

    private var recycleBinDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appLocalized("Recycle Bin"))
                    .font(.system(size: 20, weight: .semibold))
                Text(FrozenCollectionCopy.recycleSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            if vault.recycledCredentials.isEmpty {
                WorkspaceEmptyState(
                    title: appLocalized("Recycle Bin is empty"),
                    message: FrozenCollectionCopy.recycleEmptyMessage,
                    systemImage: "trash"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                    ForEach(vault.recycledCredentials) { credential in
                    HStack(spacing: 12) {
                        Text(RecycleBinPresentation.credentialMarker(name: credential.name))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.brand)
                            .frame(width: 32, height: 32)
                            .background(Theme.brand.opacity(0.1), in: .rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(credential.name).font(.system(size: 14, weight: .semibold))
                            HStack(spacing: 6) {
                                credentialTag(appLocalizedFormat("%lld items", max(credential.components.count, 1)))
                                credentialTag(RecycleBinPresentation.remainingDaysCopy(
                                    deletedAt: credential.deletedAt,
                                    now: Date()
                                ), accent: true)
                            }
                        }
                        Spacer()
                        Button(appLocalized("Restore")) {
                            vault.restoreRecycledCredential(credential)
                        }
                        .accessibilityIdentifier("credential-restore-\(credential.id)")
                        if permanentlyDeletingCredentialID == credential.id {
                            Button(
                                FrozenDangerActions.permanentCredentialConfirmationTitle,
                                role: .destructive
                            ) {
                                permanentlyDeletingCredentialID = nil
                                Task { await vault.permanentlyDeleteRecycledCredential(credential) }
                            }
                            .buttonStyle(FrozenDangerButtonStyle())
                            .accessibilityIdentifier("credential-permanent-delete-confirm-\(credential.id)")
                            Button(appLocalized("Keep")) { permanentlyDeletingCredentialID = nil }
                        } else {
                            Button(appLocalized("Delete Permanently…"), role: .destructive) {
                                permanentlyDeletingCredentialID = credential.id
                            }
                            .foregroundStyle(Theme.red)
                            .tint(Theme.red)
                            .accessibilityIdentifier("credential-permanent-delete-\(credential.id)")
                        }
                    }
                    .padding(12)
                    .background(Theme.panelBackground, in: .rect(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.neutral(0.08)))
                    .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
                    }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
            }
        }
        .background(Theme.windowBackground)
        .onAppear { if !previewMode { vault.reloadCredentials() } }
    }

    private func accessOperationTitle(_ operation: CredentialAccessEvent.Operation) -> String {
        switch operation {
        case .catalog: return appLocalized("Browse Credential Catalog")
        case .runtimeRead: return appLocalized("Use Credential")
        case .create: return appLocalized("Create Credential")
        case .modify: return appLocalized("Modify Credential")
        case .delete: return appLocalized("Delete Credential")
        }
    }

    private func accessResultTitle(_ result: CredentialAccessEvent.Result) -> String {
        switch result {
        case .allowed: return appLocalized("Allowed")
        case .denied: return appLocalized("Denied")
        case .failed: return appLocalized("Failed")
        case .hiddenNameRejected: return appLocalized("Hidden")
        }
    }

    private func credentialName(for id: String?) -> String {
        guard let id else { return appLocalized("Hidden credential request") }
        return vault.credentials.first { $0.id == id }?.name ?? id
    }

    private var emptyState: some View {
        WorkspaceEmptyState(
            title: emptyTitle,
            message: emptyMessage,
            systemImage: "archivebox",
            actionTitle: emptyActionTitle,
            action: { route = .templateChooser }
        )
    }

    private var emptyTitle: String {
        CredentialEmptyPresentation.title(section: selectedSection, searchText: searchText)
    }

    private var emptyMessage: String {
        CredentialEmptyPresentation.message(section: selectedSection, searchText: searchText)
    }

    private var emptyActionTitle: String? {
        CredentialEmptyPresentation.action(section: selectedSection, searchText: searchText)
    }

    private var credentialList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredCredentials) { credential in
                Button {
                    selectedCredentialID = credential.id
                } label: {
                    HStack(spacing: 12) {
                        Text(String(credential.name.prefix(1)).uppercased())
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.brand)
                            .frame(width: 32, height: 32)
                            .background(Theme.brand.opacity(0.1), in: .rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(credential.name)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            HStack(spacing: 6) {
                                ForEach(
                                    CredentialListPresentation(credential: credential).tags,
                                    id: \.self
                                ) { tag in
                                    credentialTag(
                                        tag,
                                        accent: tag == credential.permission.prototypeTitle
                                    )
                                }
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.neutral(0.08)))
                    .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("credential-\(credential.id)")
                .contextMenu {
                    Button(appLocalized("Edit")) {
                        route = .editor(template: .custom, credentialID: credential.id)
                    }
                    .accessibilityIdentifier("credential-list-edit-\(credential.id)")
                    Button(appLocalized("Delete"), role: .destructive) {
                        selectedCredentialID = credential.id
                        deletingCredential = credential
                    }
                    .accessibilityIdentifier("credential-list-delete-\(credential.id)")
                }
            }
        }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 28)
    }

    private func credentialTag(_ text: String, accent: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(accent ? Theme.brand : Theme.textMuted)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(accent ? Theme.brand.opacity(0.11) : Theme.neutral(0.055), in: .rect(cornerRadius: 5))
    }

    private func inlineWarning(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("⚠︎").foregroundStyle(Theme.amber)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.amber.opacity(0.10), in: .rect(cornerRadius: 9))
    }

    @ViewBuilder
    private var credentialInspector: some View {
        if let credential = filteredCredentials.first(where: { $0.id == selectedCredentialID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(credential.name)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Theme.text)
                            Text(appLocalizedFormat("%lld items are delivered together after one approval.", max(credential.components.count, 1)))
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        if deletingCredential?.id == credential.id {
                            Button(FrozenDangerActions.credentialConfirmationTitle, role: .destructive) {
                                vault.deleteTextCredential(credential)
                                deletingCredential = nil
                                selectedCredentialID = nil
                            }
                            .buttonStyle(FrozenDangerButtonStyle())
                            .accessibilityIdentifier("credential-delete-confirm-\(credential.id)")
                            Button(appLocalized("Keep")) { deletingCredential = nil }
                        } else {
                            Button(appLocalized("Edit")) {
                                route = .editor(template: .custom, credentialID: credential.id)
                            }
                            .accessibilityIdentifier("credential-edit-\(credential.id)")
                            Button(appLocalized("Delete…"), role: .destructive) { deletingCredential = credential }
                                .foregroundStyle(Theme.red)
                                .tint(Theme.red)
                                .accessibilityIdentifier("credential-delete-\(credential.id)")
                        }
                    }

                    if deletingCredential?.id == credential.id {
                        inlineWarning(appLocalized("Deleted credentials remain recoverable in the Recycle Bin for 30 days. Permanent deletion is available only there."))
                    }

                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(FrozenCredentialDetailCopy.protectionTitle)
                                .font(.system(size: 13.5, weight: .semibold))
                            Text(FrozenCredentialDetailCopy.protectionMessage)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        Button(
                            vault.revealedCredential?.id == credential.id
                                ? appLocalized("Hide Plaintext")
                                : appLocalized("Authenticate and Reveal")
                        ) {
                            Task { @MainActor in
                                if vault.revealedCredential?.id == credential.id {
                                    vault.revealedCredential = nil
                                } else {
                                    _ = await vault.revealTextCredential(credential)
                                }
                            }
                        }
                        .buttonStyle(FrozenPrimaryButtonStyle())
                        if credential.payloadKind != .bundle {
                            Button(appLocalized("Authenticate and Copy")) {
                                vault.copyTextCredentialValue(credential)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(14)
                    .background(Theme.panelBackground, in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.neutral(0.08)))
                    .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)

                    VStack(alignment: .leading, spacing: 0) {
                        if credential.payloadKind == .bundle {
                            ForEach(credential.components, id: \.name) { component in
                                HStack {
                                    Text(CredentialTemplate.fieldTitle(for: component.name))
                                        .font(.system(size: 12.5, weight: .semibold))
                                    Spacer()
                                    Text(componentDisplayValue(component, credentialID: credential.id))
                                        .font(.system(size: 12.5, design: .monospaced))
                                        .foregroundStyle(Theme.textMuted)
                                    Button(appLocalized("Copy")) {
                                        vault.copyCredentialComponent(
                                            credential,
                                            componentName: component.name
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.brand)
                                    credentialTag(componentDisplayKind(component))
                                }
                                .padding(12)
                                .overlay(alignment: .top) { Divider() }
                            }
                        } else {
                            HStack {
                                Text(credential.payloadKind == .file ? appLocalized("File") : appLocalized("Value"))
                                    .font(.system(size: 12.5, weight: .semibold))
                                Spacer()
                                Text(vault.revealedCredential?.id == credential.id ? appLocalized("Revealed") : "••••••••")
                                    .font(.system(size: 12.5, design: .monospaced))
                            }
                            .padding(12)
                        }
                    }
                    .background(Theme.panelBackground, in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.neutral(0.08)))
                    .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(appLocalized("Group"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textDim)
                            Spacer()
                            Picker(appLocalized("Group"), selection: Binding(
                                get: { credential.groupName ?? "" },
                                set: { vault.moveCredential(credential, toGroup: $0.isEmpty ? nil : $0) }
                            )) {
                                Text(appLocalized("Ungrouped")).tag("")
                                ForEach(vault.credentialGroups, id: \.self) { group in
                                    Text(group).tag(group)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 180)
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let _ = allowanceRefresh
                            if let deadline = vault.timedAllowanceDeadline(for: credential.id),
                               deadline > context.date {
                                HStack {
                                    Text(appLocalized("Timed allow remaining ") + FrozenCountdown.format(deadline: deadline, now: context.date))
                                        .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                                    Spacer()
                                    Button(appLocalized("Revoke Now")) {
                                        _ = vault.revokeTimedAllowance(for: credential.id)
                                        allowanceRefresh += 1
                                    }
                                    .accessibilityIdentifier("credential-revoke-timed-allowance")
                                }
                            }
                        }
                        Text(appLocalized("Agent Permission"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textDim)
                        FrozenSegmentedControl(
                            options: CredentialPermission.prototypeCases.map { ($0, $0.prototypeTitle) },
                            selection: Binding(
                                get: { credential.permission },
                                set: { vault.updateCredentialPermission(credential, permission: $0) }
                            )
                        )
                    }
                    .padding(14)
                    .background(Theme.panelBackground, in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.neutral(0.08)))
                    .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)

                    if !credential.usageInstructions.isEmpty {
                        labeled(appLocalized("Instructions for Agent"), credential.usageInstructions)
                    }

                    if vault.revealedCredential?.id == credential.id,
                       credential.payloadKind != .bundle {
                        if credential.payloadKind == .file {
                            revealedFileBody(vault.revealedCredential?.fileBytes)
                        } else if let value = vault.revealedCredential?.value {
                            Text(value)
                                .font(.system(size: 13, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.neutral(0.06), in: .rect(cornerRadius: 8))
                        }
                    }
                }
                .padding(28)
            }
        } else {
            VStack {
                Spacer()
                Text(appLocalized("Select a credential"))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func componentDisplayValue(
        _ component: ManagedCredentialComponent,
        credentialID: String
    ) -> String {
        guard vault.revealedCredential?.id == credentialID,
              let revealed = vault.revealedCredential?.components.first(where: {
                  $0.name == component.name
              }) else { return "••••••••" }
        switch revealed.value {
        case .text(let value): return value
        case .file(let filename, let bytes):
            return "\(filename) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes.count), countStyle: .file))"
        case nil: return appLocalized("Unavailable")
        }
    }

    private func componentDisplayKind(_ component: ManagedCredentialComponent) -> String {
        guard let revealed = vault.revealedCredential?.components.first(where: {
            $0.name == component.name
        }) else {
            return FrozenCredentialDetailCopy.kindLabel(
                componentName: component.name,
                kind: component.kind
            )
        }
        switch revealed.value {
        case .text: return appLocalized("Text")
        case .file: return appLocalized("File")
        case nil: return appLocalized("Protected")
        }
    }

    @ViewBuilder
    private func revealedFileBody(_ bytes: Data?) -> some View {
        if let bytes, let text = String(data: bytes, encoding: .utf8) {
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.neutral(0.06), in: .rect(cornerRadius: 8))
        } else {
            Text(appLocalized("Binary file"))
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.neutral(0.06), in: .rect(cornerRadius: 8))
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textDim)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
        }
    }

}

enum FrozenCredentialDetailCopy {
    static var protectionTitle: String { appLocalized("Plaintext Protection") }
    static var protectionMessage: String { appLocalized("Even while management is unlocked, revealing or copying plaintext requires authentication. Copied content clears after 60 seconds.") }

    static func kindLabel(
        componentName: String,
        kind: CredentialPayloadKind = .text
    ) -> String {
        if kind == .file { return appLocalized("File") }
        switch componentName {
        case "API_KEY", "ISSUER_ID", "KEY_ID", "TEAM_ID", "SSH_PASSPHRASE",
             "ACCESS_KEY_ID", "SECRET_ACCESS_KEY", "SESSION_TOKEN", "DB_PASSWORD":
            return appLocalized("Protected")
        default:
            return appLocalized("Text")
        }
    }
}

struct FrozenTemplateChooserPage: View {
    let onBack: () -> Void
    let onSelect: (CredentialTemplate) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button(appLocalized("← Back"), action: onBack)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.brand)
                    .font(.system(size: 12.5, weight: .medium))
                Text(appLocalized("What do you want to save?"))
                    .font(.system(size: 20, weight: .bold))
                    .padding(.top, 16)
                Text(appLocalized("Choose the closest template. You can add or remove items later."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, 4)
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
                    ForEach(CredentialTemplate.allCases, id: \.self) { template in
                        Button { onSelect(template) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(template.prototypeTitle)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                Text(template.prototypeDescription)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                            .padding(14)
                            .background(Theme.panelBackground, in: .rect(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.neutral(0.08)))
                            .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 20)
            }
            .padding(28)
        }
        .background(Theme.windowBackground)
    }
}

struct FrozenFileImportPage: View {
    let group: String?
    let onCancel: () -> Void
    let onSaved: () -> Void
    let onReplaced: (String) -> Void

    @Environment(VaultViewModel.self) private var vault
    @State private var source = ""
    @State private var name = appLocalized("Imported Environment Variables")
    @State private var preview: [(name: String, value: String)] = []
    @State private var importedFile: FileImport.FrozenFile?
    @State private var conflictChoice = FrozenImportConflictChoice.skip

    init(
        group: String?,
        previewValues: [(name: String, value: String)] = [],
        onCancel: @escaping () -> Void,
        onSaved: @escaping () -> Void,
        onReplaced: ((String) -> Void)? = nil
    ) {
        self.group = group
        self.onCancel = onCancel
        self.onSaved = onSaved
        self.onReplaced = onReplaced ?? { _ in onSaved() }
        _preview = State(initialValue: previewValues)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button(appLocalized("← Back"), action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.brand)
                VStack(alignment: .leading, spacing: 4) {
                    Text(appLocalized("Import from File")).font(.system(size: 20, weight: .bold))
                    Text(appLocalized("Supports regular files and .env files. The original is never modified."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                }

                if preview.isEmpty, importedFile == nil {
                    prototypeCard {
                        Text(appLocalized(".env File")).font(.system(size: 14, weight: .semibold))
                        Text(appLocalized("Paste .env content below or choose a file. Multiple keys become items in one credential."))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                        TextEditor(text: $source)
                            .font(.system(size: 12.5, design: .monospaced))
                            .frame(minHeight: 120)
                            .padding(6)
                            .background(Theme.neutral(0.045), in: .rect(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.neutral(0.08)))
                        HStack {
                            Button(appLocalized("Parse and Preview")) { parseSource() }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.brand)
                                .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button(appLocalized("Choose File…")) { chooseFile() }
                        }
                    }
                } else {
                    prototypeCard {
                        Text(appLocalized("Import Preview")).font(.system(size: 14, weight: .semibold))
                        Text(importedFile == nil
                             ? FrozenImportCopy.previewSummary(
                                itemCount: preview.count,
                                skippedLineCount: skippedLineCount
                             )
                             : appLocalized("Contains 1 file. The original remains unchanged."))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                        TextField(appLocalized("Credential Name"), text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    let conflict = FrozenImportConflictPresentation(
                        existingName: existingCredential?.name,
                        choice: conflictChoice
                    )
                    if let warning = conflict.warning {
                        HStack(alignment: .top, spacing: 10) {
                            Text("⚠︎").foregroundStyle(Theme.amber)
                            Text(warning)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textMuted)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.amber.opacity(0.10), in: .rect(cornerRadius: 9))
                        FrozenSegmentedControl(
                            options: Array(zip(FrozenImportConflictChoice.allCases, conflict.choices)),
                            selection: $conflictChoice
                        )
                    }
                    VStack(spacing: 0) {
                        FrozenImportTableLayout {
                            Text(appLocalized("Key"))
                            Text(appLocalized("Value"))
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                        .padding(10)
                        if let importedFile {
                            FrozenImportTableLayout {
                                Text(appLocalized("File")).font(.system(size: 12.5, weight: .semibold))
                                Text("\(importedFile.originalFilename) · \(ByteCountFormatter.string(fromByteCount: Int64(importedFile.byteSize), countStyle: .file))")
                                    .font(.system(size: 12.5))
                            }
                            .padding(10)
                            .overlay(alignment: .top) { Divider() }
                        } else {
                        ForEach(Array(preview.enumerated()), id: \.offset) { _, item in
                            FrozenImportTableLayout {
                                Text(item.name).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                FrozenImportedValue(value: item.value)
                            }
                            .padding(10)
                            .overlay(alignment: .top) { Divider() }
                        }
                        }
                    }
                    .background(Theme.panelBackground, in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.neutral(0.08)))
                    .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
                    HStack {
                        Spacer()
                        Button(appLocalized("Back to Edit")) { preview = []; importedFile = nil }
                        Button(conflict.confirmTitle) { save() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.brand)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(28)
        }
        .background(Theme.windowBackground)
    }

    private func prototypeCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .background(Theme.panelBackground, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.neutral(0.08)))
            .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
    }

    private func parseSource() {
        do {
            preview = try FrozenEnvImport.parse(source)
            if preview.isEmpty {
                vault.errorMessage = appLocalized("The .env file contains no key-value pairs.")
            }
        } catch {
            preview = []
            vault.errorMessage = FrozenEnvImport.errorMessage(error)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if url.lastPathComponent == ".env" || url.pathExtension.lowercased() == "env" {
                let imported = try FrozenEnvImport.load(url: url)
                source = imported.text
                if name == "导入的环境变量" { name = url.deletingPathExtension().lastPathComponent }
                preview = imported.pairs
                if preview.isEmpty {
                    vault.errorMessage = appLocalized("The .env file contains no key-value pairs.")
                }
            } else {
                importedFile = try FileImport.freeze(url: url)
                name = url.lastPathComponent
            }
        } catch {
            vault.errorMessage = FrozenEnvImport.errorMessage(error)
        }
    }

    private func save() {
        let components: [CredentialComponentInput]
        if let importedFile {
            components = [FrozenFileImportMapping.component(from: importedFile)]
        } else {
            components = preview.map { .init(name: $0.name, value: .text($0.value)) }
        }
        let input = BundleCredentialInput(
            name: name,
            components: components,
            groupName: group,
            permission: .ask
        )
        if let existingCredential {
            switch conflictChoice {
            case .skip:
                onSaved()
            case .replace:
                Task {
                    if await vault.replaceImportedBundleCredential(
                        id: existingCredential.id,
                        components: components
                    ) {
                        onReplaced(existingCredential.id)
                    }
                }
            }
            return
        }
        if vault.addBundleCredential(input) { onSaved() }
    }

    private var existingCredential: ManagedTextCredential? {
        let candidate = normalizedCredentialName(name)
        return vault.credentials.first {
            normalizedCredentialName($0.name) == candidate
        }
    }

    private var skippedLineCount: Int {
        guard !source.isEmpty else { return 0 }
        return source.components(separatedBy: .newlines).filter {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    private func normalizedCredentialName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}

enum FrozenImportCopy {
    static func previewSummary(itemCount: Int, skippedLineCount: Int) -> String {
        appLocalizedFormat("Contains %lld items; skipped %lld blank lines.", itemCount, skippedLineCount)
    }
}

enum FrozenFileImportMapping {
    static func component(from file: FileImport.FrozenFile) -> CredentialComponentInput {
        .init(
            name: "FILE",
            value: .file(filename: file.originalFilename, bytes: file.bytes)
        )
    }
}

enum FrozenImportConflictChoice: CaseIterable, Equatable {
    case skip
    case replace
}

struct FrozenImportConflictPresentation: Equatable {
    static let showsValues = true

    let warning: String?
    let choices: [String]
    let selectedChoice: FrozenImportConflictChoice
    let confirmTitle: String

    init(existingName: String?, choice: FrozenImportConflictChoice) {
        warning = existingName.map {
            appLocalizedFormat("A credential named “%@” already exists. Choose for the whole credential: skip it, or authenticate to replace it with the imported content.", $0)
        }
        choices = existingName == nil ? [] : [appLocalized("Skip"), appLocalized("Authenticate and Replace")]
        selectedChoice = choice
        confirmTitle = existingName != nil && choice == .skip
            ? appLocalized("Skip and Finish")
            : appLocalized("Confirm Import")
    }

    init(
        warning: String?,
        choices: [String],
        selectedChoice: FrozenImportConflictChoice,
        confirmTitle: String
    ) {
        self.warning = warning
        self.choices = choices
        self.selectedChoice = selectedChoice
        self.confirmTitle = confirmTitle
    }
}

struct FrozenSettingsPage: View {
    @Environment(VaultViewModel.self) private var vault
    @State private var showingErase = false
    @State private var eraseWord = ""
    @State private var confirmingReadAuthenticationDisable = false
    @State private var settingsScrollTarget: String?
    @State private var confirmingAccessRecordClear = false

    init(
        initialReadAuthenticationConfirmation: Bool = false,
        initialEraseConfirmation: Bool = false,
        initialAccessRecordClearConfirmation: Bool = false
    ) {
        _confirmingReadAuthenticationDisable = State(
            initialValue: initialReadAuthenticationConfirmation
        )
        _showingErase = State(initialValue: initialEraseConfirmation)
        _eraseWord = State(initialValue: FrozenEraseConfirmationPresentation.initialText)
        _confirmingAccessRecordClear = State(initialValue: initialAccessRecordClearConfirmation)
        _settingsScrollTarget = State(initialValue: initialEraseConfirmation
            ? "settings-erase"
            : nil)
    }

    var body: some View {
        let _ = AppLanguage.store.resolved
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appLocalized("Settings")).font(.system(size: 20, weight: .bold))
                    Text(appLocalized("Tighter security applies immediately. Relaxing it explains the impact and verifies you first."))
                        .font(.system(size: 12.5)).foregroundStyle(Theme.textMuted)
                }
                settingCard(appLocalized("Agent Access"), vault.isAgentAccessPaused ? appLocalized("Paused: new requests and temporary deliveries are stopped.") : appLocalized("Running: Agents can request credentials according to each permission.")) {
                    Button(vault.isAgentAccessPaused ? appLocalized("Resume Agent Access") : appLocalized("Pause Agent Access")) {
                        Task { vault.isAgentAccessPaused ? await vault.resumeAgentAccess() : await vault.pauseAgentAccess() }
                    }
                    .foregroundStyle(vault.isAgentAccessPaused ? Theme.brand : Theme.red)
                    .tint(vault.isAgentAccessPaused ? Theme.brand : Theme.red)
                }
                let readAuthentication = FrozenReadAuthenticationPresentation(
                    enabled: vault.readApprovalAuthenticationEnabled,
                    confirmingDisable: confirmingReadAuthenticationDisable
                )
                settingCard(appLocalized("Require System Authentication for Reads"), appLocalized("On by default. After Allow, Touch ID confirms it is really you.")) {
                    Button(readAuthentication.actionTitle) {
                        if vault.readApprovalAuthenticationEnabled {
                            confirmingReadAuthenticationDisable = true
                        } else {
                            vault.readApprovalAuthenticationEnabled = true
                        }
                    }
                    .accessibilityIdentifier("settings-read-auth-action")
                }
                if let warning = readAuthentication.warning,
                   let confirmationTitle = readAuthentication.confirmationTitle {
                    HStack(alignment: .top, spacing: 10) {
                        Text("⚠︎").foregroundStyle(Theme.amber)
                        Text(warning)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textMuted)
                        Spacer()
                        Button(confirmationTitle, role: .destructive) {
                            Task {
                                guard await vault.confirmDeviceOwner(
                                    reason: ManagementAuthenticationAction.disableReadAuthentication.reasonKey
                                ) != nil else { return }
                                vault.readApprovalAuthenticationEnabled = false
                                confirmingReadAuthenticationDisable = false
                            }
                        }
                        Button(appLocalized("Cancel")) { confirmingReadAuthenticationDisable = false }
                    }
                    .padding(12)
                    .background(Theme.amber.opacity(0.10), in: .rect(cornerRadius: 9))
                }
                settingCard(
                    appLocalized("Default Timed Allow"),
                    FrozenTimedAllowanceSettingsPresentation.help(
                        minutes: vault.defaultTimedAllowanceMinutes
                    )
                ) {
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { vault.timedAllowanceEnabled },
                            set: { vault.timedAllowanceEnabled = $0 }
                        )).labelsHidden().toggleStyle(.switch).tint(Theme.mint)
                        if vault.timedAllowanceEnabled {
                            Picker("", selection: Binding(
                                get: {
                                    FrozenTimedAllowanceSettingsPresentation.sanitized(
                                        vault.defaultTimedAllowanceMinutes
                                    )
                                },
                                set: { vault.defaultTimedAllowanceMinutes = $0 }
                            )) {
                                ForEach(
                                    FrozenTimedAllowanceSettingsPresentation.menuChoices(
                                        current: vault.defaultTimedAllowanceMinutes
                                    ),
                                    id: \.self
                                ) { minutes in
                                    Text(FrozenTimedAllowanceSettingsPresentation.title(minutes))
                                        .tag(minutes)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 128)
                            .accessibilityIdentifier("settings-timed-allow-minutes")
                        }
                    }
                }
                settingCard(
                    appLocalized("Global Shortcut"),
                    appLocalized("Opens the Ask Key menu. Choose Off to release the system shortcut.")
                ) {
                    Picker("", selection: Binding(
                        get: { vault.hotkeyShortcutID },
                        set: { vault.hotkeyShortcutID = $0 }
                    )) {
                        ForEach(GlobalHotkeyManager.Shortcut.allOptions, id: \.id) { option in
                            Text(option.localizedName).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 128)
                    .accessibilityIdentifier("settings-hotkey-shortcut")
                }
                settingCard(appLocalized("Launch at Login"), appLocalized("Agents cannot use credentials while Ask Key is not running.")) {
                    Toggle("", isOn: Binding(get: { vault.launchAtLogin }, set: { vault.launchAtLogin = $0 }))
                        .labelsHidden().toggleStyle(.switch).tint(Theme.mint)
                }
                if let warning = FrozenLoginAtStartupPresentation(
                    isEnabled: vault.launchAtLogin
                ).warning {
                    HStack(alignment: .top, spacing: 10) {
                        Text("⚠︎").foregroundStyle(Theme.amber)
                        Text(warning)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.amber.opacity(0.10), in: .rect(cornerRadius: 9))
                }
                settingCard(appLocalized("Access Records"), appLocalizedFormat("Keeps 90 days of events, never credential contents; %lld records now.", vault.credentialAccessRecords.count)) {
                    if confirmingAccessRecordClear {
                        Button(FrozenDangerActions.recordsConfirmationTitle, role: .destructive) {
                            confirmingAccessRecordClear = false
                            Task { await vault.clearCredentialAccessRecords() }
                        }
                        .buttonStyle(FrozenDangerButtonStyle())
                        Button(appLocalized("Keep")) { confirmingAccessRecordClear = false }
                    } else {
                        Button(appLocalized("Clear Records…"), role: .destructive) {
                            confirmingAccessRecordClear = true
                        }
                        .foregroundStyle(Theme.red)
                        .tint(Theme.red)
                        .disabled(vault.credentialAccessRecords.isEmpty)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(appLocalized("General")).font(.system(size: 13.5, weight: .semibold))
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(appLocalized("Language")).font(.system(size: 12.5, weight: .semibold))
                            Text(appLocalized("The interface language changes immediately."))
                                .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        FrozenSegmentedControl(
                            options: Array(zip(
                                ["system", "zh-Hans", "en"],
                                FrozenSettingsContract.languageOptions
                            )),
                            selection: Binding(
                                get: { vault.languageMode },
                                set: { vault.languageMode = $0 }
                            )
                        )
                        .frame(width: 360)
                    }
                }
                .padding(14)
                .background(Theme.panelBackground, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.neutral(0.08)))
                .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(appLocalized("Erase Local Data")).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.red)
                            Text(appLocalized("Deletes all local credentials, groups, and records. Uninstalling Ask Key does not do this."))
                                .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        Button(appLocalized("Erase…"), role: .destructive) { showingErase = true }
                    }
                    if showingErase {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text(FrozenEraseConfirmationPresentation.label)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Theme.textMuted)
                            TextField(FrozenEraseConfirmationPresentation.placeholder, text: $eraseWord)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Spacer()
                            Button(appLocalized("Cancel")) {
                                showingErase = false
                                eraseWord = ""
                            }
                            Button(appLocalized("Authenticate and Erase"), role: .destructive) {
                                Task {
                                    _ = await vault.eraseLocalLibrary(
                                        confirmation: eraseWord
                                    )
                                }
                            }
                            .disabled(
                                !FrozenEraseConfirmationPresentation.accepts(eraseWord)
                            )
                        }
                    }
                }
                .padding(14)
                .background(Theme.panelBackground, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.red.opacity(0.3)))
                .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
                .id("settings-erase")
            }
            .padding(28)
        }
        .scrollPosition(id: $settingsScrollTarget, anchor: .center)
        .background(Theme.windowBackground)
        .onAppear {
            vault.reloadCredentialAccessRecords()
        }
    }

    private func settingCard<Action: View>(
        _ title: String,
        _ message: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(message).font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
            }
            Spacer()
            action()
        }
        .padding(14)
        .background(Theme.panelBackground, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.neutral(0.08)))
        .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
    }


}

struct CredentialComponentDraft: Identifiable {
    enum EmptyValuePolicy {
        case reject
        case omitWhenNameIs(String)
    }

    let id = UUID()
    var name = ""
    var kind: CredentialPayloadKind = .text
    var isSecret = false
    var isRemovable = true
    var text = ""
    var file: FileImport.FrozenFile?
    var isOptional = false
    var emptyValuePolicy = EmptyValuePolicy.reject
    var delivery: CredentialComponentDelivery?
    var masked = true
}

enum CredentialEditorComponentLoader {
    static func load(
        _ components: [ManagedCredentialComponent],
        template: CredentialTemplate = .custom
    ) throws -> [CredentialComponentDraft] {
        let inputs = try components.map { component -> CredentialComponentInput in
            guard let value = component.value else { throw VaultError.credentialUnavailable }
            return CredentialComponentInput(name: component.name, value: value, delivery: component.delivery, masked: component.masked)
        }
        return try CredentialBundleValidator.validatedComponents(inputs).map { component in
            var draft = template.components.first(where: { $0.name == component.name })
                ?? CredentialComponentDraft(name: component.name)
            draft.delivery = component.delivery
            draft.masked = component.masked
            switch component.value {
            case .text(let text):
                draft.text = text
            case .file(let filename, let bytes):
                draft.kind = .file
                draft.file = try FileImport.FrozenFile(originalFilename: filename, bytes: bytes)
            }
            return draft
        }
    }
}

enum CredentialEditorComponentValidation {
    static func canSave(_ components: [CredentialComponentDraft]) -> Bool {
        let retained = components.filter { !isOmittable($0) }
        return !retained.isEmpty && retained.allSatisfy(isComplete)
    }

    static func inputs(_ components: [CredentialComponentDraft]) -> [CredentialComponentInput]? {
        guard canSave(components) else { return nil }
        var inputs: [CredentialComponentInput] = []
        for component in components where !isOmittable(component) {
            let name = component.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if component.kind == .file {
                guard let file = component.file else { return nil }
                inputs.append(.init(
                    name: name,
                    value: .file(filename: file.originalFilename, bytes: file.bytes),
                    delivery: component.delivery ?? .temporaryFile(name),
                    masked: component.masked
                ))
            } else {
                inputs.append(.init(name: name, value: .text(component.text), delivery: component.delivery ?? .environmentVariable(name), masked: component.masked))
            }
        }
        return inputs
    }

    private static func isComplete(_ component: CredentialComponentDraft) -> Bool {
        !component.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (component.kind == .file ? component.file != nil : !component.text.isEmpty)
    }

    private static func isEmpty(_ component: CredentialComponentDraft) -> Bool {
        component.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && component.text.isEmpty
            && component.file == nil
    }

    private static func isOmittable(_ component: CredentialComponentDraft) -> Bool {
        if isEmpty(component) { return true }
        guard case .omitWhenNameIs(let expectedName) = component.emptyValuePolicy else {
            return false
        }
        return component.name.trimmingCharacters(in: .whitespacesAndNewlines) == expectedName
            && component.text.isEmpty
            && component.file == nil
    }
}

enum CredentialTemplate: String, CaseIterable {
    case api, githubApp, apple, ssh, cloud, database, custom

    var prototypeTitle: String {
        switch self {
        case .api: return appLocalized("API Access Credential")
        case .githubApp: return appLocalized("GitHub App")
        case .apple: return appLocalized("Apple Signing")
        case .ssh: return appLocalized("SSH Identity")
        case .cloud: return appLocalized("Cloud Account")
        case .database: return appLocalized("Database or Service Connection")
        case .custom: return appLocalized("Custom Credential")
        }
    }

    var prototypeDescription: String {
        switch self {
        case .api: return appLocalized("Access key and optional API endpoint")
        case .githubApp: return appLocalized("App ID, client secret, and private key file")
        case .apple: return appLocalized("For App Store Connect and automated signing")
        case .ssh: return appLocalized("Connect to servers or deploy code")
        case .cloud: return appLocalized("Access cloud platforms, storage, or CLIs")
        case .database: return appLocalized("Server, account, and password as one set")
        case .custom: return appLocalized("Add text or file values with keys, like .env")
        }
    }

    var label: String {
        switch self {
        case .custom: return appLocalized("Custom credential")
        case .api: return appLocalized("API credential")
        case .githubApp: return appLocalized("GitHub App")
        case .apple: return appLocalized("Apple signing")
        case .ssh: return appLocalized("SSH identity")
        case .cloud: return appLocalized("Cloud account")
        case .database: return appLocalized("Database connection")
        }
    }

    var components: [CredentialComponentDraft] {
        switch self {
        case .custom:
            return [CredentialComponentDraft(), CredentialComponentDraft(isOptional: true)]
        case .api:
            return [
                CredentialComponentDraft(name: "API_KEY", isSecret: true, isRemovable: false),
                CredentialComponentDraft(
                    name: "API_ENDPOINT",
                    isOptional: true,
                    emptyValuePolicy: .omitWhenNameIs("API_ENDPOINT")
                ),
            ]
        case .githubApp:
            return [
                CredentialComponentDraft(name: "GITHUB_APP_ID", isRemovable: false),
                CredentialComponentDraft(name: "GITHUB_CLIENT_ID"),
                CredentialComponentDraft(name: "GITHUB_CLIENT_SECRET", isSecret: true),
                CredentialComponentDraft(name: "GITHUB_PRIVATE_KEY", kind: .file),
                CredentialComponentDraft(
                    name: "GITHUB_INSTALLATION_ID",
                    isOptional: true,
                    emptyValuePolicy: .omitWhenNameIs("GITHUB_INSTALLATION_ID")
                ),
            ]
        case .apple:
            return [
                CredentialComponentDraft(name: "ISSUER_ID"),
                CredentialComponentDraft(name: "KEY_ID"),
                CredentialComponentDraft(name: "TEAM_ID"),
                CredentialComponentDraft(name: "PRIVATE_KEY_FILE", kind: .file),
            ]
        case .ssh:
            return [
                CredentialComponentDraft(name: "SSH_HOST"),
                CredentialComponentDraft(name: "SSH_USER"),
                CredentialComponentDraft(name: "SSH_PRIVATE_KEY", kind: .file),
                CredentialComponentDraft(name: "SSH_PASSPHRASE", isSecret: true, isOptional: true, emptyValuePolicy: .omitWhenNameIs("SSH_PASSPHRASE")),
            ]
        case .cloud:
            return [
                CredentialComponentDraft(name: "ACCESS_KEY_ID", isSecret: true),
                CredentialComponentDraft(name: "SECRET_ACCESS_KEY", isSecret: true),
                CredentialComponentDraft(name: "SESSION_TOKEN", isSecret: true, isOptional: true, emptyValuePolicy: .omitWhenNameIs("SESSION_TOKEN")),
                CredentialComponentDraft(name: "REGION", isOptional: true, emptyValuePolicy: .omitWhenNameIs("REGION")),
            ]
        case .database:
            return [
                CredentialComponentDraft(name: "DB_HOST"),
                CredentialComponentDraft(name: "DB_PORT"),
                CredentialComponentDraft(name: "DB_USER"),
                CredentialComponentDraft(name: "DB_PASSWORD", isSecret: true),
                CredentialComponentDraft(name: "DB_CERT", kind: .file, isOptional: true, emptyValuePolicy: .omitWhenNameIs("DB_CERT")),
            ]
        }
    }

    static func fieldTitle(for storageName: String) -> String {
        switch storageName {
        case "API_KEY": return appLocalized("Access Key")
        case "API_ENDPOINT": return appLocalized("API Endpoint")
        case "ISSUER_ID": return "Issuer ID"
        case "KEY_ID": return "Key ID"
        case "TEAM_ID": return "Team ID"
        case "GITHUB_APP_ID": return "App ID"
        case "GITHUB_CLIENT_ID": return "Client ID"
        case "GITHUB_CLIENT_SECRET": return appLocalized("Client Secret")
        case "GITHUB_INSTALLATION_ID": return appLocalized("Installation ID")
        case "PRIVATE_KEY_FILE", "SSH_PRIVATE_KEY", "GITHUB_PRIVATE_KEY": return appLocalized("Private Key File")
        case "SSH_HOST", "DB_HOST": return appLocalized("Server Address")
        case "SSH_USER", "DB_USER": return appLocalized("Username")
        case "SSH_PASSPHRASE": return appLocalized("Private Key Passphrase")
        case "ACCESS_KEY_ID": return appLocalized("Access Key ID")
        case "SECRET_ACCESS_KEY": return appLocalized("Secret Access Key")
        case "SESSION_TOKEN": return appLocalized("Session Token")
        case "REGION": return appLocalized("Region")
        case "DB_PORT": return appLocalized("Port")
        case "DB_PASSWORD": return appLocalized("Password")
        case "DB_CERT": return appLocalized("Certificate File")
        case "FILE", "文件": return appLocalized("File")
        default: return storageName
        }
    }
}

extension CredentialPermission {
    static let prototypeCases: [CredentialPermission] = [.ask, .allowed, .hidden]

    var prototypeTitle: String {
        switch self {
        case .allowed: return appLocalized("Always Allow")
        case .ask: return appLocalized("Ask Every Time (Recommended)")
        case .hidden: return appLocalized("Do Not Allow Agent")
        }
    }
}

enum FrozenCountdown {
    static func format(deadline: Date?, now: Date) -> String {
        guard let deadline else { return "--:--" }
        let remaining = max(0, Int(deadline.timeIntervalSince(now).rounded(.down)))
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}

private struct CredentialEditorUnavailablePage: View {
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "trash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textDim)
            Text(appLocalized("This Credential Is Unavailable"))
                .font(.system(size: 20, weight: .semibold))
            Text(appLocalized("This credential was deleted or changed. Editing and saving are no longer available."))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button(appLocalized("Back to Library"), action: onBack)
                .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLocalized("This Credential Is Unavailable"))
    }
}

struct WorkspaceEmptyState: View {
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textDim)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum RecycleBinPresentation {
    static func credentialMarker(name: String) -> String {
        name.first.map(String.init) ?? "凭"
    }

    static func remainingDaysCopy(deletedAt: Date?, now: Date) -> String {
        guard let deletedAt else { return appLocalized("Days remaining unknown") }
        let purgeDate = deletedAt.addingTimeInterval(30 * 24 * 60 * 60)
        let days = max(0, Int(ceil(purgeDate.timeIntervalSince(now) / (24 * 60 * 60))))
        return appLocalizedFormat("%lld days remaining", days)
    }
}

enum FrozenDangerActions {
    static var initialTitles: [String] { [
        appLocalized("Delete Group…"), appLocalized("Delete Permanently…"), appLocalized("Delete…"), appLocalized("Pause Agent Access"), appLocalized("Clear Records…"),
    ] }
    static var groupConfirmationTitle: String { appLocalized("Confirm Group Deletion") }
    static var credentialConfirmationTitle: String { appLocalized("Move to Recycle Bin") }
    static var recordsConfirmationTitle: String { appLocalized("Confirm Clear") }
    static var permanentCredentialConfirmationTitle: String {
        appLocalized("Confirm Permanent Deletion")
    }
    static var confirmationTitles: [String] { [
        groupConfirmationTitle, credentialConfirmationTitle, recordsConfirmationTitle,
    ] }
}

enum FrozenAccessRecordsCopy {
    static var subtitle: String { appLocalized("Keeps 90 days. Records who requested what and the outcome, never credential contents. Clear it manually in Settings.") }
}

enum FrozenPendingRequestsCopy {
    static let simulationActions: [String] = []
}

enum CredentialSearchPresentation {
    static func queryAfterChangingSection(_ query: String) -> String { "" }
}

enum CredentialEmptyPresentation {
    static func title(section: CredentialWorkspaceSection, searchText: String) -> String {
        if !searchText.isEmpty { return appLocalized("No Matching Credentials") }
        switch section {
        case .all: return appLocalized("No credentials yet")
        case .ungrouped: return appLocalized("No ungrouped credentials")
        default: return appLocalized("This group is empty")
        }
    }

    static func message(section: CredentialWorkspaceSection, searchText: String) -> String {
        if !searchText.isEmpty { return appLocalized("Try a different search term.") }
        switch section {
        case .all:
            return appLocalized("Create one, or import from a file / .env. Agents can request it after it is saved.")
        case .ungrouped:
            return appLocalized("All credentials are grouped, or there are no credentials yet.")
        case .named(let name):
            return FrozenCollectionCopy.groupEmptyMessage(group: name)
        default:
            return appLocalized("New credentials created here are added directly to this group.")
        }
    }

    static func action(section: CredentialWorkspaceSection, searchText: String) -> String? {
        guard searchText.isEmpty else { return nil }
        switch section {
        case .all: return FrozenSettingsContract.emptyLibraryAction
        case .named: return appLocalized("New Credential in This Group")
        default: return nil
        }
    }
}

enum FrozenCollectionCopy {
    static var importAction: String { appLocalized("Import from File") }
    static var newCredentialAction: String { appLocalized("New Credential in This Group") }
    static var deleteAction: String { appLocalized("Delete Group…") }
    static var groupActions: [String] { [importAction, newCredentialAction, deleteAction] }
    static var groupSubtitle: String { appLocalized("Groups organize credentials without changing authorization boundaries. New credentials created here join this group.") }
    static var recycleSubtitle: String { appLocalized("Deleted credentials remain for 30 days, then are removed permanently. Agents cannot access the Recycle Bin.") }
    static var recycleEmptyMessage: String { appLocalized("Credentials deleted from details remain here for 30 days.") }

    static func groupEmptyMessage(group: String) -> String {
        appLocalizedFormat("New credentials are added to “%@”. Move existing credentials here from their details.", group)
    }

    static func showsSearch(
        section: CredentialWorkspaceSection,
        hasCredentials: Bool
    ) -> Bool {
        guard hasCredentials else { return false }
        if case .all = section { return true }
        return false
    }
}

struct CredentialListPresentation: Equatable {
    let tags: [String]

    init(credential: ManagedTextCredential) {
        let componentNames = Set(credential.components.map(\.name))
        let template = CredentialTemplate.prototypeTemplate(componentNames: componentNames)
        var tags = [
            template.prototypeTitle,
            appLocalizedFormat("%lld items", max(credential.components.count, 1)),
            credential.permission.prototypeTitle,
        ]
        tags.append(credential.groupName ?? appLocalized("Ungrouped"))
        self.tags = tags
    }
}

extension CredentialTemplate {
    static func prototypeTemplate(componentNames: Set<String>) -> CredentialTemplate {
        for template in [githubApp, apple, ssh, cloud, database, api] {
            let drafts = template.components
            let allowedNames = Set(drafts.map(\.name))
            if let marker = drafts.first?.name,
               componentNames.contains(marker),
               componentNames.isSubset(of: allowedNames) {
                return template
            }
        }
        return custom
    }
}

struct FrozenReadAuthenticationPresentation: Equatable {
    let actionTitle: String
    let warning: String?
    let confirmationTitle: String?

    init(enabled: Bool, confirmingDisable: Bool) {
        actionTitle = enabled
            ? appLocalized("Turn Off…")
            : appLocalized("Turn On Again")
        warning = enabled && confirmingDisable
            ? appLocalized("After turning this off, one click releases Agent read requests without confirming it is you. Credential changes still require authentication.")
            : nil
        confirmationTitle = enabled && confirmingDisable
            ? appLocalized("Turn Off Anyway")
            : nil
    }

    init(actionTitle: String, warning: String?, confirmationTitle: String?) {
        self.actionTitle = actionTitle
        self.warning = warning
        self.confirmationTitle = confirmationTitle
    }
}

struct FrozenSegmentedControl<Selection: Hashable>: View {
    let options: [(Selection, String)]
    @Binding var selection: Selection

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let active = selection == option.0
                Button {
                    selection = option.0
                } label: {
                    HStack(spacing: 4) {
                        if active {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.brand)
                        }
                        Text(option.1)
                            .lineLimit(1)
                    }
                    .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Theme.text : Theme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(active ? Color.white : Color.clear, in: .rect(cornerRadius: 6))
                    .shadow(color: active ? Theme.cardShadow : .clear, radius: 2, x: 0, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.neutral(0.06), in: .rect(cornerRadius: 8))
    }
}

struct FrozenPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.brand.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(.rect(cornerRadius: 7))
    }
}

struct FrozenDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.red.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(.rect(cornerRadius: 7))
    }
}

enum FrozenTimedAllowanceSettingsPresentation {
    static let choices = [15, 30, 60, 120]

    static func sanitized(_ minutes: Int) -> Int {
        if minutes > 0, minutes <= Int.max / 60 { return minutes }
        return 30
    }

    static func menuChoices(current: Int) -> [Int] {
        let value = sanitized(current)
        if choices.contains(value) { return choices }
        return (choices + [value]).sorted()
    }

    static func title(_ minutes: Int) -> String {
        switch minutes {
        case 15: return appLocalized("15 minutes")
        case 30: return appLocalized("30 minutes")
        case 60: return appLocalized("60 minutes")
        case 120: return appLocalized("2 hours")
        default: return appLocalizedFormat("%lld minutes", minutes)
        }
    }

    static func help(minutes: Int) -> String {
        let value = sanitized(minutes)
        return appLocalizedFormat("A %lld-minute allowance applies to all local callers for that credential, then expires. Changing the default does not extend an allowance already granted.", value)
    }
}

enum FrozenHotkeySettingsPresentation {
    static var optionIDs: [String] {
        GlobalHotkeyManager.Shortcut.allOptions.map(\.id)
    }

    static var includesOff: Bool {
        optionIDs.contains("disabled")
    }
}

enum FrozenSettingsContract {
    static var languageOptions: [String] {
        AppLanguage.publishedModes.map { appLocalized(AppLanguage.titleKey(for: $0)) }
    }
    static var agentAccessSubtitle: String { appLocalized("Choose a client. Review how it connects, then decide whether to check or configure.") }
    static var emptyLibraryAction: String { appLocalized("Create First Credential") }

}

enum FrozenEraseConfirmationPresentation {
    static var label: String { appLocalized("Type ERASE to confirm") }
    static var confirmationText: String {
        AppLanguage.current == "zh-Hans"
            ? LocalVaultEraseLanguage.simplifiedChinese.confirmationText
            : LocalVaultEraseLanguage.english.confirmationText
    }
    static var placeholder: String { confirmationText }
    static let initialText = ""

    static func accepts(_ text: String) -> Bool {
        text == confirmationText
    }
}

private enum FrozenClock {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale(for: AppLanguage.current)
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

enum CredentialEditorPresentation {
    static func showsGlobalEnvironmentVariable(
        editingExisting: Bool,
        payloadKind: CredentialPayloadKind
    ) -> Bool {
        editingExisting && payloadKind != .bundle
    }
}

enum CredentialEditorInputVisibility: Equatable {
    case plain
    case secure
}

enum CredentialEditorInteractionPresentation {
    static func inputVisibility(
        template: CredentialTemplate,
        isSecret: Bool,
        isRevealed: Bool
    ) -> CredentialEditorInputVisibility {
        template == .custom || !isSecret || isRevealed ? .plain : .secure
    }
}

enum FrozenEditorCopy {
    struct FieldCard: Equatable {
        let title: String
        let help: String
    }

    static var keyHeader: String { appLocalized("Key") }
    static var valueHeader: String { appLocalized("Value") }
    static var tableHeaders: [String] { [keyHeader, valueHeader] }
    static var customHelp: String { appLocalized("Enter keys and values like .env. Each value can be text or a file.") }
    static var addTextAction: String { appLocalized("Add Text Key") }
    static var addFileAction: String { appLocalized("Add File Key") }
    static var customAddActions: [String] { [addTextAction, addFileAction] }

    static func fieldCard(for component: CredentialComponentDraft) -> FieldCard {
        let title = CredentialTemplate.fieldTitle(for: component.name)
            + (component.isOptional ? appLocalized(" (Optional)") : "")
        let help: String
        switch component.name {
        case "API_KEY": help = appLocalized("The key or token from your provider")
        case "API_ENDPOINT": help = appLocalized("For example https://api.example.com; leave empty or remove if unused")
        default: help = ""
        }
        return .init(title: title, help: help)
    }

    static func kindLabel(for kind: CredentialPayloadKind) -> String {
        kind == .file ? appLocalized("File") : appLocalized("Text")
    }

    static func kindLabel(for component: CredentialComponentDraft) -> String {
        component.kind == .file
            ? appLocalized("File")
            : component.isSecret
                ? appLocalized("Protected")
                : appLocalized("Text")
    }
}

struct FrozenImportTableLayout: Layout {
    static let columnWeights: [CGFloat] = [1, 1.4]
    private let spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == Self.columnWeights.count else { return .zero }
        let width = proposal.width ?? subviews.reduce(spacing) {
            $0 + $1.sizeThatFits(.unspecified).width
        }
        let widths = columnWidths(totalWidth: width)
        let height = zip(subviews, widths).map { subview, width in
            subview.sizeThatFits(.init(width: width, height: proposal.height)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == Self.columnWeights.count else { return }
        let widths = columnWidths(totalWidth: bounds.width)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: .init(width: width, height: bounds.height)
            )
            x += width + spacing
        }
    }

    private func columnWidths(totalWidth: CGFloat) -> [CGFloat] {
        let available = max(0, totalWidth - spacing)
        let totalWeight = Self.columnWeights.reduce(0, +)
        return Self.columnWeights.map { available * $0 / totalWeight }
    }
}

struct CredentialEditorView: View {
    let credential: ManagedTextCredential?
    let onClose: (() -> Void)?

    @Environment(VaultViewModel.self) private var vault
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var value: String
    @State private var usageInstructions: String
    @State private var privateNotes: String
    @State private var groupName: String
    @State private var environmentVariable: String
    @State private var permission: CredentialPermission
    @State private var expiryDateText: String
    @State private var revealed = false
    @State private var revealedComponentIDs: Set<UUID> = []
    @State private var payloadKind: CredentialPayloadKind
    @State private var snapshot: FileImport.FrozenFile?
    @State private var didLoadSecrets = false
    @State private var template = CredentialTemplate.custom
    @State private var components: [CredentialComponentDraft]
    @State private var isEnvImport = false
    @State private var importConflictChoice = FrozenImportConflictChoice.skip
    @State private var moreExpanded = false

    init(
        credential: ManagedTextCredential?,
        preferredKind: CredentialPayloadKind = .text,
        preferredGroup: String? = nil,
        initialTemplate: CredentialTemplate = .custom,
        initialMoreExpanded: Bool = false,
        onClose: (() -> Void)? = nil
    ) {
        self.credential = credential
        self.onClose = onClose
        _name = State(initialValue: credential?.name ?? "")
        _value = State(initialValue: "")
        _usageInstructions = State(initialValue: credential?.usageInstructions ?? "")
        _privateNotes = State(initialValue: "")
        _groupName = State(initialValue: credential?.groupName ?? preferredGroup ?? "")
        _environmentVariable = State(initialValue: credential?.environmentVariable ?? "")
        _moreExpanded = State(initialValue: initialMoreExpanded)
        _permission = State(initialValue: credential?.permission ?? .ask)
        _expiryDateText = State(initialValue: credential?.expiresAt.map(
            FrozenEditorMoreSettingsPresentation.expiryText
        ) ?? "")
        _payloadKind = State(initialValue: credential?.payloadKind ?? preferredKind)
        if let credential, credential.payloadKind == .bundle {
            let inferred = CredentialTemplate.prototypeTemplate(
                componentNames: Set(credential.components.map(\.name))
            )
            _template = State(initialValue: inferred)
            _components = State(initialValue: credential.components.map { component in
                var draft = inferred.components.first(where: { $0.name == component.name })
                    ?? CredentialComponentDraft(name: component.name)
                draft.kind = component.kind
                draft.delivery = component.delivery
                draft.masked = component.masked
                return draft
            })
        } else {
            _template = State(initialValue: initialTemplate)
            _components = State(initialValue: preferredKind == .file
                ? [CredentialComponentDraft(kind: .file), CredentialComponentDraft(isOptional: true)]
                : initialTemplate.components)
        }
    }

    private var isValid: Bool {
        let named = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let expiryIsValid = expiryDateText.isEmpty || parsedExpiryDate != nil
        if credential != nil, !didLoadSecrets {
            return named && expiryIsValid
        }
        if credential == nil || payloadKind == .bundle {
            return named
                && CredentialEditorComponentValidation.canSave(components)
                && (credential == nil || didLoadSecrets)
                && expiryIsValid
        }
        if payloadKind == .file {
            let hasFile = snapshot != nil || credential?.payloadKind == .file
            return named && hasFile && (credential == nil || didLoadSecrets) && expiryIsValid
        }
        return named && !value.isEmpty && expiryIsValid
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button(credential == nil ? appLocalized("← Choose Again") : appLocalized("← Cancel Editing")) { close() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.brand)
                VStack(alignment: .leading, spacing: 4) {
                    Text(credential == nil ? appLocalized("New Credential") : appLocalized("Edit Credential"))
                        .font(.system(size: 20, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Text("\(template.prototypeTitle) · " + appLocalized("Its contents are saved and authorized as one set."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                }
                editorField(appLocalized("Credential Name")) {
                    TextField(appLocalized("For example: Production API"), text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("credential-editor-name")
                }
                editorField(appLocalized("Agent Permission")) { permissionSegments }
                editorField(appLocalized("This Credential Contains")) {
                    if credential != nil, !didLoadSecrets {
                        HStack {
                            Text(appLocalized("Contents stay hidden. Changing the name, group, or permission does not reveal plaintext."))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textMuted)
                            Spacer()
                            Button(appLocalized("Authenticate to Edit Contents")) {
                                Task { await loadExistingSecrets() }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(12)
                        .background(Theme.panelBackground, in: .rect(cornerRadius: 10))
                    } else if credential == nil || payloadKind == .bundle {
                        componentEditor
                    } else if payloadKind == .file {
                        filePicker
                    } else {
                        HStack {
                            if revealed {
                                TextField(appLocalized("Value"), text: $value)
                                    .accessibilityIdentifier("credential-editor-value")
                            } else {
                                SecureField(appLocalized("Value"), text: $value)
                                    .accessibilityIdentifier("credential-editor-value")
                            }
                            Button { revealed.toggle() } label: {
                                Image(systemName: revealed ? "eye.slash" : "eye")
                            }.buttonStyle(.plain)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        moreExpanded.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.textMuted)
                                .rotationEffect(.degrees(moreExpanded ? 90 : 0))
                            Text(appLocalized("More Settings"))
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("credential-more-settings")
                    if moreExpanded {
                        VStack(alignment: .leading, spacing: 10) {
                            editorField(FrozenEditorMoreSettingsPresentation.agentInstructionsLabel) {
                                TextField(appLocalized("For example: App Store releases only"), text: $usageInstructions, axis: .vertical)
                            }
                            editorField(FrozenEditorMoreSettingsPresentation.privateNotesLabel) {
                                TextField(appLocalized("Only you can see this"), text: $privateNotes, axis: .vertical)
                                    .accessibilityIdentifier("credential-private-notes")
                                    .disabled(credential != nil && !didLoadSecrets)
                                if credential != nil && !didLoadSecrets {
                                    Button(appLocalized("Authenticate to Edit Private Notes")) {
                                        Task { await loadExistingSecrets() }
                                    }
                                    .buttonStyle(.link)
                                }
                            }
                            editorField(FrozenEditorMoreSettingsPresentation.expiryLabel) {
                                TextField("YYYY-MM-DD", text: $expiryDateText)
                                    .textFieldStyle(.roundedBorder)
                                Text(FrozenEditorMoreSettingsPresentation.expiryHelp)
                                    .font(.system(size: 11.5, weight: .regular))
                                    .foregroundStyle(
                                        expiryDateText.isEmpty || parsedExpiryDate != nil
                                            ? Theme.textMuted
                                            : Theme.red
                                    )
                            }
                        }
                        .padding(.top, 10)
                    }
                }
                .font(.system(size: 12.5, weight: .semibold))
                if let existingImportCredential {
                    let conflict = FrozenImportConflictPresentation(
                        existingName: existingImportCredential.name,
                        choice: importConflictChoice
                    )
                    HStack(alignment: .top, spacing: 10) {
                        Text("⚠︎").foregroundStyle(Theme.amber)
                        Text(conflict.warning ?? "")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.amber.opacity(0.10), in: .rect(cornerRadius: 9))
                    FrozenSegmentedControl(
                        options: Array(zip(FrozenImportConflictChoice.allCases, conflict.choices)),
                        selection: $importConflictChoice
                    )
                }
                HStack {
                    Spacer()
                    Button(appLocalized("Cancel")) { close() }
                    Button(credential == nil ? appLocalized("Save Credential") : appLocalized("Save Changes")) { save() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.brand)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid)
                        .accessibilityIdentifier("credential-editor-save")
                }
                .padding(.top, 4)
            }
            .padding(28)
        }
        .background(Theme.windowBackground)
    }

    @MainActor
    private func loadExistingSecrets() async {
        guard let credential, !didLoadSecrets else { return }
        if let revealed = await vault.revealTextCredential(credential) {
                value = revealed.value ?? ""
                privateNotes = revealed.privateNotes ?? ""
                if revealed.payloadKind == .bundle {
                    do {
                        components = try CredentialEditorComponentLoader.load(
                            revealed.components,
                            template: template
                        )
                    } catch {
                        vault.presentError(error)
                        return
                    }
                }
                didLoadSecrets = true
        }
    }

    private func editorField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
            content()
        }
    }

    private var permissionSegments: some View {
        FrozenSegmentedControl(
            options: CredentialPermission.prototypeCases.map { ($0, $0.prototypeTitle) },
            selection: $permission
        )
    }

    private var componentEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(template == .custom
                 ? FrozenEditorCopy.customHelp
                 : appLocalized("Keep everything needed for one task together."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            DisclosureGroup(appLocalized("Delivery Options")) {
                ForEach($components) { $component in
                    if !component.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        CredentialComponentDeliveryEditor(component: $component)
                    }
                }
            }
            .font(.system(size: 11))
            if template == .custom {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text(FrozenEditorCopy.keyHeader)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(FrozenEditorCopy.valueHeader)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: 42, height: 1)
                        Color.clear.frame(width: 18, height: 1)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)

                    ForEach($components) { $component in
                        HStack(spacing: 10) {
                            TextField(appLocalized("Key, for example API_TOKEN"), text: $component.name)
                                .font(.system(size: 12.5, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier(componentEditorIdentifier(component, field: "name"))
                            if component.kind == .file {
                                Button(component.file?.originalFilename ?? appLocalized("Choose File…")) {
                                    chooseComponentFile(component.id)
                                }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier(componentEditorIdentifier(component, field: "value"))
                            } else {
                                TextField(appLocalized("Enter text value"), text: $component.text)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityIdentifier(componentEditorIdentifier(component, field: "value"))
                            }
                            Text(FrozenEditorCopy.kindLabel(for: component.kind))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Theme.textMuted)
                                .frame(width: 42)
                            if components.count > 1 {
                                Button(role: .destructive) {
                                    components.removeAll { $0.id == component.id }
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.textMuted)
                                .frame(width: 18)
                            } else {
                                Color.clear.frame(width: 18, height: 1)
                            }
                        }
                        .padding(10)
                        .overlay(alignment: .top) { Divider() }
                    }
                }
                .background(Theme.panelBackground, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.neutral(0.08)))
                .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
            } else if template == .api {
                ForEach($components) { $component in
                    let card = FrozenEditorCopy.fieldCard(for: component)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                if !card.help.isEmpty {
                                    Text(card.help)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.textMuted)
                                }
                            }
                            Spacer()
                            if component.isRemovable {
                                Button(appLocalized("Remove"), role: .destructive) {
                                    components.removeAll { $0.id == component.id }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.textMuted)
                            }
                        }
                        HStack(spacing: 8) {
                            if component.kind == .file {
                                Button(component.file?.originalFilename ?? appLocalized("Choose file")) {
                                    chooseComponentFile(component.id)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier(componentEditorIdentifier(component, field: "value"))
                            } else if CredentialEditorInteractionPresentation.inputVisibility(
                                template: template,
                                isSecret: component.isSecret,
                                isRevealed: revealedComponentIDs.contains(component.id)
                            ) == .plain {
                                TextField(
                                    appLocalizedFormat("Enter %@", CredentialTemplate.fieldTitle(for: component.name)),
                                    text: $component.text
                                )
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier(componentEditorIdentifier(component, field: "value"))
                            } else {
                                SecureField(
                                    appLocalizedFormat("Enter %@", CredentialTemplate.fieldTitle(for: component.name)),
                                    text: $component.text
                                )
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier(componentEditorIdentifier(component, field: "value"))
                            }
                            if component.isSecret {
                                componentRevealButton(component.id)
                            }
                            Text(FrozenEditorCopy.kindLabel(for: component))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    .padding(12)
                    .background(Theme.panelBackground, in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.neutral(0.08)))
                    .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
                }
            } else {
                ForEach($components) { $component in
                    HStack {
                        Text(CredentialTemplate.fieldTitle(for: component.name))
                            .font(.system(size: 12.5, weight: .semibold))
                            .frame(minWidth: 100, alignment: .leading)
                        if component.kind == .file {
                            Button(component.file?.originalFilename ?? appLocalized("Choose file")) {
                                chooseComponentFile(component.id)
                            }
                            .accessibilityIdentifier(componentEditorIdentifier(component, field: "value"))
                        } else if CredentialEditorInteractionPresentation.inputVisibility(
                            template: template,
                            isSecret: component.isSecret,
                            isRevealed: revealedComponentIDs.contains(component.id)
                        ) == .plain {
                            TextField(
                                appLocalizedFormat("Enter %@", CredentialTemplate.fieldTitle(for: component.name)),
                                text: $component.text
                            )
                            .accessibilityIdentifier(componentEditorIdentifier(component, field: "value"))
                        } else {
                            SecureField(
                                appLocalizedFormat("Enter %@", CredentialTemplate.fieldTitle(for: component.name)),
                                text: $component.text
                            )
                            .accessibilityIdentifier(componentEditorIdentifier(component, field: "value"))
                        }
                        if component.isSecret {
                            componentRevealButton(component.id)
                        }
                        Text(FrozenEditorCopy.kindLabel(for: component))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 42)
                        if component.isRemovable {
                            Button(role: .destructive) {
                                components.removeAll { $0.id == component.id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack {
                Button(template == .custom ? FrozenEditorCopy.addTextAction : appLocalized("Add text")) {
                    components.append(CredentialComponentDraft())
                }
                .buttonStyle(.bordered)
                Button(template == .custom ? FrozenEditorCopy.addFileAction : appLocalized("Add file")) {
                    components.append(CredentialComponentDraft(kind: .file))
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func componentEditorIdentifier(
        _ component: CredentialComponentDraft,
        field: String
    ) -> String {
        let index = components.firstIndex(where: { $0.id == component.id }) ?? 0
        return "credential-editor-component-\(field)-\(index)"
    }

    private func chooseComponentFile(_ id: UUID) {
        guard let url = chooseFileURL() else { return }
        do {
            if url.lastPathComponent == ".env" || url.pathExtension.lowercased() == "env" {
                let pairs = try FrozenEnvImport.load(url: url).pairs
                guard !pairs.isEmpty else {
                    vault.errorMessage = appLocalized("The .env file contains no key-value pairs.")
                    return
                }
                components = pairs.map { CredentialComponentDraft(name: $0.name, text: $0.value) }
                isEnvImport = true
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    name = appLocalized("Imported environment variables")
                }
                return
            }
            let frozen = try FileImport.freeze(url: url)
            guard let index = components.firstIndex(where: { $0.id == id }) else { return }
            components[index].file = frozen
        } catch {
            vault.errorMessage = FrozenEnvImport.errorMessage(error)
        }
    }

    private func toggleComponentReveal(_ id: UUID) {
        if revealedComponentIDs.contains(id) {
            revealedComponentIDs.remove(id)
        } else {
            revealedComponentIDs.insert(id)
        }
    }

    private func componentRevealButton(_ id: UUID) -> some View {
        let isRevealed = revealedComponentIDs.contains(id)
        return Button {
            toggleComponentReveal(id)
        } label: {
            Image(systemName: isRevealed ? "eye.slash" : "eye")
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRevealed ? appLocalized("Hide Content") : appLocalized("Show Content"))
    }

    @ViewBuilder
    private var filePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(appLocalized(snapshot == nil && credential == nil ? CredentialManagementCopy.chooseFile : CredentialManagementCopy.replaceFile)) {
                chooseFile()
            }
            if let snapshot {
                Text(snapshot.originalFilename)
                    .font(.system(.body, design: .monospaced))
                Text(ByteCountFormatter.string(fromByteCount: Int64(snapshot.byteSize), countStyle: .file))
                    .foregroundStyle(.secondary)
                Text(snapshot.contentDigest.map { String(format: "%02x", $0) }.joined())
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else if let credential, credential.payloadKind == .file {
                Text("••••")
                    .foregroundStyle(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: Int64(credential.byteSize ?? 0), countStyle: .file))
                    .foregroundStyle(.secondary)
                Text(credential.contentDigest ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private func chooseFile() {
        guard let url = chooseFileURL() else { return }
        do {
            let frozen = try FileImport.freeze(url: url)
            snapshot = frozen
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = frozen.originalFilename
            }
        } catch {
            vault.presentError(error)
        }
    }

    private func chooseFileURL() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = appLocalized("Choose")
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func save() {
        if let credential, !didLoadSecrets {
            if vault.updateCredentialMetadata(
                id: credential.id,
                name: name,
                usageInstructions: usageInstructions,
                groupName: groupName,
                permission: permission,
                expiresAt: parsedExpiryDate
            ) {
                close()
            }
            return
        }
        if credential == nil || payloadKind == .bundle {
            guard let input = bundleInput() else {
                vault.errorMessage = appLocalized("Complete every credential component before saving.")
                return
            }
            if let existingImportCredential {
                switch importConflictChoice {
                case .skip:
                    close()
                case .replace:
                    Task {
                        if await vault.replaceImportedBundleCredential(
                            id: existingImportCredential.id,
                            components: input.components
                        ) {
                            close()
                        }
                    }
                }
                return
            }
            if let credential {
                guard vault.updateBundleCredential(id: credential.id, input) else { return }
            } else {
                guard vault.addBundleCredential(input) else { return }
            }
        } else if payloadKind == .file {
            let input = FileCredentialInput(
                name: name,
                snapshot: snapshot,
                usageInstructions: usageInstructions,
                privateNotes: privateNotes,
                groupName: groupName,
                environmentVariable: environmentVariable.isEmpty ? nil : environmentVariable,
                permission: permission,
                expiresAt: parsedExpiryDate
            )
            if let credential {
                vault.updateFileCredential(id: credential.id, input)
            } else {
                vault.addFileCredential(input)
            }
        } else {
            let input = TextCredentialInput(
                name: name,
                value: value,
                usageInstructions: usageInstructions,
                privateNotes: privateNotes,
                groupName: groupName,
                environmentVariable: environmentVariable.isEmpty ? nil : environmentVariable,
                permission: permission,
                expiresAt: parsedExpiryDate
            )
            if let credential {
                vault.updateTextCredential(id: credential.id, input)
            } else {
                vault.addTextCredential(input)
            }
        }
        close()
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func bundleInput() -> BundleCredentialInput? {
        guard let savedComponents = CredentialEditorComponentValidation.inputs(components) else {
            return nil
        }
        return BundleCredentialInput(
            name: name,
            components: savedComponents,
            usageInstructions: usageInstructions,
            privateNotes: privateNotes,
            groupName: groupName,
            permission: permission,
            expiresAt: parsedExpiryDate
        )
    }

    private var parsedExpiryDate: Date? {
        FrozenEditorMoreSettingsPresentation.expiryDate(from: expiryDateText)
    }

    private var existingImportCredential: ManagedTextCredential? {
        guard credential == nil, isEnvImport else { return nil }
        let candidate = normalizedCredentialName(name)
        return vault.credentials.first {
            normalizedCredentialName($0.name) == candidate
        }
    }

    private func normalizedCredentialName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}

enum FrozenEditorMoreSettingsPresentation {
    static var agentInstructionsLabel: String { appLocalized("Instructions for Agent (Optional)") }
    static var privateNotesLabel: String { appLocalized("Private Notes (Optional)") }
    static var expiryLabel: String { appLocalized("Expiry Date (Optional)") }
    static var labels: [String] { [
        agentInstructionsLabel,
        privateNotesLabel,
        expiryLabel,
    ] }
    static var expiryHelp: String { appLocalized("The credential is disabled at expiry. Agent requests are denied, with reminders starting 7 days before.") }

    static func expiryDate(from text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        return formatter.date(from: text)
    }

    static func expiryText(from date: Date) -> String {
        formatter.string(from: date)
    }

    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}
