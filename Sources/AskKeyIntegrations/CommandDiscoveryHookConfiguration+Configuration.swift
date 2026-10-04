import Darwin
import Foundation

extension CommandDiscoveryHookConfiguration {
    func makeDefinition() throws -> Definition {
        guard expectedHooks.count <= Self.maximumHooksBytes, !expectedHooks.contains(0) else {
            throw Error.invalidExpectedHooks
        }
        let object: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(
                with: expectedHooks, options: [.fragmentsAllowed]
            ) as? [String: Any] else { throw Error.invalidExpectedHooks }
            object = value
        } catch let error as Error { throw error }
        catch { throw Error.invalidExpectedHooks }

        switch format {
        case .claudeMerged:
            return try claudeDefinition(object)
        case .grokOwned:
            let commands = allCommands(in: object)
            guard !commands.isEmpty else { throw Error.invalidExpectedHooks }
            return Definition(
                root: object, groups: [:], commands: commands,
                canonical: try serialize(object, error: .invalidExpectedHooks)
            )
        case .cursorMerged:
            guard let version = object["version"] as? NSNumber, version.intValue == 1,
                  let rawHooks = object["hooks"] as? [String: Any], !rawHooks.isEmpty else {
                throw Error.invalidExpectedHooks
            }
            var groups: [String: [[String: Any]]] = [:]
            var commands: [String] = []
            for event in rawHooks.keys.sorted() {
                guard let rawGroups = rawHooks[event] as? [Any], !rawGroups.isEmpty else {
                    throw Error.invalidExpectedHooks
                }
                var eventGroups: [[String: Any]] = []
                for rawGroup in rawGroups {
                    guard let group = rawGroup as? [String: Any], !commandStrings(in: group).isEmpty else {
                        throw Error.invalidExpectedHooks
                    }
                    eventGroups.append(group)
                    commands.append(contentsOf: commandStrings(in: group))
                }
                groups[event] = eventGroups
            }
            return Definition(
                root: object, groups: groups, commands: commands,
                canonical: try serialize(object, error: .invalidExpectedHooks)
            )
        }
    }

    func object(_ bytes: Data, error: Error) throws -> [String: Any] {
        guard !bytes.isEmpty, !bytes.contains(0) else { throw error }
        do {
            guard let value = try JSONSerialization.jsonObject(
                with: bytes, options: [.fragmentsAllowed]
            ) as? [String: Any] else { throw error }
            return value
        } catch let caught as Error { throw caught }
        catch { throw error }
    }

    func serialize(_ object: [String: Any], error: Error) throws -> Data {
        do {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            data.append(0x0A)
            return data
        } catch { throw error }
    }

    func jsonEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        guard let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]) else { return false }
        return left == right
    }

    func cursorMatches(in document: [String: Any], definition: Definition) throws -> [Match] {
        guard let version = document["version"] as? NSNumber, version.intValue == 1 else {
            throw Error.invalidHooksFile
        }
        let rawHooks: [String: Any]
        if let value = document["hooks"] {
            guard let hooks = value as? [String: Any] else { throw Error.invalidHooksFile }
            rawHooks = hooks
        } else {
            rawHooks = [:]
        }
        var found: [Match] = []
        for event in rawHooks.keys {
            guard let rawGroups = rawHooks[event] as? [Any] else { throw Error.invalidHooksFile }
            for rawGroup in rawGroups {
                guard let group = rawGroup as? [String: Any] else { throw Error.invalidHooksFile }
                let commands = commandStrings(in: group)
                guard !commands.isEmpty else { continue }
                let exact = definition.groups[event]?.contains { jsonEqual($0, group) } == true
                let ownLike = commands.contains { isOwnLike($0, expected: definition.commands) }
                if exact || ownLike {
                    found.append(Match(event: event, exact: exact, ownLike: ownLike))
                }
            }
        }
        return found
    }

    func validate(_ matches: [Match], expected: [String: [[String: Any]]]) throws {
        let own = matches.filter(\.ownLike).count
        let custom = matches.filter { $0.ownLike && !$0.exact }.count
        let expectedCount = expected.values.reduce(0) { $0 + $1.count }
        let exactByEvent = Dictionary(grouping: matches.filter(\.exact), by: \.event)
        if exactByEvent.contains(where: { $0.value.count > (expected[$0.key]?.count ?? 0) }) {
            throw Error.multipleExpectedHooks
        }
        if own > expectedCount { throw Error.multipleExpectedHooks }
        if custom > 0 { throw Error.customHookMismatch }
    }

    func append(to document: inout [String: Any], definition: Definition) throws {
        var hooks: [String: Any]
        if let raw = document["hooks"] {
            guard let existing = raw as? [String: Any] else { throw Error.invalidHooksFile }
            hooks = existing
        } else {
            hooks = [:]
        }
        for event in definition.groups.keys.sorted() {
            var groups = (hooks[event] as? [Any]) ?? []
            if hooks[event] != nil, hooks[event] as? [Any] == nil { throw Error.invalidHooksFile }
            for expected in definition.groups[event] ?? [] {
                if !groups.contains(where: { ($0 as? [String: Any]).map { jsonEqual($0, expected) } == true }) {
                    groups.append(expected)
                }
            }
            hooks[event] = groups
        }
        document["hooks"] = hooks
    }

    private func commandStrings(in group: [String: Any]) -> [String] {
        var values: [String] = []
        if let command = group["command"] as? String, !command.isEmpty { values.append(command) }
        if let handlers = group["hooks"] as? [Any] {
            for handler in handlers {
                if let value = handler as? [String: Any],
                   let command = value["command"] as? String, !command.isEmpty { values.append(command) }
            }
        }
        return values
    }

    private func allCommands(in value: Any) -> [String] {
        if let object = value as? [String: Any] {
            var values = object["command"].flatMap { $0 as? String }.map { [$0] } ?? []
            values += object.values.flatMap { allCommands(in: $0) }
            return values
        }
        if let array = value as? [Any] { return array.flatMap { allCommands(in: $0) } }
        return []
    }

    func containsOwnLike(in document: [String: Any], commands: [String]) -> Bool {
        allCommands(in: document).contains { isOwnLike($0, expected: commands) }
    }

    private func isOwnLike(_ command: String, expected: [String]) -> Bool {
        if expected.contains(command) { return true }
        let value = command.lowercased()
        return value.contains("askkey") || value.contains("ask key") || value.contains(format.invocationMarker)
    }
}
