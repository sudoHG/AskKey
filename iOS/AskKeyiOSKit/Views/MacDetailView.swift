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
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let row {
                MacDetailContent(row: row, now: context.date, renameProblem: renameProblem,
                                 removalFailed: removalFailed,
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
                    let removed = await model.removeMac(id: macID)
                    // A removal that succeeded closes this screen.
                    removalFailed = !removed && row != nil
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

/// The Mac's detail as a grouped list: the Mac, whether this iPhone
/// approves its requests (#342's status line), when it was paired and last
/// reached, Rename, and Remove in its own section.
struct MacDetailContent: View {
    let row: PairedMacRow
    var now: Date = .now
    var renameProblem: RenameProblem?
    var removalFailed = false
    let onRename: () -> Void
    let onRemove: () -> Void
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .largeTitle) private var circle: CGFloat = 84

    var body: some View {
        VStack(spacing: 24) {
            header
            GroupedSection {
                ValueRow {
                    Text("mac.detail.paired", bundle: .kit)
                } value: {
                    Text(row.pairedAt, format: .dateTime.year().month().day()).foregroundStyle(.secondary)
                }
                GroupedDivider()
                ValueRow {
                    Text("mac.detail.lastReached", bundle: .kit)
                } value: {
                    if let reached = row.lastReachedAt {
                        Text(verbatim: RelativeTime.text(reached, now: now, locale: locale)).foregroundStyle(.secondary)
                    } else {
                        Text("list.notReached", bundle: .kit).foregroundStyle(.orange)
                    }
                }
            }
            GroupedSection {
                Button(action: onRename) {
                    Text("mac.rename", bundle: .kit)
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .frame(minHeight: GroupedMetrics.rowMinHeight)
                }
                .buttonStyle(GroupedRowButtonStyle())
            } footer: {
                if let renameProblem {
                    Self.text(renameProblem).foregroundStyle(.orange)
                } else {
                    Text("mac.rename.message", bundle: .kit)
                }
            }
            GroupedSection {
                Button(role: .destructive, action: onRemove) {
                    Text("list.remove", bundle: .kit)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .frame(minHeight: GroupedMetrics.rowMinHeight)
                }
                .buttonStyle(GroupedRowButtonStyle())
            } footer: {
                // What removing does is #342's confirmation, word for word.
                if removalFailed {
                    Text("list.notice.removalFailed", bundle: .kit).foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// The Mac, its name and the status line. Pairing sets the flag; only a
    /// Mac paired before #336 without approval lacks it, and only pairing
    /// again can set it. A Mac whose removal failed is refused here too
    /// (`PairedMacRow`).
    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .frame(width: circle, height: circle)
                .background(Circle().fill(Color(uiColor: .secondarySystemGroupedBackground)))
                .accessibilityHidden(true)
            Text(verbatim: row.name)
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: row.isApprover ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(row.isApprover ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                Text(row.isApprover ? "mac.status.approving" : "mac.status.notApproving", bundle: .kit)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
    }

    static func text(_ problem: RenameProblem) -> Text {
        switch problem {
        case .empty: return Text("mac.rename.empty", bundle: .kit)
        case .duplicate(let name): return Text("mac.rename.duplicate \(Text(verbatim: name))", bundle: .kit)
        case .failed: return Text("mac.rename.failed", bundle: .kit)
        }
    }
}
