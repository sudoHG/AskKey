import Foundation
import MachO
import XCTest

final class SDKMarkerTests: XCTestCase {
    func testTestProcessAndBundleUseTheReleaseSDK() throws {
        try SDKMarkerTestSupport.checkTestProcess()
    }
}

enum SDKMarkerTestSupport {
    static func checkTestProcess(file: StaticString = #filePath, line: UInt = #line) throws {
        // AppKit consults the main executable's SDK, not just the loaded test bundle.
        let image = try XCTUnwrap(_dyld_get_image_name(0), file: file, line: line)
        let bundle = try XCTUnwrap(Bundle(for: SDKMarkerTests.self).executableURL, file: file, line: line)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("scripts/check_sdk_markers.py").path,
                             String(cString: image), bundle.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        print(message)
        guard process.terminationStatus == 0 else {
            XCTFail(message, file: file, line: line)
            throw NSError(domain: "SDKMarkerTests", code: Int(process.terminationStatus))
        }
    }
}
