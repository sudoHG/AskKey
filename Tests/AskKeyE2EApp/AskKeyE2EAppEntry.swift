import AskKeyAppKit
import AskKeyTestSupport

@main
enum AskKeyE2EAppEntry {
    @MainActor static func main() {
        AskKeyApp.run(configuration: E2EAppRuntime.configuration())
    }
}
