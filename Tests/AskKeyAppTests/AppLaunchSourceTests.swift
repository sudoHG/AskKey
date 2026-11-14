import AppKit
import CoreServices
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyBroker

final class AppLaunchSourceTests: XCTestCase {
    private let executable = "/Applications/Ask Key.app/Contents/MacOS/AskKeyApp"

    func testLoginwindowPropDataMarksALoginLaunch() {
        let event = Self.openApplication(propData: OSType(keyAELaunchedAsLogInItem))
        XCTAssertEqual(AppLaunchSource(event: event, arguments: [executable]), .loginItem)
    }

    func testLaunchedAsLogInItemKeywordIsAlsoALoginLaunch() {
        let event = Self.openApplication()
        event.setParam(
            NSAppleEventDescriptor(boolean: true),
            forKeyword: AEKeyword(keyAELaunchedAsLogInItem)
        )
        XCTAssertEqual(AppLaunchSource(event: event, arguments: [executable]), .loginItem)
    }

    func testBareOpenApplicationIsAUserLaunch() {
        // Finder, the Dock, Spotlight, Launchpad and `open` send this shape.
        XCTAssertEqual(AppLaunchSource(event: Self.openApplication(), arguments: [executable]), .active)
    }

    func testOtherPropDataOrEventsAreUserLaunches() {
        let serviceItem = Self.openApplication(propData: OSType(keyAELaunchedAsServiceItem))
        XCTAssertEqual(AppLaunchSource(event: serviceItem, arguments: [executable]), .active)

        let reopen = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        reopen.setParam(
            NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)),
            forKeyword: AEKeyword(keyAEPropData)
        )
        XCTAssertEqual(AppLaunchSource(event: reopen, arguments: [executable]), .active)
    }

    func testMissingEventIsAUserLaunch() {
        XCTAssertEqual(AppLaunchSource(event: nil, arguments: [executable]), .active)
    }

    func testHelperOpenArgumentsMarkAHelperLaunch() {
        // What `askkey open` passes after `--args` is what the App recognises.
        let bundle = URL(fileURLWithPath: "/Applications/Ask Key.app")
        let openArguments = HelperHostApplication.openArguments(for: bundle, backgroundLaunch: true)
        let passed = Array(openArguments.drop { $0 != "--args" }.dropFirst())
        XCTAssertFalse(passed.isEmpty)

        XCTAssertEqual(
            AppLaunchSource(event: Self.openApplication(), arguments: [executable] + passed),
            .helper
        )
        XCTAssertEqual(AppLaunchSource(event: nil, arguments: [executable] + passed), .helper)
    }

    func testHelperFlagIsIgnoredAsTheExecutablePath() {
        let source = AppLaunchSource(
            event: Self.openApplication(),
            arguments: [HelperHostApplication.backgroundLaunchArgument]
        )
        XCTAssertEqual(source, .active)
    }

    func testLoginEventWinsOverTheHelperFlag() {
        let source = AppLaunchSource(
            event: Self.openApplication(propData: OSType(keyAELaunchedAsLogInItem)),
            arguments: [executable, HelperHostApplication.backgroundLaunchArgument]
        )
        XCTAssertEqual(source, .loginItem)
    }

    func testEventSummaryListsKeysButNoValues() {
        let event = Self.openApplication(propData: OSType(keyAELaunchedAsLogInItem))
        event.setParam(
            NSAppleEventDescriptor(string: "SYNTHETIC-VALUE"),
            forKeyword: AEKeyword(keyDirectObject)
        )
        let summary = AppLaunchSource.eventSummary(event)
        XCTAssertTrue(summary.hasPrefix("aevt/oapp keys=["), summary)
        XCTAssertTrue(summary.contains("prdt"), summary)
        XCTAssertTrue(summary.contains("----"), summary)
        XCTAssertFalse(summary.contains("SYNTHETIC"), summary)
        XCTAssertFalse(summary.contains("lgit"), summary)

        XCTAssertEqual(
            AppLaunchSource.eventSummary(
                Self.openApplication(propData: OSType(keyAELaunchedAsLogInItem))
            ),
            "aevt/oapp keys=[prdt]"
        )
        XCTAssertEqual(AppLaunchSource.eventSummary(Self.openApplication()), "aevt/oapp keys=[]")
        XCTAssertEqual(AppLaunchSource.eventSummary(nil), "none")
    }

    func testLogNamesAreStable() {
        XCTAssertEqual(AppLaunchSource.active.logName, "active")
        XCTAssertEqual(AppLaunchSource.loginItem.logName, "loginItem")
        XCTAssertEqual(AppLaunchSource.helper.logName, "helper")
    }

    private static func openApplication(propData: OSType? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if let propData {
            event.setParam(
                NSAppleEventDescriptor(enumCode: propData),
                forKeyword: AEKeyword(keyAEPropData)
            )
        }
        return event
    }
}
