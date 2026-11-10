import AppKit

/// Diagnostics for #298, in the E2E App only: XCTest's click on Pair a Device… opened no sheet,
/// and full-tree queries timed out after a pairing. They record which window and views receive
/// the App's mouse events, and the App's own accessibility tree. Nothing they record carries a
/// pairing code or QR payload: the Mac never shows its code, and the QR image's label names it only.
@MainActor
enum E2EDeviceDiagnostics {
    private static var monitor: Any?
    private static var walks = 0

    /// Reports each left mouse down and up the App receives.
    static func recordMouseEvents(_ report: @escaping @MainActor (String) -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            report(describe(event))
            return event
        }
    }

    /// Walks every window's accessibility tree in the App's process and writes the listing,
    /// with each visible window's AppKit views and their frames, to `device-ax-walk-<n>.txt`.
    /// Returns a summary: the element count, any cycle, the slowest elements, the first
    /// responder, and the AppKit views under the Pair a Device… button.
    static func walkAccessibility(control: URL) -> String {
        walks += 1
        var lines: [String] = [], slow: [String] = []
        var seen = Set<ObjectIdentifier>()
        var count = 0, cycles = 0, widest = 0
        var pairFrame: NSRect?
        let start = Date()
        func walk(_ object: Any, depth: Int) {
            guard count < 30_000, Date().timeIntervalSince(start) < 10 else { return }
            let node = object as AnyObject
            let pad = String(repeating: " ", count: depth)
            guard seen.insert(ObjectIdentifier(node)).inserted else {
                cycles += 1
                lines.append(pad + "CYCLE \(type(of: node))")
                return
            }
            count += 1
            guard let element = node as? NSObject else { return lines.append(pad + "not an object: \(type(of: node))") }
            let began = Date()
            let role = element.accessibilityAttributeValue(.role) as? String ?? "-"
            let identifier = element.accessibilityAttributeValue(.identifier) as? String ?? ""
            let label = element.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXDescription")) as? String
                ?? element.accessibilityAttributeValue(.title) as? String ?? ""
            let value = element.accessibilityAttributeValue(.value).map { String(describing: $0) } ?? ""
            let frame = (element as? NSAccessibilityElementProtocol)?.accessibilityFrame() ?? .zero
            let focused = element.accessibilityAttributeValue(.focused) as? Bool ?? false
            let children = element.accessibilityAttributeValue(.children) as? [Any] ?? []
            let elapsed = Date().timeIntervalSince(began)
            widest = max(widest, children.count)
            if identifier == "settings-pair-device" { pairFrame = frame }
            let line = "\(pad)\(type(of: node)) role=\(role) id=\(identifier) label=\(label.prefix(60)) value=\(value.prefix(60)) "
                + "frame=\(frame) focused=\(focused) children=\(children.count) took=\(String(format: "%.3f", elapsed))"
            lines.append(line)
            if elapsed > 0.05 { slow.append(line) }
            for child in children { walk(child, depth: depth + 1) }
        }
        for window in NSApp.windows { walk(window, depth: 0) }
        let summary = "accessibility walk \(walks): elements=\(count) cycles=\(cycles) widest=\(widest) slow=\(slow.count) "
            + "took=\(String(format: "%.2f", Date().timeIntervalSince(start))) key=\(NSApp.keyWindow.map(name) ?? "none") "
            + "firstResponder=\(NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none") "
            + "windows=\(NSApp.windows.map { "\(name($0)) visible=\($0.isVisible) sheet=\($0.attachedSheet != nil)" }) "
            + "pair=\(pairFrame.map(viewsUnder) ?? "absent")"
        var views: [String] = []
        func dump(_ view: NSView, depth: Int) {
            guard views.count < 2_000 else { return }
            let frame = view.window.map { _ in view.convert(view.bounds, to: nil) } ?? view.frame
            views.append("\(String(repeating: " ", count: depth))\(type(of: view)) window-frame=\(frame) hidden=\(view.isHidden) "
                + "alpha=\(view.alphaValue) layer=\(view.wantsLayer)")
            for subview in view.subviews { dump(subview, depth: depth + 1) }
        }
        for window in NSApp.windows where window.isVisible {
            views.append("VIEWS \(name(window)) frame=\(window.frame)")
            if let frameView = window.contentView?.superview { dump(frameView, depth: 1) }
        }
        let listing = ([summary] + slow.map { "SLOW " + $0 } + views + lines).joined(separator: "\n")
        try? listing.write(to: control.appendingPathComponent("device-ax-walk-\(walks).txt"), atomically: true, encoding: .utf8)
        return summary
    }

    /// Posts a left mouse down and up to the App's own event queue at a point in XCTest's screen
    /// coordinates (top-left origin), as AppKit would queue a hardware click. Both are queued
    /// together, so a view that tracks the mouse after the down finds the up.
    static func postClick(atRunnerPoint point: NSPoint) async -> String {
        guard let screen = NSScreen.screens.first else { return "no screen" }
        let screenPoint = NSPoint(x: point.x, y: screen.frame.maxY - point.y)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.level == .normal && $0.frame.contains(screenPoint) }) else {
            return "no window at \(screenPoint)"
        }
        let location = window.convertPoint(fromScreen: screenPoint)
        let now = ProcessInfo.processInfo.systemUptime
        let events = [(NSEvent.EventType.leftMouseDown, now, Float(1)), (.leftMouseUp, now + 0.1, Float(0))].compactMap { type, time, pressure in
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: pressure)
        }
        events.forEach { NSApp.postEvent($0, atStart: false) }
        try? await Task.sleep(for: .milliseconds(500))
        return "posted \(events.count) events at \(location) in \(name(window))"
    }

    /// The accessibility element at a point in XCTest's screen coordinates, then its press action,
    /// which runs a button's action without any mouse event.
    static func pressAccessibilityElement(atRunnerPoint point: NSPoint) async -> String {
        guard let screen = NSScreen.screens.first else { return "no screen" }
        let screenPoint = NSPoint(x: point.x, y: screen.frame.maxY - point.y)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.level == .normal && $0.frame.contains(screenPoint) }) else {
            return "no window at \(screenPoint)"
        }
        guard let element = window.accessibilityHitTest(screenPoint) as? NSObject else { return "no element at \(screenPoint)" }
        let role = element.accessibilityAttributeValue(.role) as? String ?? "-"
        let identifier = element.accessibilityAttributeValue(.identifier) as? String ?? ""
        let actions = element.accessibilityActionNames()
        element.accessibilityPerformAction(.press)
        try? await Task.sleep(for: .milliseconds(500))
        return "pressed \(type(of: element)) role=\(role) id=\(identifier) actions=\(actions.map(\.rawValue))"
    }

    /// The AppKit views under the centre of a screen rectangle, in each visible window containing it.
    private static func viewsUnder(_ screenFrame: NSRect) -> String {
        let point = NSPoint(x: screenFrame.midX, y: screenFrame.midY)
        let hits = NSApp.windows.filter { $0.isVisible && $0.frame.contains(point) }.map { window in
            "\(name(window)) frame=\(screenFrame) hit=\(chain(window, at: window.convertPoint(fromScreen: point)))"
        }
        return hits.isEmpty ? "no window at \(point)" : hits.joined(separator: "; ")
    }

    private static func describe(_ event: NSEvent) -> String {
        let window = event.window
        let down = event.type == .leftMouseDown
        var text = "\(down ? "mouse down" : "mouse up") window=\(window.map(name) ?? "none") key=\(window?.isKeyWindow ?? false) "
            + "active=\(NSApp.isActive) point=\(event.locationInWindow) screen=\(NSEvent.mouseLocation) "
            + "hit=\(window.map { chain($0, at: event.locationInWindow) } ?? "none") "
            + "firstResponder=\(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none") "
            + "sheet=\(window?.attachedSheet != nil) clicks=\(event.clickCount)"
        if down {
            text += " visible=\(NSApp.windows.filter(\.isVisible).map { "\(name($0)) level=\($0.level.rawValue) frame=\($0.frame)" })"
        }
        return text
    }

    private static func chain(_ window: NSWindow, at point: NSPoint) -> String {
        var views: [String] = []
        var view = window.contentView?.superview?.hitTest(point)
        while let current = view, views.count < 8 {
            views.append(String(describing: type(of: current)))
            view = current.superview
        }
        return "\(views)"
    }

    private static func name(_ window: NSWindow) -> String {
        "\(type(of: window))[\(window.identifier?.rawValue ?? "-")]"
    }
}
