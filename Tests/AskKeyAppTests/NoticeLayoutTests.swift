import AppKit
import SwiftUI
import XCTest
@testable import AskKeyAppKit

@MainActor
final class NoticeLayoutTests: AskKeyAppTestCase {
    func testNoticesStayInsideContentAndShellReachesBothWindowEdges() throws {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        for language in ["en", "zh-Hans"] {
            for state in [SettingsEntryState.onboarding, .empty, .locked, .management] {
                for (recovery, broker) in [(false, false), (true, false), (false, true), (true, true)] {
                    let model = try NoticeLayoutFixtures.Model(
                        language: language, state: state, recovery: recovery, broker: broker
                    )
                    defer { model.close() }
                    let host = NoticeLayoutFixtures.Host(model: model)
                    defer { host.close() }
                    let context = "\(language) \(state) recovery=\(recovery) broker=\(broker)"
                    let window = host.window
                    let bounds = host.view.convert(host.view.bounds, to: nil)
                    let raster = try NoticeRaster(host.render(includingChrome: false))
                    XCTAssertEqual(window.frame.size, ManagementWindowConfiguration.frameSize, context)
                    XCTAssertEqual(bounds.size, ManagementWindowConfiguration.frameSize, context)
                    let titlebar = CGRect(x: bounds.minX, y: window.contentLayoutRect.maxY,
                                          width: bounds.width, height: bounds.maxY - window.contentLayoutRect.maxY)
                    XCTAssertGreaterThan(titlebar.height, 0, context)
                    let columnX = WorkspaceVisualContract.sidebarWidth + 1
                    let columnWidth = bounds.width - columnX
                    var notices: [CGRect] = []
                    let templates: [(Bool, AnyView)] = [
                        (recovery, AnyView(AgentAccessPolicyNotice())),
                        (broker, AnyView(BrokerRecoveryNotice())),
                    ]
                    for (shown, view) in templates where shown {
                        let bitmap = try NoticeLayoutFixtures.notice(view, model: model, width: columnWidth)
                        let template = try NoticeRaster(bitmap)
                        let match = raster.find(template, atX: columnX)
                        if match == nil {
                            try host.export("unmatched-management")
                            try NoticeLayoutFixtures.export(bitmap, name: "unmatched-management-template")
                        }
                        // Hidden windows have no AX children. Locate each complete rendered
                        // notice by its pixels, then compare its actual frame with AppKit's chrome.
                        let frame = try XCTUnwrap(match, "Missing or clipped notice: \(context)")
                        XCTAssertFalse(frame.intersects(titlebar), context)
                        XCTAssertEqual(frame.minX, columnX, accuracy: 1, context)
                        XCTAssertTrue(bounds.contains(frame), context)
                        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                            let control = try XCTUnwrap(window.standardWindowButton(button))
                            XCTAssertFalse(frame.intersects(control.convert(control.bounds, to: nil)), context)
                        }
                        notices.append(frame)
                    }
                    if notices.count == 2 {
                        XCTAssertLessThanOrEqual(notices[1].maxY, notices[0].minY, context)
                    }
                    try assertShellEdges(raster, host: host, model: model, context: context)
                    if (state == .locked && recovery && !broker)
                        || (state == .management && (recovery || broker)) {
                        try host.export("\(language)-\(state)-\(recovery ? "recovery" : "no-recovery")-\(broker ? "broker" : "no-broker")")
                    }
                }
            }
        }
    }

    func testPopoverRecoveryNoticeFitsItsWidthInBothLanguages() throws {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        for language in ["en", "zh-Hans"] {
            let model = try NoticeLayoutFixtures.Model(language: language, state: .locked, recovery: true, broker: false)
            defer { model.close() }
            let host = NoticeLayoutFixtures.Host(model: model, popover: true)
            defer { host.close() }
            let raster = try NoticeRaster(host.render(includingChrome: false))
            let bitmap = try NoticeLayoutFixtures.notice(
                AgentAccessPolicyNotice(showsResumeAction: false), model: model, width: 260, popover: true
            )
            let template = try NoticeRaster(bitmap)
            let match = raster.find(template, atX: 0)
            if match == nil {
                try host.export("unmatched-popover")
                try NoticeLayoutFixtures.export(bitmap, name: "unmatched-popover-template")
            }
            XCTAssertEqual(host.view.bounds.width, 260, accuracy: 1)
            let frame = try XCTUnwrap(match, "The full \(language) recovery notice must fit")
            XCTAssertTrue(host.view.bounds.contains(frame))
            XCTAssertGreaterThan(frame.minY, 4 * 30, "The menu actions fit below the full notice")
            try host.export("\(language)-popover-recovery")
        }
    }

    private func assertShellEdges(
        _ raster: NoticeRaster, host: NoticeLayoutFixtures.Host,
        model: NoticeLayoutFixtures.Model, context: String
    ) throws {
        let sidebar = try NoticeRaster(NoticeLayoutFixtures.notice(Theme.sidebarBackground.frame(height: 2), model: model, width: 2))
        let content = try NoticeRaster(NoticeLayoutFixtures.notice(Theme.windowBackground.frame(height: 2), model: model, width: 2))
        // The outer edges contain no labels or controls. A shortened or shifted
        // shell leaves the NSWindow background here instead of the column colors.
        let sidebarGap = (0..<raster.height).first { y in
            !raster.matchesPixel(x: 0, y: y, other: sidebar, otherX: 0, otherY: 0)
        }
        XCTAssertNil(sidebarGap, "Sidebar must reach both window edges: \(context)")
        let contentGap = (Int((WorkspaceVisualContract.sidebarWidth + 2) * raster.scale)..<raster.width).first { x in
            !raster.matchesPixel(x: x, y: raster.height - 1, other: content, otherX: 0, otherY: 0)
        }
        XCTAssertNil(contentGap, "Content must reach the window bottom: \(context)")
        if sidebarGap != nil || contentGap != nil {
            let png = try XCTUnwrap(host.render().representation(using: .png, properties: [:]))
            print("NOTICE_LAYOUT_FAILURE_BEGIN \(context)")
            let encoded = Array(png.base64EncodedString())
            for start in stride(from: 0, to: encoded.count, by: 4_000) {
                print("NOTICE_LAYOUT_FAILURE_CHUNK \(String(encoded[start..<min(start + 4_000, encoded.count)]))")
            }
            print("NOTICE_LAYOUT_FAILURE_END")
        }
    }
}
