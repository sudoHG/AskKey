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
                sectionHeader(appLocalized("Credential Library"))
                Spacer()
                if allowsCredentialChanges {
                    Button(action: createGroup) {
                        Image(systemName: "plus")
                            .font(Theme.Fonts.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                    .help(appLocalized("New group"))
                }
            }
            .padding(.trailing, Theme.Spacing.sm)

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

            Spacer(minLength: Theme.Spacing.lg)

            sectionHeader(appLocalized("Agent approvals"))
            VStack(spacing: 2) {
                routeButton(
                    .pendingRequests,
                    title: appLocalized("Pending requests"),
                    icon: "tray",
                    identifier: "sidebar-pending",
                    count: vault.pendingApprovalCount,
                    highlightsCount: true
                )
                routeButton(
                    .accessRecords,
                    title: appLocalized("Access records"),
                    icon: "clock",
                    identifier: "sidebar-records"
                )
                routeButton(
                    .agentAccess,
                    title: appLocalized("Agent access"),
                    icon: "arrow.left.arrow.right",
                    identifier: "sidebar-agent"
                )
                routeButton(
                    .settings,
                    title: appLocalized("Settings"),
                    icon: "gearshape",
                    identifier: "sidebar-settings"
                )
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.top, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.md)
        .background(Theme.sidebarBackground)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.Fonts.caption.weight(.medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.bottom, Theme.Spacing.xs)
            .accessibilityAddTraits(.isHeader)
    }

    /// Credential counts are known only while management is unlocked; the
    /// locked shell shows no counts rather than a misleading zero.
    private func groupRow(
        _ section: CredentialWorkspaceSection,
        title: String,
        count: Int
    ) -> some View {
        let selected = selectedSection == section && route.sidebarSelection == sidebarSelection(for: section)
        return Button {
            select(section)
        } label: {
            sidebarRow(
                title: title,
                icon: sidebarIcon(for: section),
                count: allowsCredentialChanges ? count : nil,
                highlightsCount: false,
                selected: selected
            )
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
        highlightsCount: Bool = false
    ) -> some View {
        let selected = route.sidebarSelection == destination.sidebarSelection
        return Button {
            activateRoute(destination)
        } label: {
            sidebarRow(
                title: title,
                icon: icon,
                count: count,
                highlightsCount: highlightsCount,
                selected: selected
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(selected ? "selected" : "")
        .registerAction(identifier, action: { activateRoute(destination) })
    }

    /// One row style for every sidebar destination. Counters share one
    /// style; a nonzero count that needs attention becomes an accent badge.
    private func sidebarRow(
        title: String,
        icon: String,
        count: Int?,
        highlightsCount: Bool,
        selected: Bool
    ) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 16)
            Text(title)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.xs)
            if let count {
                if highlightsCount, count > 0 {
                    Text("\(count)")
                        .font(Theme.Fonts.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Theme.accent, in: Capsule())
                } else {
                    Text("\(count)")
                        .font(Theme.Fonts.secondary)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .frame(height: 28)
        .background(selected ? Theme.neutral(0.08) : Color.clear, in: .rect(cornerRadius: Theme.Radius.control))
        .contentShape(Rectangle())
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
        case .all: return "list.bullet.rectangle"
        case .named: return "folder"
        case .ungrouped: return "line.3.horizontal"
        case .recycleBin: return "trash"
        case .accessRecords: return "clock"
        case .agentAccess: return "arrow.left.arrow.right"
        }
    }

}
