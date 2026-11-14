import SwiftUI

/// One paired Mac: its name on this iPhone, whether this iPhone approves
/// its requests, and removal.
struct MacDetailView: View {
    @Bindable var model: AppModel
    let macID: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingStop = false
    @State private var confirmingRemoval = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var renameProblem: RenameProblem?
    @State private var stopFailed = false

    private var row: PairedMacRow? { model.pairedMacs.first { $0.id == macID } }

    var body: some View {
        Group {
            if let row {
                MacDetailContent(row: row, renameProblem: renameProblem, stopFailed: stopFailed,
                                 onRename: {
                                     newName = row.name
                                     renaming = true
                                 },
                                 onApprove: { model.startApproverConfirmation(macID: macID) },
                                 onStop: { confirmingStop = true },
                                 onRemove: { confirmingRemoval = true })
            }
        }
        .screenScaffold()
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: row == nil) { _, gone in
            if gone { dismiss() }
        }
        .alert(Text("mac.rename.title", bundle: .kit), isPresented: $renaming) {
            TextField(text: $newName) { Text("mac.rename.placeholder", bundle: .kit) }
            Button {
                let name = newName
                Task { renameProblem = await model.renameMac(id: macID, to: name) }
            } label: {
                Text("mac.rename.save", bundle: .kit)
            }
            Button(role: .cancel) {} label: { Text("common.cancel", bundle: .kit) }
        } message: {
            Text("mac.rename.message", bundle: .kit)
        }
        .confirmationDialog(Text("mac.stop.confirmTitle \(row?.name ?? String())", bundle: .kit),
                            isPresented: $confirmingStop, titleVisibility: .visible) {
            Button(role: .destructive) {
                Task { stopFailed = !(await model.stopApproving(macID: macID)) }
            } label: {
                Text("mac.stop.confirm", bundle: .kit)
            }
            Button(role: .cancel) {} label: { Text("common.cancel", bundle: .kit) }
        } message: {
            Text("mac.stop.confirmMessage", bundle: .kit)
        }
        .confirmationDialog(Text("list.remove.confirmTitle \(row?.name ?? String())", bundle: .kit),
                            isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(role: .destructive) {
                Task { await model.removeMac(id: macID) }
            } label: {
                Text("list.remove.confirm", bundle: .kit)
            }
            Button(role: .cancel) {} label: { Text("common.cancel", bundle: .kit) }
        } message: {
            Text("list.remove.confirmMessage", bundle: .kit)
        }
        .sheet(item: $model.approverConfirmation, onDismiss: model.closeApproverConfirmation) { flow in
            ApproverConfirmationView(model: model, flow: flow)
        }
    }
}

struct MacDetailContent: View {
    let row: PairedMacRow
    var renameProblem: RenameProblem?
    var stopFailed = false
    let onRename: () -> Void
    let onApprove: () -> Void
    let onStop: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: row.name)
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text("list.pairedOn \(row.pairedAt, format: .dateTime.year().month().day())", bundle: .kit)
                    .foregroundStyle(.secondary)
                if let reached = row.lastReachedAt {
                    Text("list.lastReached \(reached, format: .dateTime.year().month().day().hour().minute())", bundle: .kit)
                        .foregroundStyle(.secondary)
                } else {
                    Text("list.notReached", bundle: .kit)
                        .foregroundStyle(.orange)
                }
                Button(action: onRename) { Text("mac.rename", bundle: .kit).font(.subheadline.weight(.semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
            if let renameProblem {
                NoticeCard(symbol: "exclamationmark.triangle.fill", tone: .warning, text: Self.text(renameProblem))
            }
            VStack(alignment: .leading, spacing: 12) {
                if stopFailed {
                    NoticeCard(symbol: "exclamationmark.triangle.fill", tone: .warning,
                               text: Text("mac.stop.failed", bundle: .kit))
                }
                NoticeCard(symbol: row.isApprover ? "checkmark.shield.fill" : "shield.slash",
                           tone: row.isApprover ? .success : .info,
                           text: Text(row.isApprover ? "mac.status.approving" : "mac.status.notApproving", bundle: .kit))
                // The iPhone cannot learn whether the Mac accepted; once its flag
                // is on, the button only sends a new code.
                Button(action: onApprove) { Text(row.isApprover ? "mac.approveAgain" : "mac.approve", bundle: .kit) }
                    .buttonStyle(ActionButtonStyle(kind: row.isApprover ? .secondary : .primary))
                if row.isApprover {
                    Button(action: onStop) { Text("mac.stop", bundle: .kit) }
                        .buttonStyle(ActionButtonStyle(kind: .destructive))
                }
            }
            Button(action: onRemove) { Text("list.remove", bundle: .kit) }
                .buttonStyle(ActionButtonStyle(kind: .destructive))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func text(_ problem: RenameProblem) -> Text {
        switch problem {
        case .empty: return Text("mac.rename.empty", bundle: .kit)
        case .duplicate(let name): return Text("mac.rename.duplicate \(Text(verbatim: name))", bundle: .kit)
        case .failed: return Text("mac.rename.failed", bundle: .kit)
        }
    }
}
