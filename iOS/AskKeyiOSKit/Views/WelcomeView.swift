import SwiftUI

struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        WelcomeContent(step: model.welcomeStep) {
            Task { await model.runWelcomeChecks() }
        }
        .screenScaffold()
    }
}

/// The welcome screen: what the app needs, the wireless-data prompt some
/// iPhones show before the first network access, and each failed check.
struct WelcomeContent: View {
    let step: WelcomeStep
    let onContinue: () -> Void

    var body: some View {
        ScreenContent(title: "welcome.title", subtitle: "welcome.subtitle") {
            VStack(alignment: .leading, spacing: 16) {
                requirement("lock.shield", "welcome.requirement.secureEnclave")
                requirement("faceid", "welcome.requirement.biometry")
                requirement("icloud", "welcome.requirement.icloud")
                requirement("bell.badge", "welcome.requirement.notifications")
            }
            NoticeCard(symbol: "antenna.radiowaves.left.and.right", text: Text("welcome.wirelessData", bundle: .kit))
            if case .failed(let failure) = step {
                NoticeCard(symbol: "exclamationmark.triangle.fill", tone: .warning,
                           text: Text(Self.explanation(failure), bundle: .kit))
            }
            Button(action: onContinue) {
                Text(buttonTitle, bundle: .kit)
            }
            .buttonStyle(ActionButtonStyle())
            .disabled(step == .checking)
        }
    }

    private var buttonTitle: LocalizedStringKey {
        switch step {
        case .intro: return "welcome.continue"
        case .checking: return "welcome.checking"
        case .failed: return "welcome.tryAgain"
        }
    }

    private func requirement(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            Text(text, bundle: .kit)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
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
