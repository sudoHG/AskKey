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
                HomeTabs(model: model)
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
            if phase == .active { Task { await model.sceneBecameActive() } }
        }
        .onChange(of: model.stage) { _, stage in
            if stage == .ready { Task { await model.becameActive() } }
        }
    }
}

/// The home: Requests, History and Macs, each with its own navigation and
/// large title (ADR 0014 → iPhone app, Home, amended by #345). The Requests
/// tab's badge counts the requests that can still be decided. A request's
/// page opens as a sheet over every tab, from a row or a tapped
/// notification, never by itself when a request arrives.
struct HomeTabs: View {
    @Bindable var model: AppModel
    @State private var promptedName = ""

    var body: some View {
        // Redrawn when a request's countdown ends, so the badge drops it.
        TimelineView(.explicit(model.decidableCountChanges)) { context in
            TabView(selection: $model.selectedTab) {
                NavigationStack { RequestsView(model: model) }
                    .tabItem { HomeTab.requests.label }
                    .tag(HomeTab.requests)
                    .badge(model.decidableRequestCount(at: max(context.date, Date())))
                NavigationStack { HistoryView(model: model) }
                    .tabItem { HomeTab.history.label }
                    .tag(HomeTab.history)
                NavigationStack { MacsView(model: model) }
                    .tabItem { HomeTab.macs.label }
                    .tag(HomeTab.macs)
            }
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
    }

    /// The rename prompt waits until the pairing sheet has closed.
    private var renamePromptShown: Binding<Bool> {
        Binding(get: { model.renamePrompt != nil && model.pairing == nil },
                set: { if !$0 { model.renamePrompt = nil } })
    }
}

extension HomeTab {
    /// The tab's name, also its navigation title.
    var title: LocalizedStringKey {
        switch self {
        case .requests: return "tab.requests"
        case .history: return "tab.history"
        case .macs: return "tab.macs"
        }
    }

    /// The tab's symbol; the tab bar fills it where a filled form exists.
    var symbol: String {
        switch self {
        case .requests: return "tray"
        case .history: return "clock.arrow.circlepath"
        case .macs: return "laptopcomputer"
        }
    }

    var label: some View {
        Label { Text(title, bundle: .kit) } icon: { Image(systemName: symbol) }
    }
}

struct UnusableIdentityView: View {
    let model: AppModel
    @State private var confirming = false

    var body: some View {
        FullScreenScaffold {
            UnusableIdentityContent(biometry: model.biometryKind)
        } actions: {
            UnusableIdentityActions(isResetting: model.isResetting, resetFailed: model.resetFailed) { confirming = true }
        }
        .readingBiometryKind(model)
        .confirmationDialog(UnusableResetText.title, isPresented: $confirming, titleVisibility: .visible) {
            Button(role: .destructive) {
                Task { await model.resetIdentity() }
            } label: {
                UnusableResetText.confirm
            }
            Button(role: .cancel) {} label: { Text("common.cancel", bundle: .kit) }
        } message: {
            UnusableResetText.message
        }
    }
}

/// **Reset This iPhone**'s confirmation, in the dialog and in its render.
enum UnusableResetText {
    static var title: Text { Text("unusable.confirmTitle", bundle: .kit) }
    static var message: Text { Text("unusable.confirmMessage", bundle: .kit) }
    static var confirm: Text { Text("unusable.reset", bundle: .kit) }
}

/// A stored key no longer works, for example after a Face ID or Touch ID
/// enrollment change; one reset deletes the keys and the list (#351): a key
/// with a slash in an orange circle, the cause, and what the reset deletes
/// and what to do next.
struct UnusableIdentityContent: View {
    var biometry: BiometryKind = .faceID
    @ScaledMetric(relativeTo: .largeTitle) private var circle: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "key.slash")
                .font(.largeTitle.weight(.medium))
                .foregroundStyle(.orange)
                .frame(width: circle, height: circle)
                .background(Circle().fill(Color.orange.opacity(0.15)))
                .padding(.bottom, 28)
                .accessibilityHidden(true)
            FullScreenTitle(title: "unusable.title",
                            detail: biometry == .touchID ? "unusable.detail.touchID" : "unusable.detail")
            FullScreenNotice(text: Text("unusable.consequence", bundle: .kit))
                .padding(.top, 28)
        }
    }
}

/// The reset screen's actions: a failed reset's notice and **Reset This
/// iPhone**, which asks for confirmation first.
struct UnusableIdentityActions: View {
    let isResetting: Bool
    let resetFailed: Bool
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if resetFailed {
                FullScreenNotice(text: Text("unusable.failed", bundle: .kit))
            }
            Button(role: .destructive, action: onReset) {
                HStack(spacing: 8) {
                    if isResetting {
                        ButtonSpinner()
                    }
                    Text(isResetting ? "unusable.resetting" : "unusable.reset", bundle: .kit)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .disabled(isResetting)
        }
    }
}
