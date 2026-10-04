import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

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
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .textCase(.uppercase)
                Spacer()
                if allowsCredentialChanges {
                    Button(action: createGroup) {
                        Image(systemName: "plus")
                            .font(Theme.Fonts.body)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .help(appLocalized("New group"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, Theme.Spacing.xs)

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
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
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

            Divider().overlay(Theme.separator).padding(.horizontal, 14)

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
        .padding(.horizontal, Theme.Spacing.sm)
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
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text(title)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
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
            .font(Theme.Fonts.body)
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
