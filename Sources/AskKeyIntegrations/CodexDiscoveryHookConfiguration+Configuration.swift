import Darwin
import Foundation

extension CodexDiscoveryHookConfiguration {
    var hooksParentURL: URL { hooksURL.deletingLastPathComponent() }

    static var expectedHookGroup: [String: Any] {
        [
            "matcher": expectedMatcher,
            "hooks": [[
                "type": "mcp_tool",
                "server": expectedServer,
                "tool": expectedTool,
                "input": [
                    "session_id": "${session_id}",
                    "turn_id": "${turn_id}",
                    "tool_name": "${tool_name}",
                    "tool_input": "${tool_input}"
                ],
                "timeout": 3
            ]]
        ]
    }

    func readHooksSnapshot() throws -> HooksSnapshot? {
        try inspectExistingDirectoryChain(hooksParentURL, error: .unsafeHooksFile)
        do {
            let file = try ClientConfigFileIO.readRegularFile(
                hooksURL,
                maximumBytes: Self.maximumHooksBytes
            )
            guard !file.bytes.contains(0) else {
                throw CodexDiscoveryHookConfigurationError.invalidHooksFile
            }
            return HooksSnapshot(bytes: file.bytes, mode: UInt32(file.mode))
        } catch ClientConfigFileIO.Failure.notFound {
            return nil
        } catch ClientConfigFileIO.Failure.tooLarge {
            throw CodexDiscoveryHookConfigurationError.fileTooLarge
        } catch ClientConfigFileIO.Failure.unsafe {
            throw CodexDiscoveryHookConfigurationError.unsafeHooksFile
        }
    }

    func parseDocument(_ bytes: Data) throws -> [String: Any] {
        guard !bytes.isEmpty else { return [:] }
        do {
            let object = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
            guard let document = object as? [String: Any] else {
                throw CodexDiscoveryHookConfigurationError.invalidHooksFile
            }
            return document
        } catch let error as CodexDiscoveryHookConfigurationError {
            throw error
        } catch {
            throw CodexDiscoveryHookConfigurationError.invalidHooksFile
        }
    }

    func serializeDocument(_ document: [String: Any]) throws -> Data {
        do {
            var bytes = try JSONSerialization.data(
                withJSONObject: document,
                options: [.prettyPrinted, .sortedKeys]
            )
            bytes.append(0x0A)
            return bytes
        } catch {
            throw CodexDiscoveryHookConfigurationError.invalidHooksFile
        }
    }

    func matchingHookGroups(in document: [String: Any]) throws -> [HookGroupMatch] {
        guard let rawHooks = document["hooks"] else { return [] }
        guard let hooks = rawHooks as? [String: Any] else {
            throw CodexDiscoveryHookConfigurationError.invalidHooksFile
        }

        var matches: [HookGroupMatch] = []
        for (eventName, rawGroups) in hooks {
            guard let groups = rawGroups as? [Any] else {
                throw CodexDiscoveryHookConfigurationError.invalidHooksFile
            }
            for rawGroup in groups {
                guard let group = rawGroup as? [String: Any],
                      let rawHooksInGroup = group["hooks"] as? [Any] else {
                    throw CodexDiscoveryHookConfigurationError.invalidHooksFile
                }
                for rawHook in rawHooksInGroup {
                    guard let hook = rawHook as? [String: Any] else {
                        throw CodexDiscoveryHookConfigurationError.invalidHooksFile
                    }
                    guard hook["server"] as? String == Self.expectedServer,
                          hook["tool"] as? String == Self.expectedTool else {
                        continue
                    }
                    matches.append(HookGroupMatch(eventName: eventName, group: group))
                }
            }
        }
        return matches
    }

    func validateOwnHook(_ matches: [HookGroupMatch]) throws {
        if matches.count > 1 {
            throw CodexDiscoveryHookConfigurationError.multipleExpectedHooks
        }
    }

    func appendExpectedHook(to document: inout [String: Any]) throws {
        var hooks: [String: Any]
        if let rawHooks = document["hooks"] {
            guard let existingHooks = rawHooks as? [String: Any] else {
                throw CodexDiscoveryHookConfigurationError.invalidHooksFile
            }
            hooks = existingHooks
        } else {
            hooks = [:]
        }

        var preToolUse: [Any]
        if let rawPreToolUse = hooks["PreToolUse"] {
            guard let existing = rawPreToolUse as? [Any] else {
                throw CodexDiscoveryHookConfigurationError.invalidHooksFile
            }
            preToolUse = existing
        } else {
            preToolUse = []
        }
        preToolUse.append(Self.expectedHookGroup)
        hooks["PreToolUse"] = preToolUse
        document["hooks"] = hooks
    }

    func jsonEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        guard let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]) else {
            return false
        }
        return left == right
    }

    func readSnapshot(at url: URL) throws -> HooksSnapshot? {
        do {
            let file = try ClientConfigFileIO.readRegularFile(url, maximumBytes: Self.maximumHooksBytes)
            return HooksSnapshot(bytes: file.bytes, mode: UInt32(file.mode))
        } catch ClientConfigFileIO.Failure.notFound {
            return nil
        } catch ClientConfigFileIO.Failure.tooLarge {
            throw CodexDiscoveryHookConfigurationError.fileTooLarge
        } catch {
            throw CodexDiscoveryHookConfigurationError.unsafeHooksFile
        }
    }
}
