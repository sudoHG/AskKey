import Foundation

/// Preserve object member order and original bytes of untouched values while
/// editing the small owned portion of a shared Claude settings document.
struct CommandHookJSON {
    private indirect enum Value {
        case object([(String, CommandHookJSON)])
        case array([CommandHookJSON])
        case scalar
    }
    private var value: Value
    private var original: Data?
    static let emptyObject = CommandHookJSON(value: .object([]))
    static let emptyArray = CommandHookJSON(value: .array([]))

    var bytes: Data {
        if let original { return original }
        switch value {
        case .object(let members):
            let values = members.map { key, node in
                let encoded = quotedKey(key)
                return encoded + Data(":".utf8) + node.bytes
            }
            return joined(values, open: "{", close: "}")
        case .array(let elements): return joined(elements.map(\.bytes), open: "[", close: "]")
        case .scalar: return Data()
        }
    }

    private func quotedKey(_ key: String) -> Data {
        var encoded = Data([34])
        for byte in key.utf8 {
            switch byte {
            case 34, 92: encoded.append(92); encoded.append(byte)
            case 0..<32: encoded.append(contentsOf: String(format: "\\u%04x", byte).utf8)
            default: encoded.append(byte)
            }
        }
        encoded.append(34)
        return encoded
    }

    private func joined(_ values: [Data], open: String, close: String) -> Data {
        var result = Data(open.utf8)
        for (index, value) in values.enumerated() {
            if index > 0 { result.append(contentsOf: ",".utf8) }
            result.append(value)
        }
        result.append(contentsOf: close.utf8)
        return result
    }

    func member(_ key: String) -> Self? {
        guard case .object(let members) = value else { return nil }
        return members.first { $0.0 == key }?.1
    }

    func requiredMember(_ key: String) throws -> Self {
        guard let member = member(key) else { throw CommandDiscoveryHookConfigurationError.invalidHooksFile }
        return member
    }

    mutating func set(_ key: String, to node: Self) throws {
        guard case .object(var members) = value else { throw CommandDiscoveryHookConfigurationError.invalidHooksFile }
        if let index = members.firstIndex(where: { $0.0 == key }) { members[index].1 = node }
        else { members.append((key, node)) }
        value = .object(members); original = nil
    }

    func element(_ index: Int) throws -> Self {
        guard case .array(let elements) = value, elements.indices.contains(index)
        else { throw CommandDiscoveryHookConfigurationError.invalidHooksFile }
        return elements[index]
    }

    mutating func setElement(_ index: Int, to node: Self) throws {
        guard case .array(var elements) = value, elements.indices.contains(index)
        else { throw CommandDiscoveryHookConfigurationError.invalidHooksFile }
        elements[index] = node; value = .array(elements); original = nil
    }

    mutating func append(_ node: Self) throws {
        guard case .array(var elements) = value else { throw CommandDiscoveryHookConfigurationError.invalidHooksFile }
        elements.append(node); value = .array(elements); original = nil
    }

    mutating func remove(_ index: Int) throws {
        guard case .array(var elements) = value, elements.indices.contains(index)
        else { throw CommandDiscoveryHookConfigurationError.invalidHooksFile }
        elements.remove(at: index); value = .array(elements); original = nil
    }

    var isEmptyArray: Bool {
        if case .array(let elements) = value { return elements.isEmpty }
        return false
    }

    static func parse(_ data: Data) throws -> Self {
        // Foundation validates grammar before the order-preserving parser.
        do { _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw CommandDiscoveryHookConfigurationError.invalidHooksFile }
        var parser = Parser(data: Array(data))
        let node = try parser.node(depth: 0)
        parser.space()
        guard parser.offset == parser.data.count else { throw CommandDiscoveryHookConfigurationError.invalidHooksFile }
        return node
    }

    private struct Parser {
        let data: [UInt8]
        var offset = 0
        mutating func space() {
            while offset < data.count, [9, 10, 13, 32].contains(data[offset]) { offset += 1 }
        }
        mutating func string() throws -> Data {
            let start = offset
            guard offset < data.count, data[offset] == 34 else { throw CommandDiscoveryHookConfigurationError.invalidHooksFile }
            offset += 1
            while offset < data.count {
                let byte = data[offset]; offset += 1
                if byte == 34 { return Data(data[start..<offset]) }
                if byte == 92 { offset += 1 }
            }
            throw CommandDiscoveryHookConfigurationError.invalidHooksFile
        }
        mutating func node(depth: Int) throws -> CommandHookJSON {
            space()
            guard offset < data.count, depth < 128 else { throw CommandDiscoveryHookConfigurationError.invalidHooksFile }
            let start = offset
            let value: Value
            switch data[offset] {
            case 123:
                offset += 1; space()
                var members: [(String, CommandHookJSON)] = []
                var seen = Set<String>()
                while offset < data.count, data[offset] != 125 {
                    let keyData = try string()
                    guard let key = try JSONSerialization.jsonObject(with: keyData, options: [.fragmentsAllowed]) as? String,
                          seen.insert(key).inserted else {
                        throw CommandDiscoveryHookConfigurationError.invalidHooksFile
                    }
                    space()
                    guard offset < data.count, data[offset] == 58 else {
                        throw CommandDiscoveryHookConfigurationError.invalidHooksFile
                    }
                    offset += 1
                    members.append((key, try node(depth: depth + 1)))
                    space()
                    if offset < data.count, data[offset] == 44 { offset += 1; space() } else { break }
                }
                guard offset < data.count, data[offset] == 125 else {
                    throw CommandDiscoveryHookConfigurationError.invalidHooksFile
                }
                offset += 1; value = .object(members)
            case 91:
                offset += 1; space()
                var elements: [CommandHookJSON] = []
                while offset < data.count, data[offset] != 93 {
                    elements.append(try node(depth: depth + 1)); space()
                    if offset < data.count, data[offset] == 44 { offset += 1; space() } else { break }
                }
                guard offset < data.count, data[offset] == 93 else {
                    throw CommandDiscoveryHookConfigurationError.invalidHooksFile
                }
                offset += 1; value = .array(elements)
            case 34:
                _ = try string(); value = .scalar
            default:
                while offset < data.count, ![9, 10, 13, 32, 44, 93, 125].contains(data[offset]) { offset += 1 }
                guard offset > start else { throw CommandDiscoveryHookConfigurationError.invalidHooksFile }
                value = .scalar
            }
            return CommandHookJSON(value: value, original: Data(data[start..<offset]))
        }
    }
}
