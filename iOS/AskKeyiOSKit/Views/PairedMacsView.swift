import SwiftUI

struct PairedMacsView: View {
    @Bindable var model: AppModel
    @State private var pendingRemoval: PairedMacRow?

    var body: some View {
        PairedMacsContent(rows: model.pairedMacs, accountNotice: model.accountNotice, listNotice: model.listNotice,
                          records: model.deliveryRecords, onPair: model.startPairing,
                          onRemove: { pendingRemoval = $0 }, onDismissNotice: { model.listNotice = nil })
            .screenScaffold()
            .refreshable { await model.processInbox() }
            .confirmationDialog(Text("list.remove.confirmTitle \(pendingRemoval?.name ?? String())", bundle: .kit),
                                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                                titleVisibility: .visible, presenting: pendingRemoval) { row in
                Button(role: .destructive) {
                    Task { await model.removeMac(id: row.id) }
                } label: {
                    Text("list.remove.confirm", bundle: .kit)
                }
                Button(role: .cancel) {} label: { Text("common.cancel", bundle: .kit) }
            } message: { _ in
                Text("list.remove.confirmMessage", bundle: .kit)
            }
    }
}

/// The paired Macs: name, paired date and last reached, with Remove; the
/// iCloud state and the outcome of the last removal; and the delivery
/// checks this iPhone answered.
struct PairedMacsContent: View {
    let rows: [PairedMacRow]
    let accountNotice: AccountNotice?
    let listNotice: ListNotice?
    let records: [DeliveryRecord]
    let onPair: () -> Void
    let onRemove: (PairedMacRow) -> Void
    let onDismissNotice: () -> Void

    var body: some View {
        ScreenContent(title: "list.title") {
            if let accountNotice {
                NoticeCard(symbol: "icloud.slash", tone: .warning, text: Text(Self.explanation(accountNotice), bundle: .kit))
            }
            if let listNotice {
                HStack(alignment: .top) {
                    NoticeCard(symbol: "info.circle.fill", tone: listNotice == .removalFailed ? .warning : .info,
                               text: Self.text(listNotice))
                    Button(action: onDismissNotice) {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(Text("common.dismiss", bundle: .kit))
                }
            }
            if rows.isEmpty {
                NoticeCard(symbol: "desktopcomputer", text: Text("list.empty", bundle: .kit))
            } else {
                VStack(spacing: 12) {
                    ForEach(rows) { row in
                        MacRow(row: row) { onRemove(row) }
                    }
                }
            }
            Button(action: onPair) {
                Label { Text("list.pair", bundle: .kit) } icon: { Image(systemName: "qrcode.viewfinder") }
            }
            .buttonStyle(ActionButtonStyle())
            if !records.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("list.deliveries.title", bundle: .kit)
                        .font(.headline)
                    ForEach(Array(records.suffix(5).reversed()), id: \.self) { record in
                        Self.recordText(record)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    static func explanation(_ notice: AccountNotice) -> LocalizedStringKey {
        switch notice {
        case .signedOut: return "list.account.signedOut"
        case .restricted: return "list.account.restricted"
        case .unavailable: return "list.account.unavailable"
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

    static func recordText(_ record: DeliveryRecord) -> Text {
        let format = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute().second()
        switch record.source {
        case .push: return Text("list.deliveries.push \(record.arrivedAt, format: format)", bundle: .kit)
        case .polling: return Text("list.deliveries.polling \(record.arrivedAt, format: format)", bundle: .kit)
        }
    }
}

private struct MacRow: View {
    let row: PairedMacRow
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "laptopcomputer")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: row.name)
                    .font(.headline)
                Text("list.pairedOn \(row.pairedAt, format: .dateTime.year().month().day())", bundle: .kit)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let reached = row.lastReachedAt {
                    Text("list.lastReached \(reached, format: .dateTime.year().month().day().hour().minute())", bundle: .kit)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("list.notReached", bundle: .kit)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            Button(action: onRemove) {
                Text("list.remove", bundle: .kit)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }
}
