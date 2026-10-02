import Foundation
import Darwin

@main
enum E2ERequestEvidenceChecks {
    private struct CheckFailure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let scenario = CommandLine.arguments[1]
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("askkey-reader-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let request = directory.appendingPathComponent("request-7D61FE55-9B89-40D0-BF2A-49995C68093F-1-32.json")
        let temporary = directory.appendingPathComponent(request.lastPathComponent + ".sb-16373f5c-0KHNZI")
        let original = Data(#"{"jsonrpc":"2.0","id":32,"params":{"name":"run","arguments":{"operation_id":"synthetic"}}}"#.utf8)
        try original.write(to: request, options: .atomic)

        switch scenario {
        case "incomplete-temporary":
            try Data(#"{"jsonrpc":"#.utf8).write(to: temporary)
            try assertOnlyOriginalRequest(E2ERequestEvidenceReader.requests(in: directory))
        case "disappearing-temporary":
            try original.write(to: temporary)
            let requests = try E2ERequestEvidenceReader.requests(in: directory) { directory in
                let entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                guard let enumeratedTemporary = entries.first(where: {
                    $0.lastPathComponent == temporary.lastPathComponent
                }) else {
                    throw CheckFailure(description: "The transient file must actually be enumerated")
                }
                try manager.removeItem(at: enumeratedTemporary)
                return entries
            }
            try assertOnlyOriginalRequest(requests)
        case "valid-temporary":
            try original.write(to: temporary)
            try original.write(to: directory.appendingPathComponent("health.json"))
            try original.write(to: directory.appendingPathComponent("request-notes.txt"))
            try assertOnlyOriginalRequest(E2ERequestEvidenceReader.requests(in: directory))
        case "replaced-published":
            let replacement = Data(#"{"jsonrpc":"2.0","id":33,"params":{"name":"run"}}"#.utf8)
            let requests = try E2ERequestEvidenceReader.requests(in: directory) { directory in
                let entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                try replacement.write(to: request, options: .atomic)
                return entries
            }
            try require(requests.count == 1 && requests[0]["id"] as? Int == 33,
                        "Reading must open the published path directly after atomic replacement")
        case "malformed-published":
            for malformed in [Data("{".utf8), Data("[]".utf8)] {
                try malformed.write(to: request, options: .atomic)
                try requireThrows("Malformed final evidence was silently discarded") {
                    _ = try E2ERequestEvidenceReader.requests(in: directory)
                }
            }
        case "missing-published":
            try requireThrows("A missing published request was silently discarded") {
                _ = try E2ERequestEvidenceReader.requests(in: directory) { directory in
                    let entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    guard let enumeratedRequest = entries.first(where: {
                        $0.lastPathComponent == request.lastPathComponent
                    }) else {
                        throw CheckFailure(description: "The published request must actually be enumerated")
                    }
                    try manager.removeItem(at: enumeratedRequest)
                    return entries
                }
            }
        default:
            throw CheckFailure(description: "Unknown scenario: \(scenario)")
        }
    }

    private static func assertOnlyOriginalRequest(_ requests: [[String: Any]]) throws {
        try require(requests.count == 1, "Only the one published request may be returned; got \(requests.count)")
        try require(requests[0]["id"] as? Int == 32, "The published MCP request must remain unchanged")
        let params = requests[0]["params"] as? [String: Any]
        let arguments = params?["arguments"] as? [String: Any]
        try require(arguments?["operation_id"] as? String == "synthetic", "The original request body was lost")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(description: message) }
    }

    private static func requireThrows(_ message: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch let error as CheckFailure { throw error }
        catch { return }
        throw CheckFailure(description: message)
    }
}
