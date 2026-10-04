import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialManagementView {
    var filteredCredentials: [ManagedTextCredential] {
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

    @ViewBuilder
    var credentialDetail: some View {
        if selectedCredentialID != nil {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    selectedCredentialID = nil
                } label: {
                    Label(sectionTitle, systemImage: "arrow.left")
                        .font(Theme.Fonts.secondary)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 28)
                .padding(.top, 20)
                credentialInspector
            }
            .background(Theme.windowBackground)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    PageHeader(title: sectionTitle, subtitle: sectionSubtitle) {
                        libraryActions
                    }
                    if deletingGroupName != nil {
                        inlineWarning(appLocalized("Deleting a group does not delete credentials. Its credentials become ungrouped."))
                    }
                }
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.top, Theme.Spacing.xxl)
                .padding(.bottom, Theme.Spacing.lg)

                if FrozenCollectionCopy.showsSearch(
                    section: selectedSection,
                    hasCredentials: !vault.credentials.isEmpty
                ) {
                    searchField
                        .padding(.horizontal, Theme.Spacing.xxl)
                        .padding(.bottom, Theme.Spacing.md)
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

    @ViewBuilder
    private var libraryActions: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if case .named(let name) = selectedSection {
                if deletingGroupName == name {
                    Button(appLocalized("Keep")) { deletingGroupName = nil }
                        .buttonStyle(.secondaryAction)
                    Button(FrozenDangerActions.groupConfirmationTitle, role: .destructive) {
                        deletingGroupName = nil
                        vault.deleteCredentialGroup(name)
                        selectedSection = .ungrouped
                    }
                    .buttonStyle(FrozenDangerButtonStyle())
                } else {
                    Button(FrozenCollectionCopy.deleteAction, role: .destructive) {
                        deletingGroupName = name
                    }
                    .buttonStyle(.irreversibleAction)
                }
            }
            if selectedSection.showsCredentialImport {
                BorderedActionButton(action: {
                    route = .fileImport
                }) {
                    Text(
                        selectedSection.importDestinationGroup == nil
                            ? appLocalized("Import from File")
                            : FrozenCollectionCopy.importAction
                    )
                }
            }
            Button {
                route = .templateChooser
            } label: {
                Text(
                    selectedSection.importDestinationGroup == nil
                        ? appLocalized("New Credential")
                        : FrozenCollectionCopy.newCredentialAction
                )
            }
            .buttonStyle(FrozenPrimaryButtonStyle())
            .accessibilityIdentifier("credential-new")
        }
    }

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.textTertiary)
            TextField(appLocalized("Search credentials…"), text: $searchText)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.body)
                .focused($searchFocused)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .frame(width: 300, height: Theme.controlHeight)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .stroke(Theme.neutral(0.16), lineWidth: 1)
        )
    }

    func credentialDetailPage(id: String) -> some View {
        credentialDetail.onAppear { selectedCredentialID = id }
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
        let credentials = filteredCredentials
        return ScrollView {
            GroupedList {
                ForEach(Array(credentials.enumerated()), id: \.element.id) { index, credential in
                    if index > 0 { GroupedListSeparator() }
                    credentialRow(credential)
                }
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.bottom, Theme.Spacing.xxl)
        }
    }

    private func credentialRow(_ credential: ManagedTextCredential) -> some View {
        let presentation = CredentialListPresentation(
            credential: credential,
            showsGroup: selectedSection.importDestinationGroup == nil
        )
        return Button {
            selectedCredentialID = credential.id
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Text(presentation.monogram)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.neutralSubtle, in: .rect(cornerRadius: Theme.Radius.control))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(credential.name)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(presentation.secondaryLine)
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: Theme.Spacing.md)
                StatusLabel(title: presentation.statusTitle, role: presentation.statusRole)
                Image(systemName: "chevron.right")
                    .font(Theme.Fonts.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .contentShape(Rectangle())
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
