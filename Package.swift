// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AskKey",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AskKeyBroker", targets: ["AskKeyBroker"]),
        .library(name: "AskKeyCore", targets: ["AskKeyCore"]),
        .executable(name: "askkey", targets: ["AskKeyHelper"]),
        .executable(name: "AskKeyApp", targets: ["AskKeyApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0"),
        .package(url: "https://github.com/P-H-C/phc-winner-argon2.git", revision: "f57e61e19229e23c4445b85494dbf7c07de721cb"),
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
            name: "AskKeyCore",
            dependencies: [
                "AskKeyBroker",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "argon2", package: "phc-winner-argon2"),
            ],
            path: "Sources/AskKeyCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AskKeyHelper",
            dependencies: ["AskKeyBroker"],
            path: "Sources/AskKeyHelper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AskKeyApp",
            dependencies: [
                "AskKeyBroker",
                "AskKeyCore",
            ],
            path: "Sources/AskKeyApp",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AskKeyBrokerTests",
            dependencies: ["AskKeyBroker"],
            path: "Tests/AskKeyBrokerTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AskKeyCoreTests",
            dependencies: ["AskKeyBroker", "AskKeyCore", "AskKeyHelper"],
            path: "Tests/AskKeyCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AskKeyAppTests",
            dependencies: ["AskKeyApp", "AskKeyCore"],
            path: "Tests/AskKeyAppTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
