import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker

extension CursorUserMCPAdapter {
    public func verify() throws -> CursorMCPConnectionStatus {
        try withBackupLock { try verifyLocked() }
    }

    private func verifyLocked() throws -> CursorMCPConnectionStatus {
        let status = try status()
        if status.connected, FileManager.default.fileExists(atPath: backupURL.path) {
            try cleanupOwnedBackup()
        }
        return status
    }

    public func status() throws -> CursorMCPConnectionStatus {
        let configReady = try configuredAskKeyMatches()
        let helperReady = isExecutableRegularFile(helperURL) && signing.isTrusted(helperURL)
        let protocolReady = configReady && probeMCP()
        let brokerHealthy = probeBroker()
        let status = CursorMCPConnectionStatus(
            connected: configReady && helperReady && protocolReady && brokerHealthy,
            configReady: configReady,
            helperReady: helperReady,
            protocolReady: protocolReady,
            brokerHealthy: brokerHealthy
        )
        return status
    }

    func configuredAskKeyMatches() throws -> Bool {
        let object = try loadExistingObject()
        guard let servers = object?["mcpServers"] as? [String: Any],
              let askkey = servers["askkey"] as? [String: Any],
              askkey["command"] as? String == helperURL.path,
              stringArray(askkey["args"]) == ["mcp"] else {
            return false
        }
        return true
    }

    func readBack(expectedMode: mode_t) throws {
        let info = try inspect(userConfigURL)
        guard info.exists, info.permissions == expectedMode else {
            throw CursorMCPError.readbackFailed
        }
        guard try configuredAskKeyMatches() else {
            throw CursorMCPError.readbackFailed
        }
    }

    private func probeBroker() -> Bool {
        do {
            let response = try BrokerSocketClient(socketPath: brokerSocketPath)
                .send(.init(version: BrokerProtocolVersion.current, method: "health"))
            guard case .success(.health(let health)) = response, health.status == "ok" else {
                return false
            }
            return true
        } catch {
            return false
        }
    }
}
