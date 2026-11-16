import SwiftUI

struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        WelcomeContent(step: model.welcomeStep, biometry: model.biometryKind) {
            Task { await model.runWelcomeChecks() }
        }
        .tabScaffold()
        // Which of Face ID and Touch ID the point names; reading it prompts for nothing.
        .onAppear { model.readBiometryKind() }
    }
}

/// The welcome screen (#351): the app's icon, why the app exists in three
/// points, **Continue** at the bottom with the wireless-data prompt some
/// iPhones show before the first network access, and each failed check
/// above the button.
struct WelcomeContent: View {
    let step: WelcomeStep
    var biometry: BiometryKind = .faceID
    let onContinue: () -> Void

    var body: some View {
        FullScreenLayout {
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
        } bottom: {
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

    private var biometryTitle: Text {
        switch biometry {
        case .faceID: return Text("welcome.point.faceID.title", bundle: .kit)
        case .touchID: return Text("welcome.point.touchID.title", bundle: .kit)
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

/// One of the welcome's points: an accent symbol, a bold title and one sentence.
private struct WelcomePoint: View {
    let symbol: String
    let title: Text
    let detail: Text
    @ScaledMetric(relativeTo: .title2) private var symbolWidth: CGFloat = 36

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: symbolWidth)
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
/// the content from the top and the actions at the bottom. In the app,
/// `tabScaffold()` makes it at least as tall as the screen and lets it
/// scroll when it is taller, as with large Dynamic Type sizes.
struct FullScreenLayout<Content: View, Bottom: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var bottom: Bottom

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .padding(.horizontal, 8)
            Spacer(minLength: 32)
            VStack(spacing: 14) { bottom }
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// A button's spinner while its work runs, drawn as a symbol so the
/// screen's render shows it too.
struct ButtonSpinner: View {
    var body: some View {
        Image(systemName: "progress.indicator")
            .symbolEffect(.variableColor.iterative)
            .accessibilityHidden(true)
    }
}
