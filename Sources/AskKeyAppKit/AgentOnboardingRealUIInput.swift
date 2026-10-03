#if DEBUG
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Real-window input for 331-404 B2. Never calls `DebugPressRegistry`.
enum RealUIInput {
    struct Target {
        var identifier: String
        var role: String
        var title: String
        var frame: CGRect
        var enabled: Bool
        var hidden: Bool
        var source: String

        var visible: Bool {
            hidden == false && frame.width >= 2 && frame.height >= 2
        }

        var usable: Bool { visible && enabled }
    }

    struct HitRecord {
        var identifier: String
        var found: Bool = false
        var visible: Bool = false
        var enabled: Bool = false
        var role: String = ""
        var title: String = ""
        var frame: String = ""
        var source: String = ""
        var method: String = "none"
        var hitView: String = ""
        var detail: String = ""

        func line() -> String {
            "- input \(identifier) found=\(found) visible=\(visible) enabled=\(enabled) role=\(role) title=\(title) frame=\(frame) source=\(source) method=\(method) hit=\(hitView) \(detail)"
        }
    }

    static func describeChildren(identifier: String) -> String {
        guard let element = axElement(
            identifier: identifier,
            in: AXUIElementCreateApplication(pid_t(ProcessInfo.processInfo.processIdentifier))
        ) else {
            return "missing"
        }
        let children = axChildren(element).map { child in
            let role = axString(child, kAXRoleAttribute as String) ?? "?"
            let id = axString(child, kAXIdentifierAttribute as String) ?? ""
            let title = axString(child, kAXTitleAttribute as String) ?? ""
            return "\(role)#\(id):\(title)"
        }
        return children.isEmpty ? "none" : children.joined(separator: ",")
    }

    static func describeTree(limit: Int = 40) -> [String] {
        var lines: [String] = []
        collect(AXUIElementCreateApplication(pid_t(ProcessInfo.processInfo.processIdentifier)), into: &lines, limit: limit)
        return lines
    }

    static func find(identifier: String) -> Target? {
        let system = findAX(identifier: identifier, in: AXUIElementCreateApplication(pid_t(ProcessInfo.processInfo.processIdentifier)))
        var appKit: Target?
        for window in NSApp.windows {
            if let content = window.contentView,
               let found = findAppKit(identifier: identifier, in: content) {
                appKit = found
                break
            }
        }
        switch (system, appKit) {
        case (let system?, let appKit?):
            return system.frame.width * system.frame.height >= appKit.frame.width * appKit.frame.height
                ? system : appKit
        case (let system?, nil):
            return system
        case (nil, let appKit?):
            return appKit
        case (nil, nil):
            return nil
        }
    }

    @discardableResult
    static func clickVisible(
        identifier: String,
        window: NSWindow,
        record: (String) -> Void
    ) -> HitRecord {
        var hit = HitRecord(identifier: identifier)
        guard let target = find(identifier: identifier) else {
            hit.detail = "target-not-in-ax-or-appkit"
            record(hit.line())
            record("- FAIL: \(identifier) not found as a visible control; no Registry fallback")
            return hit
        }
        hit.found = true
        hit.visible = target.visible
        hit.enabled = target.enabled
        hit.role = target.role
        hit.title = target.title
        hit.frame = NSStringFromRect(target.frame)
        hit.source = target.source
        guard target.usable else {
            hit.detail = "not-usable"
            record(hit.line())
            record("- FAIL: \(identifier) found but visible=\(target.visible) enabled=\(target.enabled); no Registry fallback")
            return hit
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if clickWithNSEvent(target: target, window: window, hit: &hit) {
            hit.method = "mouse-nsevent-sent"
            hit.detail = "window-local mouse; SwiftUI may ignore unless hit-tested"
            record(hit.line())
            return hit
        }
        if performSystemAXPress(identifier: identifier) {
            hit.method = "ax-system-press"
            hit.detail = "nsevent-create-failed-then-system-ax"
            record(hit.line())
            return hit
        }
        hit.method = "none"
        hit.detail = "mouse-and-system-ax-failed"
        record(hit.line())
        record("- FAIL: \(identifier) usable but neither window-local mouse nor system AX press could be delivered; no Registry fallback")
        return hit
    }

    @discardableResult
    static func systemAXPress(identifier: String, record: (String) -> Void) -> Bool {
        guard let target = find(identifier: identifier), target.usable else {
            record("- FAIL: system AX press skipped, \(identifier) not usable; no Registry fallback")
            return false
        }
        let ok = performSystemAXPress(identifier: identifier)
        record("- input \(identifier) method=ax-system-press ok=\(ok) role=\(target.role) frame=\(NSStringFromRect(target.frame))")
        return ok
    }

    static func keyboardFocusIdentifier(window: NSWindow) -> String {
        if let view = window.firstResponder as? NSView {
            let identifier = view.accessibilityIdentifier()
            if !identifier.isEmpty { return "firstResponder:\(identifier)" }
            return "firstResponder:\(type(of: view))"
        }
        if let responder = window.firstResponder {
            return "firstResponder:\(type(of: responder))"
        }
        return "firstResponder:nil"
    }

    struct FocusObservation {
        var focusedCopyError: String
        var identifier: String
        var role: String
        var title: String
        var focusedAttribute: String
        var pid: String
        var samePID: Bool
        var windowTitle: String
        var windowError: String
        var sameWindow: Bool
        var frame: String
        var firstResponder: String
        var targetFocusedAttribute: String

        var isReadable: Bool {
            focusedCopyError == "0" || focusedCopyError == "0/nil"
        }

        func matches(identifier expected: String) -> Bool {
            if targetFocusedAttribute == "true" { return true }
            guard samePID else { return false }
            if identifier == expected { return true }
            if let target = find(identifier: expected),
               let focused = nsRect(from: frame),
               abs(target.frame.midX - focused.midX) < 2,
               abs(target.frame.midY - focused.midY) < 2,
               target.frame.width > 1 {
                return true
            }
            return false
        }

        func line(step: Int) -> String {
            "- Tab step \(step) axFocused err=\(focusedCopyError) id=\(identifier) role=\(role) title=\(title) AXFocused=\(focusedAttribute) pid=\(pid) samePID=\(samePID) window=\(windowTitle) windowErr=\(windowError) sameWindow=\(sameWindow) frame=\(frame) targetAXFocused=\(targetFocusedAttribute) \(firstResponder)"
        }
    }

    static func observeFocus(window: NSWindow, targetIdentifier: String) -> FocusObservation {
        let app = AXUIElementCreateApplication(pid_t(ProcessInfo.processInfo.processIdentifier))
        let (focusedError, focusedRef) = axCopy(app, "AXFocusedUIElement")
        var observation = FocusObservation(
            focusedCopyError: "\(focusedError.rawValue)",
            identifier: "",
            role: "",
            title: "",
            focusedAttribute: "unread",
            pid: "",
            samePID: false,
            windowTitle: "",
            windowError: "",
            sameWindow: false,
            frame: "",
            firstResponder: keyboardFocusIdentifier(window: window),
            targetFocusedAttribute: targetAXFocused(identifier: targetIdentifier)
        )
        guard focusedError == .success, let focusedRef else {
            if focusedError == .success {
                observation.focusedCopyError = "0/nil"
            }
            return observation
        }
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            observation.focusedCopyError = "\(focusedError.rawValue)/not-ax-element"
            return observation
        }
        let focused = unsafeBitCast(focusedRef, to: AXUIElement.self)
        observation.identifier = axString(focused, kAXIdentifierAttribute as String) ?? ""
        observation.role = axString(focused, kAXRoleAttribute as String) ?? ""
        observation.title = axString(focused, kAXTitleAttribute as String)
            ?? axString(focused, kAXDescriptionAttribute as String)
            ?? ""
        if let frame = axFrame(focused) {
            observation.frame = NSStringFromRect(frame)
        }
        let (focusedAttrError, focusedAttr) = axCopy(focused, "AXFocused")
        if focusedAttrError == .success, let focusedAttr, let flag = focusedAttr as? Bool {
            observation.focusedAttribute = flag ? "true" : "false"
        } else {
            observation.focusedAttribute = "unread:\(focusedAttrError.rawValue)"
        }
        var pid: pid_t = 0
        let pidError = AXUIElementGetPid(focused, &pid)
        if pidError == .success {
            observation.pid = "\(pid)"
            observation.samePID = pid == ProcessInfo.processInfo.processIdentifier
        } else {
            observation.pid = "unread:\(pidError.rawValue)"
        }
        let (windowError, windowRef) = axCopy(focused, "AXWindow")
        observation.windowError = "\(windowError.rawValue)"
        if windowError == .success, let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() {
            let axWindow = unsafeBitCast(windowRef, to: AXUIElement.self)
            observation.windowTitle = axString(axWindow, kAXTitleAttribute as String) ?? ""
            if let axFrame = axFrame(axWindow) {
                observation.sameWindow = window.frame.intersects(axFrame)
                    || observation.windowTitle == window.title
            } else {
                observation.sameWindow = observation.windowTitle == window.title && !window.title.isEmpty
            }
        }
        return observation
    }

    private static func targetAXFocused(identifier: String) -> String {
        guard let element = axElement(
            identifier: identifier,
            in: AXUIElementCreateApplication(pid_t(ProcessInfo.processInfo.processIdentifier))
        ) else {
            return "missing"
        }
        let (error, ref) = axCopy(element, "AXFocused")
        if error == .success, let ref, let flag = ref as? Bool {
            return flag ? "true" : "false"
        }
        return "unread:\(error.rawValue)"
    }

    private static func nsRect(from text: String) -> CGRect? {
        guard !text.isEmpty else { return nil }
        return NSRectFromString(text)
    }

    @discardableResult
    static func sendKey(_ characters: String, keyCode: UInt16, to window: NSWindow) -> Bool {
        guard let events = makeKeyEvents(characters, keyCode: keyCode, window: window) else { return false }
        window.sendEvent(events.down)
        window.sendEvent(events.up)
        return true
    }

    @discardableResult
    static func sendAppKey(_ characters: String, keyCode: UInt16, to window: NSWindow) -> Bool {
        guard let events = makeKeyEvents(characters, keyCode: keyCode, window: window) else { return false }
        NSApp.sendEvent(events.down)
        NSApp.sendEvent(events.up)
        return true
    }

    @discardableResult
    static func sendResponderKey(_ characters: String, keyCode: UInt16, to window: NSWindow) -> Bool {
        guard let events = makeKeyEvents(characters, keyCode: keyCode, window: window),
              let responder = window.firstResponder else {
            return false
        }
        responder.keyDown(with: events.down)
        responder.keyUp(with: events.up)
        return true
    }

    private static func makeKeyEvents(
        _ characters: String,
        keyCode: UInt16,
        window: NSWindow
    ) -> (down: NSEvent, up: NSEvent)? {
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ), let up = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { return nil }
        return (down, up)
    }

    private static func clickWithNSEvent(
        target: Target,
        window: NSWindow,
        hit: inout HitRecord
    ) -> Bool {
        let screenPoint = CGPoint(x: target.frame.midX, y: target.frame.midY)
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        if let content = window.contentView {
            let local = content.convert(windowPoint, from: nil)
            if let view = content.hitTest(local) {
                hit.hitView = String(describing: type(of: view))
            } else {
                hit.hitView = "nil"
            }
        }
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 331_404,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp + 0.02,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 331_405,
            clickCount: 1,
            pressure: 1
        ) else {
            hit.detail = "nsevent-create-failed"
            return false
        }
        window.sendEvent(down)
        window.sendEvent(up)
        return true
    }

    private static func performSystemAXPress(identifier: String) -> Bool {
        guard let element = axElement(
            identifier: identifier,
            in: AXUIElementCreateApplication(pid_t(ProcessInfo.processInfo.processIdentifier))
        ) else {
            return false
        }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private static func findAX(identifier: String, in element: AXUIElement) -> Target? {
        guard let found = axElement(identifier: identifier, in: element) else { return nil }
        return target(from: found, identifier: identifier, source: "ax-system")
    }

    private static func axElement(identifier: String, in element: AXUIElement) -> AXUIElement? {
        if axString(element, kAXIdentifierAttribute as String) == identifier {
            return element
        }
        for child in axChildren(element) {
            if let found = axElement(identifier: identifier, in: child) {
                return found
            }
        }
        return nil
    }

    private static func findAppKit(identifier: String, in view: NSView) -> Target? {
        if view.accessibilityIdentifier() == identifier {
            return Target(
                identifier: identifier,
                role: view.accessibilityRole()?.rawValue ?? "Unknown",
                title: view.accessibilityLabel() ?? view.accessibilityTitle() ?? "",
                frame: view.accessibilityFrame(),
                enabled: view.isEnabledIfControl,
                hidden: view.isHiddenOrHasHiddenAncestor,
                source: "appkit-ax"
            )
        }
        if let children = view.accessibilityChildren() as? [NSObject] {
            for child in children {
                if let nested = child as? NSView, let found = findAppKit(identifier: identifier, in: nested) {
                    return found
                }
                if let element = child as? NSAccessibilityElement,
                   element.accessibilityIdentifier() == identifier {
                    return Target(
                        identifier: identifier,
                        role: element.accessibilityRole()?.rawValue ?? "Unknown",
                        title: element.accessibilityLabel() ?? "",
                        frame: element.accessibilityFrame(),
                        enabled: element.isAccessibilityEnabled(),
                        hidden: false,
                        source: "appkit-element"
                    )
                }
            }
        }
        for subview in view.subviews {
            if let found = findAppKit(identifier: identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    private static func target(from element: AXUIElement, identifier: String, source: String) -> Target {
        Target(
            identifier: identifier,
            role: axString(element, kAXRoleAttribute as String) ?? "",
            title: axString(element, kAXTitleAttribute as String)
                ?? axString(element, kAXDescriptionAttribute as String)
                ?? "",
            frame: axFrame(element) ?? .zero,
            enabled: axBool(element, kAXEnabledAttribute as String) ?? true,
            hidden: axBool(element, kAXHiddenAttribute as String) ?? false,
            source: source
        )
    }

    private static func collect(_ element: AXUIElement, into lines: inout [String], limit: Int) {
        guard lines.count < limit else { return }
        let identifier = axString(element, kAXIdentifierAttribute as String) ?? ""
        if !identifier.isEmpty {
            let frame = axFrame(element) ?? .zero
            let role = axString(element, kAXRoleAttribute as String) ?? ""
            let enabled = axBool(element, kAXEnabledAttribute as String) ?? true
            lines.append(
                "- ax \(identifier) role=\(role) enabled=\(enabled) frame=\(NSStringFromRect(frame))"
            )
        }
        for child in axChildren(element) {
            collect(child, into: &lines, limit: limit)
        }
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let ref,
              let children = ref as? [AXUIElement] else {
            return []
        }
        return children
    }

    private static func axCopy(_ element: AXUIElement, _ attribute: String) -> (AXError, CFTypeRef?) {
        var ref: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        return (error, ref)
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        let (error, ref) = axCopy(element, attribute)
        guard error == .success else { return nil }
        return ref as? String
    }

    private static func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? Bool
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &ref) == .success,
              let ref else {
            return nil
        }
        guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        // Type ID already matched AXValue; bitcast cannot represent another CF type here.
        var rect = CGRect.zero
        let value = unsafeBitCast(ref, to: AXValue.self)
        guard AXValueGetValue(value, .cgRect, &rect) else { return nil }
        return rect
    }
}

private extension NSView {
    var isEnabledIfControl: Bool {
        if let control = self as? NSControl { return control.isEnabled }
        return isAccessibilityEnabled()
    }
}
#endif
