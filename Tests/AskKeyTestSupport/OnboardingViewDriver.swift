import AppKit
import AskKeyAppKit

/// Wiring-test driver installed explicitly on the hosted view's environment.
@MainActor
package final class OnboardingViewDriver {
    private var actions: [String: () -> Void] = [:]

    package init() {}

    package var registration: ViewActionRegistration {
        ViewActionRegistration { [weak self] identifier, action in
            // Keep the latest action across SwiftUI onDisappear/re-render cycles.
            self?.actions[identifier] = action
        }
    }

    @discardableResult
    package func press(identifier: String, in view: NSView) -> Bool {
        if pressRegistered(identifier) { return true }
        if pressObject(identifier, view) { return true }
        for subview in view.subviews {
            if pressObject(identifier, subview) { return true }
            if press(identifier: identifier, in: subview) { return true }
        }
        for window in NSApp.windows {
            if let content = window.contentView, content !== view,
               pressObject(identifier, content) {
                return true
            }
        }
        return pressRegistered(identifier)
    }

    private func pressRegistered(_ identifier: String) -> Bool {
        guard let action = actions[identifier] else { return false }
        action()
        return true
    }

    private func pressObject(_ identifier: String, _ object: NSObject) -> Bool {
        if elementID(object) == identifier {
            if performPress(object) { return true }
            if let button = object as? NSButton {
                button.performClick(nil)
                return true
            }
        }
        for child in children(of: object) {
            if pressObject(identifier, child) { return true }
        }
        return false
    }

    private func elementID(_ object: NSObject) -> String? {
        if let view = object as? NSView {
            let identifier = view.accessibilityIdentifier()
            if !identifier.isEmpty { return identifier }
            return view.identifier?.rawValue
        }
        if let element = object as? NSAccessibilityElement,
           let identifier = element.accessibilityIdentifier(),
           !identifier.isEmpty {
            return identifier
        }
        return object.value(forKey: "accessibilityIdentifier") as? String
    }

    private func performPress(_ object: NSObject) -> Bool {
        if let view = object as? NSView {
            return view.accessibilityPerformPress()
        }
        if let element = object as? NSAccessibilityElement {
            return element.accessibilityPerformPress()
        }
        return false
    }

    private func children(of object: NSObject) -> [NSObject] {
        if let view = object as? NSView, let children = view.accessibilityChildren() as? [NSObject] {
            return children
        }
        if let element = object as? NSAccessibilityElement,
           let children = element.accessibilityChildren() as? [NSObject] {
            return children
        }
        return []
    }
}
