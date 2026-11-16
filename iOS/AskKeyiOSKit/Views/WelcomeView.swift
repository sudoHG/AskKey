import SwiftUI

struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        FullScreenScaffold {
            WelcomeContent(biometry: model.biometryKind)
        } actions: {
            WelcomeActions(step: model.welcomeStep) {
                Task { await model.runWelcomeChecks() }
            }
        }
        .readingBiometryKind(model)
        // The checks may run after a visit to Settings that set up Touch ID.
        .onChange(of: model.welcomeStep) { model.readBiometryKind() }
    }
}

/// The welcome screen's content (#351): the app's icon, the title, why the
/// app exists, and three points.
struct WelcomeContent: View {
    var biometry: BiometryKind = .faceID

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppIconImage(size: 72)
                .padding(.bottom, 28)
            FullScreenTitle(title: "welcome.title", detail: "welcome.subtitle")
            VStack(alignment: .leading, spacing: 24) {
                WelcomePoint(symbol: "lock.shield", title: Text("welcome.point.values.title", bundle: .kit),
                             detail: Text("welcome.point.values.detail", bundle: .kit))
                WelcomePoint(symbol: biometry == .touchID ? "touchid" : "faceid", title: biometryTitle,
                             detail: Text("welcome.point.biometry.detail", bundle: .kit))
                WelcomePoint(symbol: "icloud", title: Text("welcome.point.icloud.title", bundle: .kit),
                             detail: Text("welcome.point.icloud.detail", bundle: .kit))
            }
            .padding(.top, 36)
        }
    }

    private var biometryTitle: Text {
        switch biometry {
        case .faceID: return Text("welcome.point.faceID.title", bundle: .kit)
        case .touchID: return Text("welcome.point.touchID.title", bundle: .kit)
        }
    }
}

/// The welcome's actions: a failed check's own explanation, **Continue** (a
/// spinner and "Checking…" while the checks run, **Try Again** after a
/// failure), and the wireless-data prompt some iPhones show before the
/// first network access.
struct WelcomeActions: View {
    let step: WelcomeStep
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if case .failed(let failure) = step {
                FullScreenNotice(text: Text(Self.explanation(failure), bundle: .kit))
            }
            Button(action: onContinue) {
                HStack(spacing: 8) {
                    if step == .checking {
                        ButtonSpinner()
                    }
                    Text(buttonTitle, bundle: .kit)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .disabled(step == .checking)
            Text("welcome.wirelessData", bundle: .kit)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttonTitle: LocalizedStringKey {
        switch step {
        case .intro: return "welcome.continue"
        case .checking: return "welcome.checking"
        case .failed: return "welcome.tryAgain"
        }
    }

    static func explanation(_ failure: WelcomeFailure) -> LocalizedStringKey {
        switch failure {
        case .noSecureEnclave: return "welcome.failure.noSecureEnclave"
        case .biometryNotEnrolled(.faceID): return "welcome.failure.faceIDNotEnrolled"
        case .biometryNotEnrolled(.touchID): return "welcome.failure.touchIDNotEnrolled"
        case .passcodeNotSet: return "welcome.failure.passcodeNotSet"
        case .biometryDenied: return "welcome.failure.biometryDenied"
        case .noBiometry: return "welcome.failure.noBiometry"
        case .cloudNotConfigured: return "welcome.failure.cloudNotConfigured"
        case .iCloudSignedOut: return "welcome.failure.iCloudSignedOut"
        case .iCloudRestricted: return "welcome.failure.iCloudRestricted"
        case .iCloudUnavailable: return "welcome.failure.iCloudUnavailable"
        case .keyCreationFailed: return "welcome.failure.keyCreationFailed"
        case .keychainFailed: return "welcome.failure.keychainFailed"
        case .networkUnavailable: return "welcome.failure.networkUnavailable"
        case .iCloudFailed: return "welcome.failure.iCloudFailed"
        }
    }
}

/// One of the welcome's points: an accent symbol, a bold title and one
/// sentence. At accessibility text sizes the symbol moves above the text,
/// so the text keeps the screen's width.
private struct WelcomePoint: View {
    let symbol: String
    let title: Text
    let detail: Text
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var symbolWidth: CGFloat = 36

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: stacked ? nil : symbolWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                title
                    .font(.headline)
                detail
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Full-screen states

/// A full-screen state without tabs, the welcome and the key reset (#351):
/// the content scrolls, and the actions stay at the bottom of the screen
/// above the home indicator, so the button and any problem above it stay
/// in view on a small iPhone. At accessibility text sizes the actions follow
/// the content instead, so they can never fill the screen.
struct FullScreenScaffold<Content: View, Actions: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView {
                    VStack(spacing: 0) {
                        FullScreenColumn { content }
                        FullScreenActions { actions }
                    }
                }
            } else {
                ScrollView {
                    FullScreenColumn { content }
                }
                .scrollBounceBehavior(.basedOnSize)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    FullScreenActions { actions }
                        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }
}

/// A full-screen state's content, from the top.
struct FullScreenColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 32)
            .padding(.top, 40)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A full-screen state's actions, at the bottom.
struct FullScreenActions<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
    }
}

/// A full-screen state's large title and the sentence under it.
struct FullScreenTitle: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title, bundle: .kit)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text(detail, bundle: .kit)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A notice on a full-screen state, such as a failed check or what the
/// reset deletes: an orange symbol and the text on a grouped card.
struct FullScreenNotice: View {
    let text: Text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            text
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }
}

/// A button's spinner while its work runs. From iOS 18 it is a symbol, so
/// the screen's render shows it too; iOS 17 lacks the symbol and shows the
/// system's spinner.
struct ButtonSpinner: View {
    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                Image(systemName: "progress.indicator")
                    .symbolEffect(.variableColor.iterative)
            } else {
                ProgressView()
            }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Reads which of Face ID and Touch ID this iPhone has when the screen
    /// appears and whenever the app becomes active again, for example after
    /// a visit to Settings. Reading it prompts for nothing.
    func readingBiometryKind(_ model: AppModel) -> some View {
        modifier(BiometryKindReader(model: model))
    }
}

private struct BiometryKindReader: ViewModifier {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { model.readBiometryKind() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.readBiometryKind() }
            }
    }
}
