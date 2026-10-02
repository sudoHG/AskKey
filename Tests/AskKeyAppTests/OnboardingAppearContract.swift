import Foundation

enum OnboardingAppearContract {
    static func failures(
        checkCalls: Int,
        applyCalls: Int,
        errorMessage: String?
    ) -> [String] {
        var failures: [String] = []
        if checkCalls != 0 {
            failures.append("check/preview calls \(checkCalls) != 0")
        }
        if applyCalls != 0 {
            failures.append("apply calls \(applyCalls) != 0")
        }
        if let errorMessage, !errorMessage.isEmpty {
            failures.append("global errorMessage was set: \(errorMessage)")
        }
        return failures
    }
}
