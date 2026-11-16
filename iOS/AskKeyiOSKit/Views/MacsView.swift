import SwiftUI

/// The Macs tab (ADR 0014 → iPhone app, Home, amended by #345): the outcome
/// of the last removal, the paired Macs, and this iPhone's own status.
/// **+** starts pairing; a Mac's row opens its detail.
struct MacsView: View {
    @Bindable var model: AppModel
    @State private var selectedMac: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            MacsContent(rows: model.pairedMacs, listNotice: model.listNotice, accountNotice: model.accountNotice,
                        accountChecked: model.accountChecked, notifications: model.notificationAuthorization,
                        lastDeliveryCheck: model.lastDeliveryCheck,
                        version: AppVersion.current, now: context.date, onPair: model.startPairing,
                        onSelect: { selectedMac = $0.id }, onDismissNotice: { model.listNotice = nil })
        }
        .tabScaffold()
        .refreshable { await model.processInbox() }
        .navigationTitle(Text(HomeTab.macs.title, bundle: .kit))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: model.startPairing) {
                    Label { Text("list.pair", bundle: .kit) } icon: { Image(systemName: "plus") }
                }
            }
        }
        .navigationDestination(item: $selectedMac) { id in
            MacDetailView(model: model, macID: id)
        }
        .onChange(of: model.openedRequest) { _, opened in
            // A tapped notification's page opens over the home; the Mac's
            // detail on screen, with its dialogs, closes first.
            if opened != nil, model.selectedTab == .macs { selectedMac = nil }
        }
    }
}

/// The app's version and build, such as "1.0 (12)".
enum AppVersion {
    static var current: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// The Macs tab's content, drawn by SwiftUI alone so it renders for review
/// as the app shows it: the removal notice, one list of Macs with the rule
/// in its footer (or the empty state), then This iPhone.
struct MacsContent: View {
    let rows: [PairedMacRow]
    let listNotice: ListNotice?
    let accountNotice: AccountNotice?
    /// False until the first account check; This iPhone then shows no iCloud state.
    var accountChecked = true
    /// As last read; nil before the first read.
    let notifications: NotificationAuthorization?
    let lastDeliveryCheck: Date?
    let version: String
    let now: Date
    let onPair: () -> Void
    let onSelect: (PairedMacRow) -> Void
    let onDismissNotice: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            if let listNotice {
                RemovalNoticeRow(notice: listNotice, onDismiss: onDismissNotice)
            }
            if rows.isEmpty {
                EmptyStateView(symbol: "laptopcomputer", title: "list.empty.title", detail: "list.empty.detail") {
                    PairButton(action: onPair)
                }
                .padding(.vertical, 12)
            } else {
                GroupedSection {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { GroupedDivider(leadingInset: GroupedMetrics.symbolInset) }
                        MacRow(row: row, now: now) { onSelect(row) }
                    }
                } footer: {
                    Text("list.footer", bundle: .kit)
                }
            }
            ThisIPhoneSection(accountNotice: accountNotice, accountChecked: accountChecked,
                              notificationsOn: Self.notificationsOn(notifications),
                              lastDeliveryCheck: lastDeliveryCheck, version: version)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    /// The Notifications row: on only when allowed, off when denied or never
    /// answered, nothing before the first read.
    static func notificationsOn(_ authorization: NotificationAuthorization?) -> Bool? {
        switch authorization {
        case .allowed?: return true
        case .denied?, .notDetermined?: return false
        case nil: return nil
        }
    }
}

/// A Mac's row: its name, when this iPhone last heard from it, and only for
/// the exception, an entry without the approval flag, that this iPhone
/// cannot approve its requests. Tapping it opens the Mac's detail.
private struct MacRow: View {
    let row: PairedMacRow
    let now: Date
    let onSelect: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                Image(systemName: "laptopcomputer")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: row.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if let reached = row.lastReachedAt {
                        Text("list.lastReached \(RelativeTime.text(reached, now: now, locale: locale))", bundle: .kit)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("list.notReached", bundle: .kit)
                            .foregroundStyle(.orange)
                    }
                    if !row.isApprover {
                        Label { Text("list.notApprover", bundle: .kit) } icon: {
                            Image(systemName: "exclamationmark.shield.fill")
                        }
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.leading)
                    }
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                RowChevron()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(minHeight: GroupedMetrics.rowMinHeight)
        }
        .buttonStyle(GroupedRowButtonStyle())
    }
}

/// The outcome of the last removal, at the top of the tab until dismissed.
struct RemovalNoticeRow: View {
    let notice: ListNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol.name)
                .font(.title3)
                .foregroundStyle(symbol.color)
                .frame(width: 28)
                .accessibilityHidden(true)
            Self.text(notice)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -10)
            .padding(.trailing, -10)
            .accessibilityLabel(Text("common.dismiss", bundle: .kit))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .accessibilityElement(children: .contain)
    }

    private var symbol: (name: String, color: Color) {
        switch notice {
        case .removed(_, true): return ("checkmark.circle.fill", .green)
        case .removed(_, false), .removalFailed: return ("exclamationmark.triangle.fill", .orange)
        case .removedByMac: return ("info.circle.fill", .accentColor)
        }
    }

    static func text(_ notice: ListNotice) -> Text {
        switch notice {
        case .removed(let name, true): return Text("list.notice.removedAndTold \(name)", bundle: .kit)
        case .removed(let name, false): return Text("list.notice.removedNotTold \(name)", bundle: .kit)
        case .removedByMac(let name): return Text("list.notice.removedByMac \(name)", bundle: .kit)
        case .removalFailed: return Text("list.notice.removalFailed", bundle: .kit)
        }
    }
}

/// This iPhone: whether iCloud and notifications work, the last delivery
/// check, and that no credential value is kept here, with the version.
private struct ThisIPhoneSection: View {
    let accountNotice: AccountNotice?
    let accountChecked: Bool
    let notificationsOn: Bool?
    let lastDeliveryCheck: Date?
    let version: String

    var body: some View {
        GroupedSection(header: Text("list.thisIPhone", bundle: .kit)) {
            ValueRow(symbol: accountNotice == nil ? "icloud" : "icloud.slash") {
                Text(verbatim: "iCloud")
            } value: {
                iCloudValue
            }
            GroupedDivider(leadingInset: GroupedMetrics.symbolInset)
            ValueRow(symbol: notificationsOn == false ? "bell.slash" : "bell") {
                Text("list.notifications", bundle: .kit)
            } value: {
                switch notificationsOn {
                case true?: Text("list.notifications.stateOn", bundle: .kit).foregroundStyle(.secondary)
                case false?: Text("list.notifications.stateOff", bundle: .kit).foregroundStyle(.orange)
                case nil: EmptyView()
                }
            }
            GroupedDivider(leadingInset: GroupedMetrics.symbolInset)
            ValueRow(symbol: "checkmark.circle") {
                Text("list.lastDeliveryCheck", bundle: .kit)
            } value: {
                if let lastDeliveryCheck {
                    Text(lastDeliveryCheck, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .foregroundStyle(.secondary)
                } else {
                    Text("list.lastDeliveryCheck.none", bundle: .kit).foregroundStyle(.secondary)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text("list.noValues", bundle: .kit)
                Text("list.version \(version)", bundle: .kit)
            }
        }
    }

    @ViewBuilder private var iCloudValue: some View {
        switch accountNotice {
        case nil where !accountChecked: EmptyView()
        case nil: Text("list.iCloud.signedIn", bundle: .kit).foregroundStyle(.secondary)
        case .signedOut: Text("list.iCloud.signedOut", bundle: .kit).foregroundStyle(.orange)
        case .restricted: Text("list.iCloud.restricted", bundle: .kit).foregroundStyle(.orange)
        case .unavailable: Text("list.iCloud.unavailable", bundle: .kit).foregroundStyle(.orange)
        }
    }
}
