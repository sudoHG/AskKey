import SwiftUI
import AskKeyVault

package struct AskKeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    package init() {}

    @MainActor package static func run(configuration: AppRuntimeConfiguration? = nil) {
        precondition(!AppRuntimeState.normalRuntimeInitialized)
        AppRuntimeState.configuration = configuration ?? .production
        Self.main()
    }

    package var body: some Scene {
        MenuBarExtra(isInserted: .constant(!ManagementAuthenticationSubprocess.isActive)) {
            VaultPopover(onOpenManagement: appDelegate.openManagementWindow)
                .environment(appDelegate.vault)
                .environment(\.locale, appDelegate.vault.appLocale)
        } label: {
            MenuBarIcon()
            if appDelegate.pendingApprovalCount > 0 {
                Text("\(appDelegate.pendingApprovalCount)")
            }
            if VaultConfiguration.isDevelopmentBuild {
                Text("DEV")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
