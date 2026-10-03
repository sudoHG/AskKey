import AskKeyVault

/// Optional startup services are installed explicitly by the executable.
/// The ordinary app uses production defaults without consulting environment flags.
@MainActor
package struct AppRuntimeConfiguration {
    package let makeViewModel: (() -> VaultViewModel)?
    package let prepareServices: (() -> Void)?
    package let didStart: (() -> Void)?
    package let willStop: (() -> Void)?
    package let startClient: (() -> Bool)?

    package init(
        makeViewModel: (() -> VaultViewModel)? = nil,
        prepareServices: (() -> Void)? = nil,
        didStart: (() -> Void)? = nil,
        willStop: (() -> Void)? = nil,
        startClient: (() -> Bool)? = nil
    ) {
        self.makeViewModel = makeViewModel
        self.prepareServices = prepareServices
        self.didStart = didStart
        self.willStop = willStop
        self.startClient = startClient
    }

    package static var production: Self { Self() }
}

extension VaultViewModel {
    package static func configured(
        languageMode: String,
        appearanceMode: String,
        completedOnboarding: Bool,
        readApprovalAuthenticationEnabled: Bool,
        unlockVault: @escaping () throws -> Void,
        authenticateDeviceOwner: @escaping @MainActor (ManagementAuthenticationPresentation) async -> ManagementAuthenticator?,
        loginItemIsEnabled: @escaping () -> Bool,
        setLoginItemEnabled: @escaping (Bool) throws -> Void,
        onboardingOperations: AgentOnboardingOperations
    ) -> VaultViewModel {
        let preferences = AppPreferences()
        preferences.languageMode = languageMode
        preferences.appearanceMode = appearanceMode
        preferences.hasCompletedOnboarding = completedOnboarding
        preferences.readApprovalAuthenticationEnabled = readApprovalAuthenticationEnabled
        let model = VaultViewModel(
            unlockVault: unlockVault,
            authenticateDeviceOwner: authenticateDeviceOwner,
            preferences: preferences,
            loginItem: LoginItemController(isEnabled: loginItemIsEnabled, setEnabled: setLoginItemEnabled)
        )
        model.onboarding.operations = onboardingOperations
        return model
    }
}
