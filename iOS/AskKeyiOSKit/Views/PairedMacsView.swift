import SwiftUI

/// The home screen: pending requests when there are any, then the paired
/// Macs and pairing as before.
struct PairedMacsView: View {
    @Bindable var model: AppModel
    @State private var selectedMac: String?
    @State private var promptedName = ""

    var body: some View {
        PairedMacsContent(rows: model.pairedMacs, accountNotice: model.accountNotice, listNotice: model.listNotice,
                          records: model.deliveryRecords, hasRequests: !model.requests.isEmpty,
                          onPair: model.startPairing, onSelect: { selectedMac = $0.id },
                          onDismissNotice: { model.listNotice = nil }) {
            RequestList(model: model)
        }
        .screenScaffold()
        .refreshable { await model.processInbox() }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $selectedMac) { id in
            MacDetailView(model: model, macID: id)
        }
        .sheet(item: $model.openedRequest) { opened in
            OpenedRequestView(model: model, id: opened.id) { model.openedRequest = nil }
                .privacyCover(isAuthenticating: model.isAuthenticating)
        }
        .alert(Text("mac.renamedDuplicate.title", bundle: .kit), isPresented: renamePromptShown,
               presenting: model.renamePrompt) { prompt in
            TextField(text: $promptedName) { Text("mac.rename.placeholder", bundle: .kit) }
            Button {
                let name = promptedName
                Task { _ = await model.renameMac(id: prompt.macID, to: name) }
            } label: {
                Text("mac.rename.save", bundle: .kit)
            }
            Button(role: .cancel) { model.renamePrompt = nil } label: { Text("mac.renamedDuplicate.later", bundle: .kit) }
        } message: { prompt in
            Text("mac.renamedDuplicate.message \(Text(verbatim: prompt.takenName)) \(Text(verbatim: prompt.newName))",
                 bundle: .kit)
        }
        .onChange(of: model.renamePrompt) { _, prompt in
            if let prompt { promptedName = prompt.newName }
        }
        .onChange(of: model.openedRequest) { _, opened in
            if opened != nil { selectedMac = nil }
        }
    }

    /// The rename prompt waits until the pairing sheet has closed.
    private var renamePromptShown: Binding<Bool> {
        Binding(get: { model.renamePrompt != nil && model.pairing == nil },
                set: { if !$0 { model.renamePrompt = nil } })
    }
}

/// The requests, then the paired Macs: name, paired date, last reached and
/// whether this iPhone approves its requests; the iCloud state and the
/// outcome of the last removal; and the delivery checks this iPhone answered.
struct PairedMacsContent<Requests: View>: View {
    let rows: [PairedMacRow]
    let accountNotice: AccountNotice?
    let listNotice: ListNotice?
    let records: [DeliveryRecord]
    var hasRequests = false
    let onPair: () -> Void
    let onSelect: (PairedMacRow) -> Void
    let onDismissNotice: () -> Void
    @ViewBuilder var requests: Requests

    var body: some View {
        ScreenContent(title: hasRequests ? "request.section.title" : "list.title") {
            if let accountNotice {
                NoticeCard(symbol: "icloud.slash", tone: .warning, text: Text(Self.explanation(accountNotice), bundle: .kit))
            }
            if hasRequests {
                requests
                Text("list.title", bundle: .kit)
                    .font(.title2.bold())
                    .padding(.top, 8)
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
                        MacRow(row: row) { onSelect(row) }
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

extension PairedMacsContent where Requests == EmptyView {
    init(rows: [PairedMacRow], accountNotice: AccountNotice?, listNotice: ListNotice?, records: [DeliveryRecord],
         onPair: @escaping () -> Void, onSelect: @escaping (PairedMacRow) -> Void,
         onDismissNotice: @escaping () -> Void) {
        self.init(rows: rows, accountNotice: accountNotice, listNotice: listNotice, records: records, hasRequests: false,
                  onPair: onPair, onSelect: onSelect, onDismissNotice: onDismissNotice) { EmptyView() }
    }
}

/// A Mac's row; tapping it opens the Mac's detail.
private struct MacRow: View {
    let row: PairedMacRow
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "laptopcomputer")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: row.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text("list.pairedOn \(row.pairedAt, format: .dateTime.year().month().day())", bundle: .kit)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let reached = row.lastReachedAt {
                        Text("list.lastReached \(reached, format: .dateTime.year().month().day().hour().minute())",
                             bundle: .kit)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("list.notReached", bundle: .kit)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if row.isApprover {
                        Label { Text("list.approver", bundle: .kit) } icon: { Image(systemName: "checkmark.shield.fill") }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }
}
