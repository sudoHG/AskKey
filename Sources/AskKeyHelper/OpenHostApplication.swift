import Foundation
import CoreFoundation
import AskKeyBroker

func openHostApplication() throws {
    let helper = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .standardizedFileURL.resolvingSymlinksInPath()
#if DEBUG
    try HelperHostApplication.openHost(helperURL: helper, isDevelopmentBuild: true)
#else
    try HelperHostApplication.openHost(helperURL: helper, isDevelopmentBuild: false)
#endif
}
