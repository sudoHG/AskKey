import AskKeyiOSKit
import SwiftUI

/// Only starts the app; every behavior lives in `AskKeyiOSKit`.
@main
struct AskKeyiOSApp: App {
    @UIApplicationDelegateAdaptor(AskKeyAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            AskKeyRootView(model: delegate.model)
        }
    }
}
