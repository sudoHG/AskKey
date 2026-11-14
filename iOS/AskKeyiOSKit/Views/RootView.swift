import SwiftUI

/// The app's only scene content, covered in the app switcher.
public struct AskKeyRootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            switch model.stage {
            case .starting:
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            case .welcome:
                WelcomeView(model: model)
            case .ready:
                NavigationStack {
                    PairedMacsView(model: model)
                }
            case .unusableIdentity:
                UnusableIdentityView(model: model)
            }
        }
        .privacyCover(isAuthenticating: model.isAuthenticating)
        .sheet(item: $model.pairing, onDismiss: model.closePairing) { flow in
            PairingFlowView(model: flow, onClose: model.closePairing)
                .privacyCover(isAuthenticating: model.isAuthenticating)
        }
        .task { await model.start() }
        .task(id: model.stage == .ready && scenePhase == .active) {
            // The foreground poll: every 10 seconds, every 2 while a request waits.
            guard model.stage == .ready, scenePhase == .active else { return }
            await model.runForegroundPolling()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.becameActive() } }
        }
        .onChange(of: model.stage) { _, stage in
            if stage == .ready { Task { await model.becameActive() } }
        }
    }
}

struct UnusableIdentityView: View {
    let model: AppModel
    @State private var confirming = false

    var body: some View {
        UnusableIdentityContent(isResetting: model.isResetting, resetFailed: model.resetFailed) { confirming = true }
            .screenScaffold()
            .confirmationDialog(Text("unusable.confirmTitle", bundle: .kit), isPresented: $confirming,
                                titleVisibility: .visible) {
                Button(role: .destructive) {
                    Task { await model.resetIdentity() }
                } label: {
                    Text("unusable.reset", bundle: .kit)
                }
                Button(role: .cancel) {} label: { Text("common.cancel", bundle: .kit) }
            }
    }
}

/// A stored key no longer works, for example after a Face ID or Touch ID
/// enrollment change; one reset deletes the keys and the list.
struct UnusableIdentityContent: View {
    let isResetting: Bool
    let resetFailed: Bool
    let onReset: () -> Void

    var body: some View {
        ScreenContent(title: "unusable.title", subtitle: "unusable.detail") {
            NoticeCard(symbol: "arrow.counterclockwise", tone: .warning, text: Text("unusable.consequence", bundle: .kit))
            if resetFailed {
                NoticeCard(symbol: "exclamationmark.triangle.fill", tone: .warning, text: Text("unusable.failed", bundle: .kit))
            }
            Button(action: onReset) {
                Text(isResetting ? "unusable.resetting" : "unusable.reset", bundle: .kit)
            }
            .buttonStyle(ActionButtonStyle(kind: .destructive))
            .disabled(isResetting)
        }
    }
}
