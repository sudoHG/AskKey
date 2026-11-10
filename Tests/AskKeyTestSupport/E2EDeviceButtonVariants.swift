import AppKit
import Observation
import SwiftUI

/// Diagnostics for #298, in the E2E App only: on macOS 26, clicks on Pair a Device… do not reach
/// its action, while Export Backup… in the same page works. This window shows replicas of the
/// Devices row, each without one of its differences from the Backup row, so a run shows which
/// difference keeps a click from the button.
@MainActor
enum E2EDeviceButtonVariants {
    private static var window: NSWindow?

    /// The replicas: each identifier's button reports `variant <identifier> fired` when its action runs.
    static let identifiers = ["full", "no-sheet", "item-sheet", "no-dimming", "disabled-only", "no-branch", "no-outer", "backup"]

    static func show(_ report: @escaping @MainActor (String) -> Void) {
        let content = ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(identifiers, id: \.self) { identifier in
                    VariantSection(identifier: identifier, report: report)
                }
            }
            .padding(16)
        }
        let window = NSWindow(contentRect: NSRect(x: 60, y: 40, width: 560, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("devices-variants")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }

    static func hide() {
        window?.close()
        window = nil
        NSApp.windows.first { $0.identifier?.rawValue == "settings" }?.makeKeyAndOrderFront(nil)
    }
}

@Observable
@MainActor
private final class VariantModel {
    var pairing: Int?
    var restarting = false
    var offersReset = false
    var confirming = false
    var issue: String?
    var items: [Int] = []
    var visible = true
    var canPair: Bool { pairing == nil && !confirming && items.count < 10 }
    var isSheetPresented: Bool { pairing != nil || restarting }
    func opened() async { items = [] }
}

private struct SheetItem: Identifiable { let id: Int }

/// The outer view, like `DevicesSettingsSection`: an optional model in `@State`.
private struct VariantSection: View {
    let identifier: String
    let report: @MainActor (String) -> Void
    @State private var model: VariantModel? = VariantModel()

    var body: some View {
        if identifier == "no-outer" {
            VariantContent(model: VariantModel(), identifier: identifier, report: report)
        } else if let model, model.visible {
            VariantContent(model: model, identifier: identifier, report: report)
        }
    }
}

/// `DevicesSectionContent` with one difference left out, named by `identifier`; "backup" is the Backup row.
private struct VariantContent: View {
    @Bindable var model: VariantModel
    let identifier: String
    let report: @MainActor (String) -> Void
    @State private var item: SheetItem?

    var body: some View {
        VariantGroup(header: identifier) {
            row
            if model.confirming { Text("Confirm") }
            ForEach(model.items, id: \.self) { Text("\($0)") }
            if let issue = model.issue { Text(issue) }
        }
        .onAppear { Task { await model.opened() } }
    }

    @ViewBuilder private var row: some View {
        switch identifier {
        case "no-sheet": VariantRow { control }
        case "item-sheet", "backup": VariantRow { control }.sheet(item: $item) { _ in Text("Sheet") }
        default:
            VariantRow { control }
                .sheet(isPresented: Binding(get: { model.isSheetPresented }, set: { if !$0 { model.pairing = nil } })) { Text("Sheet") }
        }
    }

    @ViewBuilder private var control: some View {
        if identifier == "no-branch" || identifier == "backup" {
            button
        } else if model.offersReset {
            Button("Reset", role: .destructive) {}.buttonStyle(VariantButtonStyle())
        } else {
            button
        }
    }

    @ViewBuilder private var button: some View {
        let base = Button("Pair \(identifier)", action: fire).buttonStyle(VariantButtonStyle())
        switch identifier {
        case "no-dimming", "backup": base.accessibilityIdentifier("variant-\(identifier)")
        case "disabled-only": base.disabled(!model.canPair).accessibilityIdentifier("variant-\(identifier)")
        default: base.disabled(!model.canPair).opacity(model.canPair ? 1 : 0.45).accessibilityIdentifier("variant-\(identifier)")
        }
    }

    private func fire() {
        Task { report("variant \(identifier) fired") }
    }
}

private struct VariantGroup<Content: View>: View {
    let header: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(header).font(.caption)
            VStack(spacing: 0) { content }
                .background(Color.white, in: .rect(cornerRadius: 10))
                .clipShape(.rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.3), lineWidth: 1))
        }
    }
}

private struct VariantRow<Control: View>: View {
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pairing")
                Text("Pair Ask Key on your iPhone with this Mac.").font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
    }
}

private struct VariantButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(configuration.isPressed ? Color.black.opacity(0.06) : Color.white, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.16), lineWidth: 1))
            .contentShape(Rectangle())
    }
}
