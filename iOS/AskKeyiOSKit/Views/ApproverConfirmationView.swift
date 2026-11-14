import SwiftUI

/// **Approve Requests from This Mac**: the code from the Mac's screen in a
/// plain numeric field (not a one-time-code field), then Face ID.
struct ApproverConfirmationView: View {
    let model: AppModel
    let flow: ApproverConfirmationFlow
    @State private var code = ""
    @FocusState private var focused: Bool

    private var current: ApproverConfirmationFlow { model.approverConfirmation ?? flow }

    var body: some View {
        ApproverConfirmationContent(flow: current, onConfirm: confirm, onClose: model.closeApproverConfirmation) {
            TextField(text: $code) { Text("approver.field", bundle: .kit) }
                .keyboardType(.numberPad)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.title2.monospaced())
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(confirm)
        }
        .screenScaffold()
        .privacyCover(isAuthenticating: model.isAuthenticating)
        .interactiveDismissDisabled(current.stage == .confirming)
        .onAppear { focused = true }
        .onChange(of: current.stage) { _, stage in
            // The typed code is not kept once it was used.
            if stage != .entering && stage != .confirming { code = "" }
        }
    }

    private func confirm() {
        let typed = code
        Task { await model.confirmApprover(typed: typed) }
    }
}

struct ApproverConfirmationContent<Field: View>: View {
    let flow: ApproverConfirmationFlow
    let onConfirm: () -> Void
    let onClose: () -> Void
    @ViewBuilder var field: Field

    var body: some View {
        ScreenContent(title: "approver.title", subtitle: "approver.subtitle \(flow.macName)") {
            switch flow.stage {
            case .entering, .confirming:
                NoticeCard(symbol: "lock.shield", tone: .warning, text: Text("approver.onlyOnMac", bundle: .kit))
                NoticeCard(symbol: "iphone", text: Text("approver.whatArrives", bundle: .kit))
                field
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground)))
                if let problem = flow.problem {
                    NoticeCard(symbol: "exclamationmark.triangle.fill", tone: .warning, text: Self.text(problem))
                }
                Button(action: onConfirm) {
                    Text(flow.stage == .confirming ? "approver.confirming" : "approver.confirm", bundle: .kit)
                }
                .buttonStyle(ActionButtonStyle())
                .disabled(flow.stage == .confirming)
                Text("pairing.confirm.footnote", bundle: .kit)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(action: onClose) { Text("common.cancel", bundle: .kit) }
                    .buttonStyle(ActionButtonStyle(kind: .secondary))
                    .disabled(flow.stage == .confirming)
            case .sending:
                NoticeCard(symbol: "arrow.up.circle", text: Text("approver.sending", bundle: .kit))
                if let problem = flow.problem {
                    NoticeCard(symbol: "exclamationmark.triangle.fill", tone: .warning, text: Self.text(problem))
                }
                Button(action: onClose) { Text("common.done", bundle: .kit) }
                    .buttonStyle(ActionButtonStyle(kind: .secondary))
            case .sent:
                NoticeCard(symbol: "checkmark.circle.fill", tone: .success,
                           text: Text("approver.sent \(Text(verbatim: flow.macName))", bundle: .kit))
                Button(action: onClose) { Text("common.done", bundle: .kit) }
                    .buttonStyle(ActionButtonStyle())
            }
        }
    }

    static func text(_ problem: ApproverProblem) -> Text {
        switch problem {
        case .invalidCode: return Text("approver.problem.invalidCode", bundle: .kit)
        case .cancelled: return Text("pairing.confirm.cancelled", bundle: .kit)
        case .failed: return Text("pairing.confirm.failed", bundle: .kit)
        case .unavailable: return Text("pairing.confirm.unavailable", bundle: .kit)
        case .account: return Text("request.problem.account", bundle: .kit)
        case .retrying: return Text("approver.problem.retrying", bundle: .kit)
        case .notSent: return Text("approver.problem.notSent", bundle: .kit)
        case .other: return Text("approver.problem.other", bundle: .kit)
        }
    }
}
