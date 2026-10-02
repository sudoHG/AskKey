import Foundation
import AskKeyBroker

public enum VaultConfiguration {
    #if DEBUG
    public static let isDevelopmentBuild = true
    private static let legacyKeychainService = "com.sudohg.askkey.vault.dev"
    private static let currentAppKeychainService = "com.sudohg.askkey.vault.v2.app.dev"
    private static let priorAppKeychainService = "com.sudohg.askkey.vault.v1.app.dev"
    private static let applicationSupportSubdirectory = "AskKey/dev"
    #else
    public static let isDevelopmentBuild = false
    private static let legacyKeychainService = "com.sudohg.askkey.vault"
    private static let currentAppKeychainService = "com.sudohg.askkey.vault.v2.app"
    private static let priorAppKeychainService = "com.sudohg.askkey.vault.v1.app"
    private static let applicationSupportSubdirectory = "AskKey"
    #endif

    /// A nonthrowing UI gate only. All actual I/O validates the explicit run
    /// directory with validateRuntimeIsolation() before using derived paths.
    public static var debugRunDirectory: URL? { try? DebugRunDirectory.resolve() }

    public static func validateRuntimeIsolation() throws { _ = try DebugRunDirectory.resolve() }

    public static var keychainService: String { namespacedService(legacyKeychainService) }
    static var appKeychainService: String { namespacedService(currentAppKeychainService) }
    static var previousAppKeychainService: String { namespacedService(priorAppKeychainService) }

    private static func namespacedService(_ service: String) -> String {
        guard let directory = runtimeIsolationDirectory else { return service }
        return service + ".run." + DebugRunDirectory.namespace(for: directory)
    }

    private static var runtimeIsolationDirectory: URL? {
        do { return try DebugRunDirectory.resolve() }
        catch {
            // No invalid explicit run can ever resolve back to real/dev data.
            // Entry points throw the validation error before I/O; this path is
            // also unusable if a caller only asks for a URL.
            return URL(fileURLWithPath: "/dev/null/askkey-invalid-debug-run", isDirectory: true)
        }
    }

    public static var vaultFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("vault.db")
    }

    static var migratedVaultFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("credentials-v2.db")
    }

    static var previousMigratedVaultFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("credentials.db")
    }

    static var migrationJournalURL: URL {
        applicationSupportDirectory.appendingPathComponent("migration-v2.journal")
    }

    static var previousMigrationJournalURL: URL {
        applicationSupportDirectory.appendingPathComponent("migration.journal")
    }

    static var pendingAppKeychainService: String {
        appKeychainService + ".migration"
    }

    public static var iCloudBackupKeychainService: String {
        // Recovery material is independent of the local vault format/key.
        // Preserve its namespace across the authenticated-record migration.
        previousAppKeychainService + ".icloud-backup"
    }

    public static var localRestoreSafetySnapshotDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("restore-safety", isDirectory: true)
    }

    static var localEraseJournalURL: URL {
        if let directory = runtimeIsolationDirectory {
            return directory.appendingPathComponent("lifecycle/erase.journal")
        }
        return userApplicationSupportDirectory
            .appendingPathComponent("com.sudohg.askkey.lifecycle", isDirectory: true)
            .appendingPathComponent(isDevelopmentBuild ? "erase.dev.journal" : "erase.journal")
    }

    /// Unix socket the menu-bar app (daemon) listens on and the CLI/MCP client
    /// connects to (ADR 0014). Co-located with the vault so dev and release
    /// builds use separate sockets.
    public static var daemonSocketURL: URL {
        applicationSupportDirectory.appendingPathComponent("daemon.sock")
    }

    static var applicationSupportDirectory: URL {
        if let directory = runtimeIsolationDirectory {
            return directory.appendingPathComponent("core", isDirectory: true)
        }
        return userApplicationSupportDirectory.appendingPathComponent(applicationSupportSubdirectory)
    }

    private static var userApplicationSupportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}
