import SwiftUI

/// The History tab (ADR 0014 → iPhone app, History, amended by #345): the
/// requests this app verified, once they ended, by day, newest first, for
/// 30 days. A row opens the entry's detail. **Clear All History** is in the
/// ⋯ menu, with a confirmation. Nothing here asks for Face ID or Touch ID.
struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var selectedEntry: String?
    @State private var confirmingClear = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HistoryContent(entries: model.history, filter: filter, now: context.date,
                           onSelect: { selectedEntry = $0.id }, onClearFilter: { model.historyFilter = nil })
        }
        .tabScaffold()
        .navigationTitle(Text(HomeTab.history.title, bundle: .kit))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if !model.history.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            confirmingClear = true
                        } label: {
                            Label { HistoryClearText.action } icon: { Image(systemName: "trash") }
                        }
                    } label: {
                        Label { Text("history.more", bundle: .kit) } icon: { Image(systemName: "ellipsis") }
                    }
                }
            }
        }
        .navigationDestination(item: $selectedEntry) { id in
            HistoryDetailView(model: model, entryID: id)
        }
        .confirmationDialog(HistoryClearText.title, isPresented: $confirmingClear, titleVisibility: .visible) {
            Button(role: .destructive) {
                selectedEntry = nil
                model.clearHistory()
            } label: {
                HistoryClearText.action
            }
            Button(role: .cancel) {} label: { Text("common.cancel", bundle: .kit) }
        } message: {
            HistoryClearText.message
        }
        .onChange(of: model.openedRequest) { _, opened in
            // A tapped notification's page opens over the home; an entry's
            // detail on screen closes first, as a Mac's detail does.
            if opened != nil, model.selectedTab == .history { selectedEntry = nil }
        }
    }

    /// The Mac History is filtered to, by its name on this iPhone now, or
    /// in its latest entry once it was removed.
    private var filter: HistoryFilter? {
        guard let macID = model.historyFilter else { return nil }
        let name = model.pairedMacs.first { $0.id == macID }?.name
            ?? model.history.first { $0.macID == macID }?.macName ?? ""
        return HistoryFilter(macID: macID, macName: name)
    }
}

/// **Clear All History**'s confirmation, in the dialog and in its render.
enum HistoryClearText {
    static var title: Text { Text("history.clear.title", bundle: .kit) }
    static var message: Text { Text("history.clear.message", bundle: .kit) }
    static var action: Text { Text("history.clear", bundle: .kit) }
}

/// History filtered to one Mac, from that Mac's detail.
struct HistoryFilter: Hashable {
    let macID: String
    let macName: String
}

/// The History tab's content, drawn by SwiftUI alone so it renders for
/// review as the app shows it: the Mac filter, then one section per day
/// with the rule in the last section's footer, or the empty state.
struct HistoryContent: View {
    var entries: [HistoryEntry] = []
    var filter: HistoryFilter?
    var now: Date = .now
    var onSelect: (HistoryEntry) -> Void = { _ in }
    var onClearFilter: () -> Void = {}
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.calendar) private var environmentCalendar

    private var calendar: Calendar {
        var calendar = environmentCalendar
        calendar.timeZone = timeZone
        return calendar
    }

    private var shown: [HistoryEntry] {
        guard let filter else { return entries }
        return entries.filter { $0.macID == filter.macID }
    }

    var body: some View {
        let days = HistoryDays.sections(shown, calendar: calendar)
        VStack(spacing: 24) {
            if let filter {
                HistoryFilterBar(filter: filter, onClear: onClearFilter)
            }
            if days.isEmpty {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    EmptyStateView(symbol: "clock.arrow.circlepath", title: "history.empty.title",
                                   detail: "history.empty.detail")
                    Spacer(minLength: 24)
                }
                .frame(maxHeight: .infinity)
            } else {
                ForEach(days, id: \.day) { section in
                    GroupedSection(header: dayTitle(section.day)) {
                        ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { GroupedDivider(leadingInset: GroupedMetrics.symbolInset) }
                            HistoryRow(entry: entry) { onSelect(entry) }
                        }
                    } footer: {
                        if section.day == days.last?.day {
                            Text("history.footer", bundle: .kit)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    /// Today, Yesterday, then the weekday and the date.
    private func dayTitle(_ day: Date) -> Text {
        let today = calendar.startOfDay(for: now)
        if day == today { return Text("history.today", bundle: .kit) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return Text("history.yesterday", bundle: .kit)
        }
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
        style.locale = locale
        style.timeZone = timeZone
        style.calendar = calendar
        return Text(verbatim: day.formatted(style))
    }
}

/// Completed entries by the day they ended, newest first.
enum HistoryDays {
    struct Section {
        let day: Date
        let entries: [HistoryEntry]
    }

    static func sections(_ entries: [HistoryEntry], calendar: Calendar) -> [Section] {
        var sections: [Section] = []
        for entry in entries {
            guard let ended = entry.endedAt else { continue }
            let day = calendar.startOfDay(for: ended)
            if let last = sections.last, last.day == day {
                sections[sections.count - 1] = Section(day: day, entries: last.entries + [entry])
            } else {
                sections.append(Section(day: day, entries: [entry]))
            }
        }
        return sections
    }
}

/// Which Mac History shows, and **Show All**.
struct HistoryFilterBar: View {
    let filter: HistoryFilter
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("history.filter \(Text(verbatim: filter.macName))", bundle: .kit)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onClear) { Text("history.filter.clear", bundle: .kit) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .accessibilityElement(children: .contain)
    }
}

/// One entry: the outcome's symbol and color from the outcome page, who
/// asked for which credential, the Mac and the outcome, and when it ended.
/// The requester's name is shortened as in a Requests row; the detail shows
/// it in full.
struct HistoryRow: View {
    let entry: HistoryEntry
    let onOpen: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @ScaledMetric(relativeTo: .body) private var symbolWidth: CGFloat = 30

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                if let ending = entry.ending {
                    Image(systemName: ending.symbol)
                        .font(.title3)
                        .foregroundStyle(ending.tone.color)
                        .frame(width: symbolWidth)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    if typeSize.isAccessibilitySize {
                        names
                        outcome
                        time
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            names
                            Spacer(minLength: 0)
                            time
                        }
                        outcome
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                RowChevron()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: GroupedMetrics.rowMinHeight)
        }
        .buttonStyle(GroupedRowButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HistoryCopy.spoken(entry, time: timeText))
        .accessibilityAddTraits(.isButton)
    }

    private var timeText: String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.locale = locale
        style.timeZone = timeZone
        return entry.endedAt.map { $0.formatted(style) } ?? ""
    }

    private var names: some View {
        HistoryCopy.names(entry)
            .font(.body)
            .foregroundStyle(.primary)
            .lineLimit(typeSize.isAccessibilitySize ? 4 : 1)
    }

    /// The Mac and the outcome, on their own line so the outcome is never cut.
    private var outcome: some View {
        HistoryCopy.macAndOutcome(entry)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
    }

    private var time: some View {
        Text(verbatim: timeText)
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// History's words for an entry.
enum HistoryCopy {
    /// "Codex · GitHub Token": the requester, or Local Agent, and the credential.
    static func names(_ entry: HistoryEntry) -> Text {
        requester(entry, shortened: true) + Text(verbatim: " · ") + Text(verbatim: entry.credentialName)
    }

    /// "Studio Mac · Allowed once".
    static func macAndOutcome(_ entry: HistoryEntry) -> Text {
        Text(verbatim: RequestCopy.short(entry.macName) + " · ") + outcome(entry)
    }

    /// What VoiceOver reads for a row, in the row's order.
    static func spoken(_ entry: HistoryEntry, time: String) -> Text {
        requester(entry, shortened: false) + Text(verbatim: ", " + entry.credentialName + ", " + entry.macName + ", ")
            + outcome(entry) + Text(verbatim: ", " + time)
    }

    static func requester(_ entry: HistoryEntry, shortened: Bool) -> Text {
        guard !entry.requesterName.isEmpty else { return Text("request.localAgent", bundle: .kit) }
        return Text(verbatim: shortened ? RequestCopy.short(entry.requesterName) : entry.requesterName)
    }

    /// The outcome in a row, such as "Allowed once" or "Result unknown".
    static func outcome(_ entry: HistoryEntry) -> Text {
        switch entry.ending {
        case .closed(.allowedOnce)?: return Text("history.outcome.allowedOnce", bundle: .kit)
        case .closed(.allowedTimed(let seconds))?:
            // In the outcome page's words for the same duration.
            if seconds == 60 { return Text("history.outcome.allowedOneMinute", bundle: .kit) }
            if seconds % 60 == 0 { return Text("history.outcome.allowedMinutes \(String(seconds / 60))", bundle: .kit) }
            return Text("history.outcome.allowedTimed \(RequestCopy.duration(seconds))", bundle: .kit)
        case .closed(.denied)?: return Text("history.outcome.denied", bundle: .kit)
        case .closed(.decidedOnMac)?: return Text("history.outcome.decidedOnMac", bundle: .kit)
        case .closed(.decidedElsewhere)?: return Text("history.outcome.decidedElsewhere", bundle: .kit)
        case .closed(.expired)?: return Text("history.outcome.expired", bundle: .kit)
        case .closed(.cancelled)?: return Text("history.outcome.cancelled", bundle: .kit)
        case .closed(.notApplied)?: return Text("history.outcome.notApplied", bundle: .kit)
        case .timedOut?, nil: return Text("history.outcome.timedOut", bundle: .kit)
        case .gone?: return Text("history.outcome.gone", bundle: .kit)
        }
    }
}
