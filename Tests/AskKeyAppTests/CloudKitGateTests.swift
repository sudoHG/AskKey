import AskKeyDevices
import Foundation
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

/// The App creates the CloudKit transport only when its Info.plist declares
/// the container and its signed entitlements contain it (ADR 0013). These
/// tests check the gate's decision; none creates a container.
@MainActor
final class CloudKitGateTests: AskKeyAppTestCase {
    private let container = "iCloud.com.sudohg.askkey"

    private func entitlements(containers: [String]?, services: [String]? = ["CloudKit"]) -> (String) -> Any? {
        { key in
            switch key {
            case CloudKitGate.containerEntitlement: return containers
            case CloudKitGate.servicesEntitlement: return services
            default: return nil
            }
        }
    }

    func testWithoutTheInfoPlistKeyNothingIsConfiguredAndNoEntitlementIsRead() {
        var reads = 0
        let decision = CloudKitGate.decide(infoDictionary: ["CFBundleIdentifier": "com.sudohg.askkey.app"]) { _ in
            reads += 1
            return [self.container]
        }
        XCTAssertEqual(decision, .notConfigured)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(CloudKitGate.decide(infoDictionary: [CloudKitGate.infoPlistKey: ""],
                                           entitlement: entitlements(containers: [container])), .notConfigured)
    }

    func testWithoutTheContainerInTheSignedEntitlementsNothingIsConfigured() {
        let info: [String: Any] = [CloudKitGate.infoPlistKey: container]
        XCTAssertEqual(CloudKitGate.decide(infoDictionary: info, entitlement: entitlements(containers: nil)), .notConfigured)
        XCTAssertEqual(CloudKitGate.decide(infoDictionary: info, entitlement: entitlements(containers: ["iCloud.example.other"])),
                       .notConfigured)
        XCTAssertEqual(CloudKitGate.decide(infoDictionary: info, entitlement: entitlements(containers: [container], services: nil)),
                       .notConfigured)
        XCTAssertEqual(CloudKitGate.decide(infoDictionary: info,
                                           entitlement: entitlements(containers: [container], services: ["CloudDocuments"])),
                       .notConfigured)
    }

    func testDeclaredAndEntitledContainerIsConfigured() {
        let decision = CloudKitGate.decide(infoDictionary: [CloudKitGate.infoPlistKey: container],
                                           entitlement: entitlements(containers: [container]))
        XCTAssertEqual(decision, .configured(containerIdentifier: container))
        XCTAssertEqual(decision.containerIdentifier, container)
    }

    func testTheInfoPlistKeyIsTheOneTheBuildWritesAndAvoidsTheUpdaterTestingPrefix() {
        XCTAssertEqual(CloudKitGate.infoPlistKey, "CloudKitContainerIdentifier")
        XCTAssertFalse(CloudKitGate.infoPlistKey.hasPrefix(SoftwareUpdateAvailability.testingFlagPrefix))
    }

    func testThisTestProcessIsNotConfigured() {
        XCTAssertEqual(CloudKitGate.currentProcessDecision(), .notConfigured)
    }

    func testWithoutABackendDevicesReportsNotConfiguredAndDoesNothing() async throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        try library.vault.beginManagementSession(using: .allow)
        let coordinator = DeviceCoordinator(environment: DeviceCoordinatorEnvironment(
            vault: library.vault, backend: nil, inboxState: VaultDeviceInboxStateStore(vault: library.vault),
            authenticate: { _ in .authenticated(.allow) }, isManagementSessionActive: { true },
            automaticPolling: false
        ))
        coordinator.start()
        await coordinator.startPairing()
        await coordinator.devicesOpened()
        XCTAssertEqual(coordinator.availability, .notConfigured)
        XCTAssertNil(coordinator.pairing)
        XCTAssertFalse(coordinator.hasIdentity)
        XCTAssertTrue(library.keys.deviceItems.isEmpty)
    }

    func testTheMacPassesEachKeysProtectionExplicitly() {
        let mac = DeviceKeyProtection(accessibility: .afterFirstUnlockThisDeviceOnly, authentication: .none)
        XCTAssertEqual(CloudKitDeviceServicesBackend.macKeyProtections,
                       DeviceKeyProtections(message: mac, agreement: mac, approval: mac))
    }
}
