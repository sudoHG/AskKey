import Foundation

/// Reads the request evidence published by the local MCP fixture. The directory
/// enumerator is injectable so filesystem publication races can be reproduced
/// without launching the UI or replacing JSON parsing with a test double.
enum E2ERequestEvidenceReader {
    static func requests(
        in directory: URL,
        enumerate: (URL) throws -> [URL] = {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }
    ) throws -> [[String: Any]] {
        let published = try enumerate(directory)
            // Data.write(.atomic) exposes transient .json.sb-* siblings. Only
            // the final .json name is published protocol evidence.
            .filter { $0.lastPathComponent.hasPrefix("request-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try published.map { url in
            // Open the published path directly. Atomic replacement is safe;
            // missing or malformed final evidence must remain a test failure.
            let data = try Data(contentsOf: url)
            guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "AskKeyE2E.RequestEvidence", code: 1, userInfo: [
                    NSFilePathErrorKey: url.path,
                    NSLocalizedDescriptionKey: "Published request evidence must be a JSON object"
                ])
            }
            return envelope
        }
    }
}
