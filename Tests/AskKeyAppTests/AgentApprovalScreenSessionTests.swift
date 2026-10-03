import CoreGraphics
import XCTest
@testable import AskKeyApp

final class AgentApprovalScreenSessionTests: AskKeyAppTestCase {
    private var interactiveSession: [String: Any] {
        [kCGSessionOnConsoleKey: true, kCGSessionLoginDoneKey: true, kCGSessionUserIDKey: 501]
    }

    func testLoggedInOwnConsoleWithoutOptionalLockFlagCanPresentApproval() {
        XCTAssertEqual(AgentApprovalScreenSession.resolve(session: interactiveSession, userID: 501), .unlocked)
    }

    func testLockFlagAndForeignConsoleNeverPresentDetails() {
        var session = interactiveSession
        session["CGSSessionScreenIsLocked"] = true
        XCTAssertEqual(AgentApprovalScreenSession.resolve(session: session, userID: 501), .locked)
        session = interactiveSession
        session[kCGSessionOnConsoleKey] = false
        XCTAssertEqual(AgentApprovalScreenSession.resolve(session: session, userID: 501), .locked)
        XCTAssertEqual(AgentApprovalScreenSession.resolve(session: interactiveSession, userID: 502), .locked)
    }

    func testMissingMalformedAndLoginInProgressFailClosed() {
        XCTAssertEqual(AgentApprovalScreenSession.resolve(session: nil, userID: 501), .unknown)
        XCTAssertEqual(AgentApprovalScreenSession.resolve(session: [:], userID: 501), .unknown)
        var session = interactiveSession
        session["CGSSessionScreenIsLocked"] = "false"
        XCTAssertEqual(AgentApprovalScreenSession.resolve(session: session, userID: 501), .unknown)
        session = interactiveSession
        session[kCGSessionLoginDoneKey] = false
        XCTAssertEqual(AgentApprovalScreenSession.resolve(session: session, userID: 501), .unknown)
    }
}
