import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

extension CodexAskKeyTOML {
    static func assertAssignmentsAndKeyPaths(_ parts: [Section]) throws {
        var tables = Set<[String]>()
        var implicitTables = Set<[String]>()
        var values = Set<[String]>()
        var arrayTables = Set<[String]>()
        for part in parts {
            if let name = part.name {
                guard !name.parts.isEmpty, name.parts.allSatisfy({ !$0.isEmpty }) else {
                    throw CodexUserMCPError.illegalConfig
                }
                if part.isArray {
                    try defineArrayTable(
                        name.parts,
                        arrayTables: &arrayTables,
                        tables: tables,
                        values: values,
                        implicitTables: &implicitTables
                    )
                } else if arrayAncestor(name.parts, in: arrayTables) == nil {
                    try defineTable(
                        name.parts,
                        tables: &tables,
                        values: values,
                        arrayTables: arrayTables,
                        implicitTables: &implicitTables
                    )
                }
            }
            var keysInSection = Set<[String]>()
            var scan = Scan.normal
            for line in lines(of: part.raw, newline: part.newline) {
                if scan.isNormal {
                    let code = codePortion(line).trimmingCharacters(in: .whitespaces)
                    if let key = keyName(code) {
                        guard let local = dottedParts(key),
                              !local.isEmpty,
                              local.allSatisfy({ !$0.isEmpty }) else {
                            throw CodexUserMCPError.illegalConfig
                        }
                        if !keysInSection.insert(local).inserted {
                            throw CodexUserMCPError.illegalConfig
                        }
                        try assertAssignmentHasValue(code)
                        var path = part.name?.parts ?? []
                        path.append(contentsOf: local)
                        let underArray = part.isArray
                            || arrayAncestor(part.name?.parts ?? [], in: arrayTables) != nil
                        if !underArray {
                            try defineValue(
                                path,
                                tableDepth: part.name?.parts.count ?? 0,
                                tables: &tables,
                                values: &values,
                                arrayTables: arrayTables,
                                implicitTables: &implicitTables
                            )
                        }
                    }
                }
                scan = advance(scan, through: line)
            }
        }
    }

    private static func assertAssignmentHasValue(_ code: String) throws {
        guard let eq = code.firstIndex(of: "=") else { return }
        let value = code[code.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value.isEmpty { throw CodexUserMCPError.illegalConfig }
    }

    private static func defineArrayTable(
        _ path: [String],
        arrayTables: inout Set<[String]>,
        tables: Set<[String]>,
        values: Set<[String]>,
        implicitTables: inout Set<[String]>
    ) throws {
        guard !path.isEmpty, path.allSatisfy({ !$0.isEmpty }) else {
            throw CodexUserMCPError.illegalConfig
        }
        if values.contains(path) || tables.contains(path) || implicitTables.contains(path) {
            throw CodexUserMCPError.illegalConfig
        }
        if !arrayTables.insert(path).inserted { return }
        for index in 1..<path.count {
            let prefix = Array(path[0..<index])
            if values.contains(prefix) { throw CodexUserMCPError.illegalConfig }
            if tables.contains(prefix) || arrayTables.contains(prefix) { continue }
            implicitTables.insert(prefix)
        }
    }

    private static func defineTable(
        _ path: [String],
        tables: inout Set<[String]>,
        values: Set<[String]>,
        arrayTables: Set<[String]>,
        implicitTables: inout Set<[String]>
    ) throws {
        guard !path.isEmpty, path.allSatisfy({ !$0.isEmpty }) else {
            throw CodexUserMCPError.illegalConfig
        }
        if values.contains(path) || arrayTables.contains(path) {
            throw CodexUserMCPError.illegalConfig
        }
        if tables.contains(path) { throw CodexUserMCPError.illegalConfig }
        for index in 1..<path.count {
            let prefix = Array(path[0..<index])
            if values.contains(prefix) || arrayTables.contains(prefix) {
                throw CodexUserMCPError.illegalConfig
            }
            if !tables.contains(prefix) { implicitTables.insert(prefix) }
        }
        implicitTables.remove(path)
        tables.insert(path)
    }

    private static func defineValue(
        _ path: [String],
        tableDepth: Int,
        tables: inout Set<[String]>,
        values: inout Set<[String]>,
        arrayTables: Set<[String]>,
        implicitTables: inout Set<[String]>
    ) throws {
        guard !path.isEmpty, path.allSatisfy({ !$0.isEmpty }) else {
            throw CodexUserMCPError.illegalConfig
        }
        if tables.contains(path) || values.contains(path) || arrayTables.contains(path) || implicitTables.contains(path) {
            throw CodexUserMCPError.illegalConfig
        }
        for index in 1..<path.count {
            let prefix = Array(path[0..<index])
            if values.contains(prefix) || arrayTables.contains(prefix) {
                throw CodexUserMCPError.illegalConfig
            }
            // Dotted keys define their parent tables, unlike table-header ancestors.
            if index > tableDepth {
                implicitTables.remove(prefix)
                tables.insert(prefix)
            }
        }
        values.insert(path)
    }

    private static func arrayAncestor(_ path: [String], in arrayTables: Set<[String]>) -> [String]? {
        var index = path.count - 1
        while index >= 1 {
            let prefix = Array(path[0..<index])
            if arrayTables.contains(prefix) { return prefix }
            index -= 1
        }
        return nil
    }
}
