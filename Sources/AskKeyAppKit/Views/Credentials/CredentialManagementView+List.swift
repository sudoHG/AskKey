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
            VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sectionTitle)
                        .font(Theme.Fonts.title)
                        .foregroundStyle(Theme.text)
                    Text(sectionSubtitle)
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textSecondary)
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
                        .font(Theme.Fonts.secondary.weight(.semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(height: Theme.controlHeight)
                        .padding(.horizontal, 10)
                        .background(Theme.accent, in: .rect(cornerRadius: 7))
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
                            .foregroundStyle(Theme.warning)
                            .tint(Theme.warning)
                    }
                }
            }
            if deletingGroupName != nil {
                inlineWarning(appLocalized("Deleting a group does not delete credentials. Its credentials become ungrouped."))
            }
            }
            .padding(.horizontal, 28)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.lg)

            if FrozenCollectionCopy.showsSearch(
                section: selectedSection,
                hasCredentials: !vault.credentials.isEmpty
            ) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.textTertiary)
                    TextField(appLocalized("Search credentials…"), text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                }
                .padding(.horizontal, 10)
                .frame(width: 300, height: 28)
                .background(Theme.neutralSubtle, in: .rect(cornerRadius: 7))
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
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.sm) {
                ForEach(filteredCredentials) { credential in
                Button {
                    selectedCredentialID = credential.id
                } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        Text(String(credential.name.prefix(1)).uppercased())
                            .font(Theme.Fonts.body.bold())
                            .foregroundStyle(Theme.accent)
                            .frame(width: 32, height: 32)
                            .background(Theme.accentSubtle, in: .rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text(credential.name)
                                .font(Theme.Fonts.body.weight(.semibold))
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
                            .font(Theme.Fonts.caption.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.neutral(0.08)))
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

}
