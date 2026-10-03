// swift-tools-version: 6.0
import PackageDescription

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
