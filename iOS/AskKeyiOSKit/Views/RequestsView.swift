import AskKeyDevices
import SwiftUI
import UIKit

/// The Requests tab (ADR 0014 → iPhone app, Home, amended by #345): banners
/// for iCloud and notification problems, then the requests that can still
/// be decided or wait for the Mac, or an empty state. Tapping a row opens
/// the request's page. A request that arrives never opens its page by
/// itself; its row is highlighted instead, for two seconds once this tab
/// shows it (decision 8 of #344).
struct RequestsView: View {
    @Bindable var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            RequestsContent(cards: model.activeRequests(at: context.date), now: context.date,
                            hasMacs: !model.pairedMacs.isEmpty, approvingMacs: model.approvingMacCount,
                            accountNotice: model.accountNotice, notificationsOff: model.notificationsOff,
                            biometry: model.biometryKind, highlighted: model.unseenArrivals,
                            onOpen: { model.open($0.id) }, onPair: model.startPairing, onOpenSettings: openSettings)
        }
        .tabScaffold()
        .refreshable { await model.processInbox() }
        .navigationTitle(Text(HomeTab.requests.title, bundle: .kit))
        .navigationBarTitleDisplayMode(.large)
        .task(id: ArrivalWatch(shown: model.selectedTab == .requests, arrivals: model.unseenArrivals)) {
            guard model.selectedTab == .requests, !model.unseenArrivals.isEmpty else { return }
            let shown = model.unseenArrivals
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.8)) { model.markArrivalsSeen(shown) }
        }
    }

    private struct ArrivalWatch: Equatable {
        let shown: Bool
        let arrivals: Set<String>
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
                        if let capsule = Self.capsule(accountNotice: accountNotice, approvingMacs: approvingMacs) {
                            ReachabilityCapsule(state: capsule)
                        }
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

    /// What the empty state's capsule says. While an iCloud banner shows,
    /// the Macs cannot reach this iPhone. With notifications off, requests
    /// still arrive and the banner says what is wrong, so the capsule still
    /// counts the Macs. Without an approving Mac it is hidden: the Macs tab
    /// says why, and there is nothing true to count.
    static func capsule(accountNotice: AccountNotice?, approvingMacs: Int) -> ReachabilityCapsule.Reachability? {
        if accountNotice != nil { return .unreachable }
        return approvingMacs > 0 ? .reachable(approvingMacs) : nil
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
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    sentence
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
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The card's sentence, names bold, with the requester's and the Mac's
    /// names shortened so that a long name, which the agent chooses, cannot
    /// push the credential out of the row; the page shows them in full.
    private var sentence: Text {
        let requester = card.display.requesterName.isEmpty
            ? Text("request.localAgent", bundle: .kit) : Text(verbatim: Self.short(card.display.requesterName))
        let mac = Text(verbatim: Self.short(card.macName))
        return Text("request.title \(requester.bold()) \(mac.bold()) \(Text(verbatim: card.display.credentialName).bold())",
                    bundle: .kit)
    }

    /// A name cut to `limit` characters with an ellipsis.
    static func short(_ name: String, limit: Int = 24) -> String {
        name.count > limit ? String(name.prefix(limit - 1)) + "…" : name
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
            .accessibilityLabel(Text("request.timeLeft.value \(Self.spoken(seconds, locale: locale))", bundle: .kit))
        }
    }

    /// Seconds as VoiceOver reads them, such as "4 minutes, 32 seconds".
    static func spoken(_ seconds: Int, locale: Locale) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide).locale(locale))
    }

    /// Seconds as minutes and seconds, such as "4:32".
    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Under the empty state: a green dot and how many Macs can send requests
/// here, or an orange dot while an iCloud banner says why they cannot.
struct ReachabilityCapsule: View {
    enum Reachability: Equatable {
        case reachable(Int)
        case unreachable
    }

    let state: Reachability

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state == .unreachable ? Color.orange : Color.green)
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
        switch state {
        case .unreachable: return Text("request.empty.unreachable", bundle: .kit)
        case .reachable(1): return Text("request.empty.reachableOne", bundle: .kit)
        case .reachable(let count): return Text("request.empty.reachable \(String(count))", bundle: .kit)
        }
    }
}
