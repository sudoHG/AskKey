// swift-tools-version: 6.0
import PackageDescription
import Foundation

let package = Package(
    name: "AskKey",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AskKeyBroker", targets: ["AskKeyBroker"]),
        .library(name: "AskKeyVault", targets: ["AskKeyVault"]),
        .library(name: "AskKeySystem", targets: ["AskKeySystem"]),
        .library(name: "AskKeyIntegrations", targets: ["AskKeyIntegrations"]),
        .executable(name: "askkey", targets: ["AskKeyHelper"]),
        .executable(name: "AskKeyApp", targets: ["AskKeyApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "AskKeyBroker",
            dependencies: ["AskKeyBrokerC"],
            path: "Sources/AskKeyBroker",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AskKeyBrokerC",
            path: "Sources/AskKeyBrokerC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AskKeySystem",
            path: "Sources/AskKeySystem",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AskKeyIntegrations",
            dependencies: ["AskKeySystem", "AskKeyBroker"],
            path: "Sources/AskKeyIntegrations",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AskKeyVault",
            dependencies: [
                "AskKeySystem",
                "AskKeyBroker",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/AskKeyVault",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AskKeyHelper",
            dependencies: ["AskKeyBroker"],
            path: "Sources/AskKeyHelper",
            resources: [.copy("Resources/Localizable.xcstrings")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AskKeyAppKit",
            dependencies: [
                "AskKeyBroker",
                "AskKeyVault",
                "AskKeySystem",
                "AskKeyIntegrations",
            ],
            path: "Sources/AskKeyAppKit",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AskKeyApp",
            dependencies: ["AskKeyAppKit"],
            path: "Sources/AskKeyApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AskKeyBrokerTests",
            dependencies: ["AskKeyBroker"],
            path: "Tests/AskKeyBrokerTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AskKeyTestSupport",
            dependencies: ["AskKeyAppKit", "AskKeyVault", "AskKeySystem", "AskKeyBroker"],
            path: "Tests/AskKeyTestSupport",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AskKeyE2EApp",
            dependencies: ["AskKeyAppKit", "AskKeyTestSupport"],
            path: "Tests/AskKeyE2EApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AskKeyUnitTestSupport",
            path: "Tests/AskKeyUnitTestSupport",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AskKeySystemTests",
            dependencies: ["AskKeySystem"],
            path: "Tests/AskKeySystemTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AskKeyIntegrationsTests",
            dependencies: ["AskKeyBroker", "AskKeySystem", "AskKeyIntegrations", "AskKeyHelper", "AskKeyUnitTestSupport"],
            path: "Tests/AskKeyIntegrationsTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AskKeyVaultTests",
            dependencies: ["AskKeyBroker", "AskKeyVault", "AskKeyHelper", "AskKeyUnitTestSupport"],
            path: "Tests/AskKeyVaultTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AskKeyAppTests",
            dependencies: ["AskKeyAppKit", "AskKeyVault", "AskKeySystem", "AskKeyIntegrations", "AskKeyTestSupport"],
            path: "Tests/AskKeyAppTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

#if os(macOS)
// Debug link defaults can record the deployment target as the SDK version.
// AppKit's linked-before behavior follows that marker, not the SDK used to compile.
let sdkQuery = Process()
let sdkOutput = Pipe()
sdkQuery.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
sdkQuery.arguments = ["--sdk", "macosx", "--show-sdk-version"]
sdkQuery.standardOutput = sdkOutput
try sdkQuery.run()
let sdkVersion = String(decoding: sdkOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
sdkQuery.waitUntilExit()
precondition(sdkQuery.terminationStatus == 0 && sdkVersion.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil,
             "Unable to determine the selected macOS SDK version")
for target in package.targets where target.type == .executable || target.type == .test {
    target.linkerSettings = (target.linkerSettings ?? []) + [.unsafeFlags([
        "-Xlinker", "-platform_version", "-Xlinker", "macos",
        "-Xlinker", "14.0", "-Xlinker", sdkVersion,
    ])]
}
#endif
