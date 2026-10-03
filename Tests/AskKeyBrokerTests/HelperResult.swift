import Foundation

struct HelperResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}
