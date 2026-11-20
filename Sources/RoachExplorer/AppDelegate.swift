import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var windowControllers: [WindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        NSApp.activate(ignoringOtherApps: true)

        let startPath = ProcessInfo.processInfo.environment["ROACH_START_PATH"].map { URL(fileURLWithPath: $0) }
        openWindow(startingAt: startPath)
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(startingAt: nil)
    }

    func openWindow(startingAt url: URL?) {
        let controller = WindowController(startingURL: url)
        windowControllers.append(controller)
        controller.showWindow(nil)
    }

    /// Closing the last window quits the app. Confirmed in the plan.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func installMenus() {
        let mainMenu = NSMenu()

        // App menu.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Roach Explorer", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        let servicesMenu = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Roach Explorer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Roach Explorer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu. Standard text actions, routed through the responder chain.
        // Undo and Redo are intentionally absent: Cmd+Z belongs to the later in-app undo, and until then it does nothing.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Go menu. Cmd+L focuses the path field that is already on screen.
        let goItem = NSMenuItem()
        mainMenu.addItem(goItem)
        let goMenu = NSMenu(title: "Go")
        goItem.submenu = goMenu
        goMenu.addItem(withTitle: "Path", action: #selector(WindowController.focusPath(_:)), keyEquivalent: "l")

        // Window menu.
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        // Help menu.
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }
}
