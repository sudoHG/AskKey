import SwiftUI

/// One paired Mac: its name on this iPhone, whether this iPhone approves
/// its requests, and removal, which is how approval stops (ADR 0014,
/// amended by #336).
struct MacDetailView: View {
    @Bindable var model: AppModel
    let macID: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var renameProblem: RenameProblem?
    @State private var removalFailed = false

    private var row: PairedMacRow? { model.pairedMacs.first { $0.id == macID } }

    var body: some View {
        Group {
            if let row {
                MacDetailContent(row: row, renameProblem: renameProblem, removalFailed: removalFailed,
                                 onRename: {
                                     newName = row.name
                                     renaming = true
                                 },
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
        .confirmationDialog(MacRemovalText.title(row?.name ?? String()), isPresented: $confirmingRemoval,
                            titleVisibility: .visible) {
            Button(role: .destructive) {
                removalFailed = false
                Task {
                    await model.removeMac(id: macID)
                    // A removal that succeeded closes this screen.
                    removalFailed = row != nil && model.listNotice == .removalFailed
                }
            } label: {
                MacRemovalText.confirm
            }
            Button(role: .cancel) {} label: { Text("common.cancel", bundle: .kit) }
        } message: {
            MacRemovalText.message
        }
    }
}

/// **Remove**'s confirmation, in the dialog and in its render: this iPhone
/// stops at once, drops the Mac's pending requests and tells the Mac, which
/// stops trusting this iPhone only when it processes the unpair notice
/// (ADR 0014 → Revocation, decision 3 of the #336 amendment).
enum MacRemovalText {
    static func title(_ name: String) -> Text { Text("list.remove.confirmTitle \(name)", bundle: .kit) }
    static var message: Text { Text("list.remove.confirmMessage", bundle: .kit) }
    static var confirm: Text { Text("list.remove.confirm", bundle: .kit) }
}

struct MacDetailContent: View {
    let row: PairedMacRow
    var renameProblem: RenameProblem?
    var removalFailed = false
    let onRename: () -> Void
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
            // Pairing sets the flag; only a Mac paired before #336 without
            // approval lacks it, and only pairing again can set it.
            if row.isApprover {
                NoticeCard(symbol: "checkmark.shield.fill", tone: .success,
                           text: Text("mac.status.approving", bundle: .kit))
            } else {
                NoticeCard(symbol: "exclamationmark.shield.fill", tone: .warning,
                           text: Text("mac.status.notApproving", bundle: .kit))
            }
            if removalFailed {
                NoticeCard(symbol: "exclamationmark.triangle.fill", tone: .warning,
                           text: Text("list.notice.removalFailed", bundle: .kit))
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
