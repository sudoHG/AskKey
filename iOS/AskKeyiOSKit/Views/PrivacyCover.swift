import SwiftUI

/// The privacy cover (ADR 0014 → iPhone app → Privacy): the window is
/// covered when the app moves to the background, and when it becomes
/// inactive while no Face ID or Touch ID prompt is running, so app-switcher
/// snapshots show no request. The prompt itself makes the app inactive and
/// must see the card it is about.
enum PrivacyCover {
    static func isShown(phase: ScenePhase, authenticating: Bool) -> Bool {
        switch phase {
        case .background: return true
        case .inactive: return !authenticating
        case .active: return false
        @unknown default: return true
        }
    }
}

struct PrivacyCoverModifier: ViewModifier {
    let isAuthenticating: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.overlay {
            if PrivacyCover.isShown(phase: scenePhase, authenticating: isAuthenticating) {
                PrivacyCoverView()
            }
        }
    }
}

struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            VStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Color.accentColor)
                Text("common.appName", bundle: .kit)
                    .font(.title2.bold())
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    /// Covers this view in the app switcher; presented sheets need their own.
    func privacyCover(isAuthenticating: Bool) -> some View {
        modifier(PrivacyCoverModifier(isAuthenticating: isAuthenticating))
    }
}
