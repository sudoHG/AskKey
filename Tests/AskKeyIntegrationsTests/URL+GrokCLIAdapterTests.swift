import Foundation

extension URL {
    var isSymlink: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }
}
