import Foundation

struct LibraryInstanceApplicationIdentity {
    let bundleIdentifier: String?
    let executableURL: URL

    func matches(bundleIdentifier: String?, executableURL: URL?, pid: Int32, ownPID: Int32) -> Bool {
        guard pid > 0, pid != ownPID, self.bundleIdentifier == bundleIdentifier,
              let executableURL else { return false }
        return self.executableURL.resolvingSymlinksInPath().standardizedFileURL
            == executableURL.resolvingSymlinksInPath().standardizedFileURL
    }
}
