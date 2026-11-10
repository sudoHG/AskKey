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
    /// Only the production executable passes one; the App still creates the
    /// updater only when `SoftwareUpdateAvailability` allows it.
    package let makeSoftwareUpdater: SoftwareUpdaterFactory?
    /// The device services' backend (ADR 0013). The production executable
    /// passes none: the App then creates the CloudKit backend only when
    /// `CloudKitGate` allows it. The E2E App passes a fake.
    package let makeDeviceServices: DeviceServicesFactory?

    package init(
        makeViewModel: (() -> VaultViewModel)? = nil,
        prepareServices: (() -> Void)? = nil,
        didStart: (() -> Void)? = nil,
        willStop: (() -> Void)? = nil,
        startClient: (() -> Bool)? = nil,
        makeSoftwareUpdater: SoftwareUpdaterFactory? = nil,
        makeDeviceServices: DeviceServicesFactory? = nil
    ) {
        self.makeViewModel = makeViewModel
        self.prepareServices = prepareServices
        self.didStart = didStart
        self.willStop = willStop
        self.startClient = startClient
        self.makeSoftwareUpdater = makeSoftwareUpdater
        self.makeDeviceServices = makeDeviceServices
    }

    package static var production: Self { Self() }
}

package typealias DeviceServicesFactory = @MainActor () -> any DeviceServicesBackend

extension VaultViewModel {
    package static func configured(
        languageMode: String,
        appearanceMode: String,
        completedOnboarding: Bool,
        unlockVault: @escaping () throws -> Void,
        authenticateDeviceOwner: @escaping @MainActor (ManagementAuthenticationPresentation) async -> ManagementAuthenticationResult,
        loginItemIsEnabled: @escaping () -> Bool,
        setLoginItemEnabled: @escaping (Bool) throws -> Void,
        onboardingOperations: AgentOnboardingOperations
    ) -> VaultViewModel {
        let preferences = AppPreferences()
        preferences.languageMode = languageMode
        preferences.appearanceMode = appearanceMode
        preferences.hasCompletedOnboarding = completedOnboarding
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
