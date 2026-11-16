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

/// The cover itself: only the app's icon, centered on the grouped
/// background (#351), so nothing on it can come from a request.
struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            AppIconImage(size: 84)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The app's icon as the home screen shows it, on the welcome screen and the
/// privacy cover. It is decorative, so VoiceOver skips it.
///
/// UIKit cannot load the app's compiled `AppIcon` (loading it by name raises
/// an exception), so the kit carries `AppIconArtwork`: the iOS Default and
/// Dark renditions of `assets/AppIcon.icon` at 84 × 84 points and 3×,
/// exported with Icon Composer's `ictool` and already in the icon's shape.
/// Export it again whenever the icon changes.
struct AppIconImage: View {
    let size: CGFloat

    var body: some View {
        Image("AppIconArtwork", bundle: .kit)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            // The light icon is nearly as light as the grouped background.
            .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Covers this view in the app switcher; presented sheets need their own.
    func privacyCover(isAuthenticating: Bool) -> some View {
        modifier(PrivacyCoverModifier(isAuthenticating: isAuthenticating))
    }
}
