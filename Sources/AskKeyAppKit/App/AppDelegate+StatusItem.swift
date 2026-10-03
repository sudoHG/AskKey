import AppKit

extension AppDelegate {
    // MenuBarExtra has no public right-click API, so intercept right-clicks on the
    // status bar item's window and show a Quit menu there.
    func setupStatusItemMenu() {
        statusItemMenuMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            guard let window = event.window,
                  NSStringFromClass(type(of: window)).contains("NSStatusBarWindow"),
                  let contentView = window.contentView else { return event }

            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: appLocalized("Quit Ask Key"),
                                    action: #selector(NSApplication.terminate(_:)),
                                    keyEquivalent: "q"))
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
            return nil
        }
    }

    func setupHotkey() {
        hotkeyManager.onActivate = { [weak self] in
            self?.togglePopover()
        }
        let shortcut = GlobalHotkeyManager.Shortcut.fromID(AppPreferences().hotkeyShortcutID)
        hotkeyManager.register(shortcut)
    }

    // MenuBarExtra exposes no API to open its popover programmatically, so locate
    // the status item's button and synthesize a click — the same toggle a real
    // click performs (opening it, or closing it if already open).
    private func togglePopover() {
        guard let button = statusItemButton() else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        button.performClick(nil)
    }

    private func statusItemButton() -> NSStatusBarButton? {
        for window in NSApp.windows
        where NSStringFromClass(type(of: window)).contains("NSStatusBarWindow") {
            if let button = window.contentView?.firstDescendant(ofType: NSStatusBarButton.self) {
                return button
            }
        }
        return nil
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let found = subview.firstDescendant(ofType: type) { return found }
        }
        return nil
    }
}
