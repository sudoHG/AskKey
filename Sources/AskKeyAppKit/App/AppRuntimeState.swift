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
            alert.messageText = "请使用隔离启动脚本"
            alert.informativeText = "此测试版本需要显式指定隔离数据目录。请通过交付包中的启动脚本打开。"
            alert.runModal()
            exit(78)
        }
#endif
        normalRuntimeInitialized = true
        if let makeViewModel = configuration.makeViewModel { return makeViewModel() }
        return VaultViewModel()
    }

}
