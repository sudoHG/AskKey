import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

@MainActor
final class AgentApprovalPresentationCoordinatorTests: XCTestCase {
    func testLockedManagementActionBringsOpenPanelForwardOnCurrentDisplay() {
        let harness = Harness()
        harness.pending = [request("first")]
        harness.coordinator.presentPendingApproval()
        harness.currentDisplay = "other"
        harness.panelCovered = true
        harness.coordinator.presentPendingApproval(userInitiated: true)
        XCTAssertEqual(harness.presented, ["first"])
        XCTAssertEqual(harness.panelDisplay, "other")
        XCTAssertFalse(harness.panelCovered)
        XCTAssertEqual(harness.focusCount, 1)
        XCTAssertTrue(harness.applied.isEmpty)
    }

    func testDismissalPresentsNextRequestAndDoesNotReopenDeferredRequests() {
        let harness = Harness()
        harness.pending = [request("first"), request("second")]
        harness.coordinator.presentPendingApproval()
        harness.finish?(nil)
        XCTAssertTrue(harness.coordinator.isPresenting)
        XCTAssertEqual(harness.presented, ["first", "second"])
        harness.finish?(nil)
        XCTAssertFalse(harness.coordinator.isPresenting)
        XCTAssertEqual(harness.presented, ["first", "second"])
        harness.coordinator.presentPendingApproval(userInitiated: true)
        XCTAssertEqual(harness.presented, ["first", "second", "first"])
    }

    func testExpiredSelectionGivesGenericFeedback() {
        let harness = Harness()
        harness.pending = [request("expired", deadline: harness.now)]
        harness.coordinator.presentPendingApproval(operationID: "expired", userInitiated: true)
        XCTAssertEqual(harness.presented, [])
        XCTAssertEqual(harness.reminders, 0)
        XCTAssertEqual(harness.messages, ["This request is no longer pending."])
    }

    func testAutomaticUpdatesDoNotMoveOrFocusAnOpenPanel() {
        let harness = Harness()
        harness.pending = [request("first")]
        harness.coordinator.presentPendingApproval()
        harness.currentDisplay = "other"
        harness.panelCovered = true
        harness.pending.append(request("second"))
        harness.coordinator.presentPendingApproval()
        XCTAssertEqual(harness.presented, ["first"])
        XCTAssertEqual(harness.panelDisplay, "main")
        XCTAssertTrue(harness.panelCovered)
        XCTAssertEqual(harness.focusCount, 0)
    }

    func testInitialAutomaticPresentationUsesCurrentDisplay() {
        let harness = Harness()
        harness.currentDisplay = "other"
        harness.pending = [request("first")]
        harness.coordinator.presentPendingApproval()
        XCTAssertEqual(harness.panelDisplay, "other")
    }

    func testSelectedRequestReplacesPanelAndOldCompletionCannotApproveEitherRequest() {
        let harness = Harness()
        harness.pending = [request("first"), request("second")]
        harness.coordinator.presentPendingApproval()
        let staleFinish = harness.finish
        harness.coordinator.presentPendingApproval(operationID: "second", userInitiated: true)
        staleFinish?(.once)
        XCTAssertEqual(harness.dismissCount, 1)
        XCTAssertEqual(harness.presented, ["first", "second"])
        XCTAssertTrue(harness.applied.isEmpty)
        harness.finish?(.deny)
        XCTAssertEqual(harness.applied, ["second"])
    }

    func testOldCompletionCannotApproveSameRequestAfterReopening() {
        let harness = Harness()
        harness.pending = [request("first")]
        harness.coordinator.presentPendingApproval()
        let staleFinish = harness.finish
        harness.finish?(nil)
        harness.coordinator.presentPendingApproval(userInitiated: true)
        staleFinish?(.once)
        XCTAssertTrue(harness.applied.isEmpty)
        harness.finish?(.deny)
        XCTAssertEqual(harness.applied, ["first"])
    }

    func testExpiryCompletionAdvancesToNextLiveRequest() {
        let harness = Harness()
        harness.pending = [request("first", deadline: harness.now.addingTimeInterval(30)), request("second")]
        harness.coordinator.presentPendingApproval()
        harness.now.addTimeInterval(30)
        harness.finish?(nil)
        XCTAssertEqual(harness.presented, ["first", "second"])
        XCTAssertTrue(harness.applied.isEmpty)
    }

    func testManualActionDiscardsExpiredOpenPanelAndReportsItEnded() {
        let harness = Harness()
        harness.pending = [request("first", deadline: harness.now.addingTimeInterval(30))]
        harness.coordinator.presentPendingApproval()
        harness.now.addTimeInterval(30)
        harness.coordinator.presentPendingApproval(userInitiated: true)
        XCTAssertEqual(harness.dismissCount, 1)
        XCTAssertFalse(harness.coordinator.isPresenting)
        XCTAssertEqual(harness.messages, ["This request is no longer pending."])
        XCTAssertEqual(harness.focusCount, 0)
    }

    func testLateDecisionAfterExpiryOrCancellationDoesNotApply() {
        for cancelled in [false, true] {
            let harness = Harness()
            harness.pending = [request("first")]
            harness.coordinator.presentPendingApproval()
            if cancelled { harness.pending = [] } else { harness.now.addTimeInterval(301) }
            harness.finish?(.once)
            XCTAssertTrue(harness.applied.isEmpty)
            XCTAssertFalse(harness.coordinator.isPresenting)
        }
    }

    func testPrivacyChangeClosesOpenPanelWithoutFocusOrDetailLoadsAndReopensOnUnlock() {
        for state in [AgentApprovalScreenState.locked, .unknown] {
            let harness = Harness()
            harness.pending = [request("private")]
            harness.coordinator.presentPendingApproval()
            let loads = harness.loads
            harness.screenState = state
            harness.coordinator.presentPendingApproval(userInitiated: true)
            XCTAssertEqual(harness.loads, loads)
            XCTAssertEqual(harness.dismissCount, 1)
            XCTAssertEqual(harness.focusCount, 0)
            XCTAssertEqual(harness.messages, ["Unlock your Mac to review a pending request."])
            harness.screenState = .unlocked
            harness.coordinator.refreshAfterResume()
            XCTAssertEqual(harness.presented, ["private", "private"])
        }
    }

    func testPrivacyTimerCompletionWaitsForUnlockWithoutDeferringRequest() {
        let harness = Harness()
        harness.pending = [request("private")]
        harness.coordinator.presentPendingApproval()
        let loads = harness.loads
        harness.screenState = .locked
        harness.finish?(.once)
        XCTAssertEqual(harness.loads, loads)
        XCTAssertTrue(harness.applied.isEmpty)
        harness.screenState = .unlocked
        harness.coordinator.refreshAfterResume()
        XCTAssertEqual(harness.presented, ["private", "private"])
    }

    func testResumeRefreshRunsBeforePrivacyGateWithoutLoadingDetails() {
        let harness = Harness()
        harness.screenState = .locked
        harness.pending = [request("private")]
        harness.now.addTimeInterval(301)
        harness.coordinator.refreshAfterResume()
        XCTAssertEqual(harness.refreshes, 1)
        XCTAssertTrue(harness.pending.isEmpty)
        XCTAssertEqual(harness.loads, 0)
        XCTAssertEqual(harness.reminders, 1)
    }

    func testDecisionInFlightBlocksDuplicatePanelAndStaleCompletion() {
        let harness = Harness()
        harness.pending = [request("first"), request("second")]
        harness.coordinator.presentPendingApproval()
        let finish = harness.finish
        finish?(.once)
        finish?(.deny)
        harness.coordinator.presentPendingApproval(operationID: "second", userInitiated: true)
        XCTAssertEqual(harness.presented, ["first"])
        XCTAssertEqual(harness.applied, ["first"])
    }

    func testLockedAndUnknownScreensNeverLoadDetails() {
        for state in [AgentApprovalScreenState.locked, .unknown] {
            let harness = Harness()
            harness.screenState = state
            harness.pending = [request("private")]
            harness.coordinator.presentPendingApproval()
            XCTAssertEqual(harness.loads, 0)
            XCTAssertEqual(harness.reminders, 1)
            XCTAssertEqual(harness.presented, [])
        }
    }

    private func request(_ id: String, deadline: Date = Date(timeIntervalSince1970: 2_000_000_300)) -> BrokerPendingApproval {
        .init(requestID: id, capability: "synthetic-\(id)", request: .init(
            operationID: id, credentialID: id, targetID: id,
            operation: .create, payloadDigest: String(repeating: "a", count: 64)
        ), expiresAt: deadline)
    }

    @MainActor
    private final class Harness {
        var screenState = AgentApprovalScreenState.unlocked
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        var pending: [BrokerPendingApproval] = []
        var currentDisplay = "main"
        var panelDisplay: String?
        var panelCovered = false
        var presented: [String] = []
        var finish: ((BrokerApprovalDecision?) -> Void)?
        var loads = 0
        var reminders = 0
        var focusCount = 0
        var dismissCount = 0
        var refreshes = 0
        var messages: [String] = []
        var applied: [String] = []
        lazy var coordinator = AgentApprovalPresentationCoordinator(
            screenState: { self.screenState },
            loadPending: { self.loads += 1; return self.pending },
            clock: { self.now },
            refreshExpiration: {
                self.refreshes += 1
                self.pending.removeAll { $0.expiresAt.map { $0 <= self.now } == true }
            },
            lockedReminder: { _, _ in self.reminders += 1 },
            feedback: { self.messages.append($0) },
            present: { pending, _, finish in
                self.presented.append(pending.request.operationID)
                self.panelDisplay = self.currentDisplay
                self.panelCovered = false
                self.finish = finish
                return AgentApprovalPanelActions(bringForward: {
                    self.focusCount += 1
                    self.panelDisplay = self.currentDisplay
                    self.panelCovered = false
                }, dismiss: { self.dismissCount += 1; finish(nil) })
            },
            applyDecision: { pending, _ in self.applied.append(pending.request.operationID) }
        )
    }
}
