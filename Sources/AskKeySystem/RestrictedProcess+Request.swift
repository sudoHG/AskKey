import Foundation
import Darwin

extension RestrictedProcess {
    package struct Request: Sendable {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
        var currentDirectory: URL? = nil
        var standardInput: Data? = nil
        var writeInputBeforeSpawn = false
        var maximumInputBytes: Int? = nil
        var timeout: TimeInterval
        var usesMonotonicClock = false
        var captureStderr = true
        var maximumOutputBytes: Int
        var truncateOutput = true
        var terminationGrace: TimeInterval = 0
        var isCancelled: (@Sendable () -> Bool)? = nil

        package init(
            executable: URL,
            arguments: [String],
            environment: [String: String],
            currentDirectory: URL? = nil,
            standardInput: Data? = nil,
            writeInputBeforeSpawn: Bool = false,
            maximumInputBytes: Int? = nil,
            timeout: TimeInterval,
            usesMonotonicClock: Bool = false,
            captureStderr: Bool = true,
            maximumOutputBytes: Int,
            truncateOutput: Bool = true,
            terminationGrace: TimeInterval = 0,
            isCancelled: (@Sendable () -> Bool)? = nil
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.currentDirectory = currentDirectory
            self.standardInput = standardInput
            self.writeInputBeforeSpawn = writeInputBeforeSpawn
            self.maximumInputBytes = maximumInputBytes
            self.timeout = timeout
            self.usesMonotonicClock = usesMonotonicClock
            self.captureStderr = captureStderr
            self.maximumOutputBytes = maximumOutputBytes
            self.truncateOutput = truncateOutput
            self.terminationGrace = terminationGrace
            self.isCancelled = isCancelled
        }
    }
}
