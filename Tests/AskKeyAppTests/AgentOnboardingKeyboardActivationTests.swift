import XCTest
@testable import AskKeyAppKit

/// Preserve keyboard activation and focus identity in the production view.
@MainActor
final class AgentOnboardingKeyboardActivationTests: AskKeyAppTestCase {
    func testOnboardingActionButtonsForwardSpaceAndReturn() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent(
                "Sources/AskKeyAppKit/Views/AgentOnboardingView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("onboardingActivateWithKeyboard"),
            "check/cancel and sibling actions must forward Space/Return"
        )
        XCTAssertTrue(source.contains(".onKeyPress(.space)"))
        XCTAssertTrue(source.contains(".onKeyPress(.return)"))
        XCTAssertFalse(
            source.contains(".keyboardShortcut("),
            "do not add window-wide shortcuts"
        )
        XCTAssertTrue(
            source.contains(".id(\"onboarding-primary-"),
            "check/cancel must keep one focus identity across the phase swap"
        )
        for identifier in [
            "onboarding-check-",
            "onboarding-cancel-",
            "onboarding-confirm-",
            "onboarding-not-now-",
            "onboarding-review-"
        ] {
            XCTAssertTrue(
                source.contains(identifier),
                "\(identifier) must remain a native identified Button"
            )
        }
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
