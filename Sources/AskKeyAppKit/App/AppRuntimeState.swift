import AppKit
import AskKeyVault

@MainActor
enum AppRuntimeState {
    private(set) static var normalRuntimeInitialized = false
    static var configuration = AppRuntimeConfiguration.production

    static func makeVaultViewModel() -> VaultViewModel {
#if DEBUG
        if Bundle.main.object(forInfoDictionaryKey: "AskKeyRequiresDebugRunDirectory") as? Bool == true,
           VaultConfiguration.debugRunDirectory == nil {
            let alert = NSAlert()
            let language = AppLanguage.resolve(mode: "system")
            alert.messageText = AppLanguage.localized("Use the isolated launch script", language: language)
            alert.informativeText = AppLanguage.localized(
                "This test build requires an explicit isolated data directory. Open it using the launch script in the delivery package.",
                language: language
            )
            alert.runModal()
            exit(78)
        }
#endif
        normalRuntimeInitialized = true
        if let makeViewModel = configuration.makeViewModel { return makeViewModel() }
        return VaultViewModel()
    }

}
