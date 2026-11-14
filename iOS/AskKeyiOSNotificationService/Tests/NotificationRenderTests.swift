import AskKeyDevices
import SwiftUI
import UserNotifications
import XCTest

/// Renders the notifications the extension produces, in English and
/// Simplified Chinese, for review. The texts come from the extension's own
/// processor and catalog; only the banner around them is drawn here, after
/// the system's style. `build-ios.sh test` passes the output directory; CI
/// uploads it with the app's screens.
@MainActor
final class NotificationRenderTests: XCTestCase {
    private static let languages = ["en", "zh-Hans"]
    private static let width: CGFloat = 393

    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["SCREEN_RENDER_DIRECTORY"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyiOSScreens", isDirectory: true)
    }

    private func render(_ name: String, file: StaticString = #filePath, line: UInt = #line,
                        content: (NotificationStrings) async throws -> UNNotificationContent) async throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var images: [Data] = []
        for language in Self.languages {
            let notification = try await content(try NotificationStrings.table(language))
            let view = NotificationBanner(title: notification.title, message: notification.body)
                .padding(.horizontal, 8)
                .padding(.vertical, 24)
                .frame(width: Self.width)
                .background(LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.32),
                                                    Color(red: 0.42, green: 0.3, blue: 0.36)],
                                           startPoint: .top, endPoint: .bottom))
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage, "\(name) did not render", file: file, line: line)
            let data = try XCTUnwrap(image.pngData(), file: file, line: line)
            try data.write(to: outputDirectory.appendingPathComponent("\(name)-\(language).png"))
            images.append(data)
        }
        XCTAssertNotEqual(images[0], images[1], "\(name) looks the same in both languages", file: file, line: line)
    }

    private func requestContent(_ display: ApprovalRequestDisplay, macName: String,
                                strings: NotificationStrings) async throws -> UNNotificationContent {
        let world = try NotificationWorld(macName: macName)
        let (sealed, push) = try world.sendRequest(display: display)
        let decision = try await world.process(push, strings: strings)
        XCTAssertNotNil(decision.request)
        return NotificationContentBuilder.content(decision, recordName: sealed.sealed.envelope.recordName, strings: strings)
    }

    func testVerifiedRequest() async throws {
        try await render("50-notification-request") { strings in
            try await requestContent(NotificationWorld.sampleDisplay, macName: "MacBook Pro", strings: strings)
        }
    }

    func testVerifiedRequestWithShortenedNames() async throws {
        let display = ApprovalRequestDisplay(
            requesterName: "Release automation agent for the web team", purpose: "",
            credentialName: "Production database read-only replica credentials", commandLine: "./x",
            workingDirectory: "", executableName: "/usr/local/bin/run-nightly-database-maintenance.sh",
            deliveryRows: [ApprovalDeliveryRow(kind: .environmentVariable, label: "", variable: "TOKEN")])
        try await render("51-notification-request-shortened") { strings in
            try await requestContent(display, macName: "Studio Mac in the second-floor lab", strings: strings)
        }
    }

    func testGenericText() async throws {
        try await render("52-notification-generic") { strings in
            NotificationContentBuilder.content(.generic(.notApprover), recordName: MessageID.random().text, strings: strings)
        }
    }
}

/// A notification banner after the system's style: the app's icon, the
/// title and the body. Test-only; the extension draws nothing.
private struct NotificationBanner: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(red: 0.78, green: 0.19, blue: 0.16))
                .frame(width: 38, height: 38)
                .overlay(Image(systemName: "key.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.subheadline.weight(.semibold))
                Text(verbatim: message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.95).opacity(0.92)))
    }
}
