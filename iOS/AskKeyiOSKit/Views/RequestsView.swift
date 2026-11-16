import AskKeyDevices
import SwiftUI
import UIKit

/// The Requests tab (ADR 0014 → iPhone app, Home, amended by #345): banners
/// for iCloud and notification problems, then the requests that can still
/// be decided or wait for the Mac, or an empty state. Tapping a row opens
/// the request's page. A request that arrives never opens its page by
/// itself; its row is briefly highlighted instead (decision 8 of #344).
struct RequestsView: View {
    @Bindable var model: AppModel
    @Environment(\.openURL) private var openURL
    /// The request IDs as last seen; nil before the first look, so the rows
    /// already there when the tab appears are not highlighted.
    @State private var seenRequests: Set<String>?
    @State private var highlighted: Set<String> = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            RequestsContent(cards: model.activeRequests(at: context.date), now: context.date,
                            hasMacs: !model.pairedMacs.isEmpty, approvingMacs: model.approvingMacCount,
                            accountNotice: model.accountNotice, notificationsOff: model.notificationsOff,
                            biometry: model.biometryKind, highlighted: highlighted,
                            onOpen: { model.open($0.id) }, onPair: model.startPairing, onOpenSettings: openSettings)
        }
        .tabScaffold()
        .refreshable { await model.processInbox() }
        .navigationTitle(Text(HomeTab.requests.title, bundle: .kit))
        .navigationBarTitleDisplayMode(.large)
        .onChange(of: model.requests.map(\.id), initial: true) { _, ids in
            highlightArrivals(ids)
        }
    }

    private func highlightArrivals(_ ids: [String]) {
        let current = Set(ids)
        let previous = seenRequests
        seenRequests = current
        guard let previous else { return }
        let arrived = current.subtracting(previous)
        guard !arrived.isEmpty else { return }
        highlighted.formUnion(arrived)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.8)) { highlighted.subtract(arrived) }
        }
    }

    private func openSettings(_ page: SettingsPage) {
        let address = page == .notifications
            ? UIApplication.openNotificationSettingsURLString : UIApplication.openSettingsURLString
        if let url = URL(string: address) { openURL(url) }
    }
}

/// Which page of Settings a banner opens: Ask Key's own, or its notifications.
enum SettingsPage: Hashable {
    case app
    case notifications
}

/// The Requests tab's content, drawn by SwiftUI alone so it renders for
/// review as the app shows it. A row shows only the card's sentence and the
/// time left, or that a decision was sent; never the command, the folder,
/// the delivered names or the purpose, which only the request's page shows.
struct RequestsContent: View {
    let cards: [RequestCard]
    let now: Date
    let hasMacs: Bool
    /// The Macs whose requests this iPhone accepts.
    let approvingMacs: Int
    let accountNotice: AccountNotice?
    let notificationsOff: Bool
    var biometry: BiometryKind = .faceID
    var highlighted: Set<String> = []
    let onOpen: (RequestCard) -> Void
    let onPair: () -> Void
    let onOpenSettings: (SettingsPage) -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let accountNotice {
                BannerRow(symbol: Self.symbol(accountNotice), text: Text(Self.explanation(accountNotice), bundle: .kit)) {
                    onOpenSettings(.app)
                }
            }
            if notificationsOff {
                BannerRow(symbol: "bell.slash", text: Text("list.notifications.off", bundle: .kit)) {
                    onOpenSettings(.notifications)
                }
            }
            if cards.isEmpty {
                Spacer(minLength: 24)
                if hasMacs {
                    EmptyStateView(symbol: "tray", title: "request.empty.title", detail: "request.empty.detail") {
                        ReachabilityCapsule(approvingMacs: approvingMacs,
                                            cannotReach: Self.macsCannotReach(accountNotice: accountNotice,
                                                                              notificationsOff: notificationsOff))
                    }
                } else {
                    EmptyStateView(symbol: "laptopcomputer", title: "list.empty.title", detail: "list.empty.detail") {
                        PairButton(action: onPair)
                    }
                }
                Spacer(minLength: 24)
            } else {
                GroupedSection {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                        if index > 0 { GroupedDivider() }
                        RequestRow(card: card, now: now, isHighlighted: highlighted.contains(card.id)) { onOpen(card) }
                    }
                } footer: {
                    Text(biometry == .touchID ? "request.list.footnote.touchID" : "request.list.footnote", bundle: .kit)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    /// While a banner shows, the Macs cannot reach this iPhone, or cannot
    /// get the person's attention, so the empty state says so.
    static func macsCannotReach(accountNotice: AccountNotice?, notificationsOff: Bool) -> Bool {
        accountNotice != nil || notificationsOff
    }

    static func explanation(_ notice: AccountNotice) -> LocalizedStringKey {
        switch notice {
        case .signedOut: return "list.account.signedOut"
        case .restricted: return "list.account.restricted"
        case .unavailable: return "list.account.unavailable"
        }
    }

    static func symbol(_ notice: AccountNotice) -> String {
        switch notice {
        case .signedOut, .restricted: return "icloud.slash"
        case .unavailable: return "exclamationmark.icloud"
        }
    }
}

/// One request: its sentence, names bold, in at most two lines (more at
/// accessibility text sizes), and the time left, orange under a minute, or
/// that the decision was sent.
struct RequestRow: View {
    let card: RequestCard
    let now: Date
    var isHighlighted = false
    let onOpen: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    RequestSentence(card: card)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(typeSize.isAccessibilitySize ? 5 : 2)
                    status
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RowChevron()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: GroupedMetrics.rowMinHeight)
            .background(isHighlighted ? Color.accentColor.opacity(0.14) : Color.clear)
        }
        .buttonStyle(GroupedRowButtonStyle())
    }

    @ViewBuilder private var status: some View {
        switch card.phase(at: now) {
        case .sending:
            Label { Text("request.row.sending", bundle: .kit) } icon: { Image(systemName: "arrow.up.circle") }
                .foregroundStyle(.secondary)
        case .waiting:
            Label { Text("request.row.waiting", bundle: .kit) } icon: { Image(systemName: "hourglass") }
                .foregroundStyle(.secondary)
        default:
            let seconds = card.secondsLeft(at: now)
            Label { Text("request.timeLeft.value \(Self.clock(seconds))", bundle: .kit) } icon: {
                Image(systemName: "clock")
            }
            .monospacedDigit()
            .foregroundStyle(seconds < 60 ? Color.orange : Color.secondary)
        }
    }

    /// Seconds as minutes and seconds, such as "4:32".
    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Under the empty state: a green dot and how many Macs can send requests
/// here, or an orange dot while a banner says why they cannot.
struct ReachabilityCapsule: View {
    let approvingMacs: Int
    let cannotReach: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(cannotReach || approvingMacs == 0 ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            text
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .accessibilityElement(children: .combine)
    }

    private var text: Text {
        if cannotReach { return Text("request.empty.unreachable", bundle: .kit) }
        if approvingMacs == 1 { return Text("request.empty.reachableOne", bundle: .kit) }
        return Text("request.empty.reachable \(String(approvingMacs))", bundle: .kit)
    }
}
