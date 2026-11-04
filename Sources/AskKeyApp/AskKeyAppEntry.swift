import AskKeyAppKit

@main
enum AskKeyAppEntry {
    @MainActor static func main() {
        // The updater factory only runs when AskKeyAppKit enables updates (ADR 0011).
        AskKeyApp.run(configuration: AppRuntimeConfiguration(
            makeSoftwareUpdater: { SparkleSoftwareUpdater(relaunchGate: $0) }
        ))
    }
}
