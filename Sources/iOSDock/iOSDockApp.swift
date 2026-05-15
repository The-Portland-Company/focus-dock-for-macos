import SwiftUI
import AppKit

@main
struct FocusDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var library = AppLibrary.shared
    @StateObject private var prefs = Preferences.shared

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(library)
                .environmentObject(prefs)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var dockWindow: DockWindowController?
    var statusItem: NSStatusItem?
    private var prefsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { _ in Self.makeSettingsWindowResizable() }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { _ in Self.makeSettingsWindowResizable() }

        // Show dock window
        dockWindow = DockWindowController()
        dockWindow?.showWindow(nil)

        applyPresentationMode()
        installStatusItemIfNeeded()
        installDockIcon()

        // If a previous run was force-quit while the Dock was hidden, restore
        // originals first so we don't lose them when we re-hide below.
        SystemDockManager.selfHealIfStaleHide()

        // Install crash/force-quit backstop BEFORE hiding the Dock so abnormal
        // exits (SIGTERM, SIGINT, atexit) still restore the system Dock.
        QuitBackstop.install()

        // Offer to hide system Dock (so this dock can take over).
        SystemDockManager.hideSystemDock()

        // Start polling the system Dock's AX tree for numeric badges and
        // attention requests. Prompts once for Accessibility permission;
        // silently no-ops until granted.
        BadgeMonitor.shared.start()

        // Surface minimized windows of other apps in the protected right-hand
        // section of the dock (mirrors native macOS Dock).
        MinimizedMonitor.shared.start()

        // Surface running-but-not-pinned apps in the dock so it has parity
        // with the native macOS Dock (which always shows every running app).
        RunningAppsMonitor.shared.start()

        // Watch ~/.Trash so the dock's Trash icon swaps between empty/full
        // bitmaps as items move in or out.
        TrashWatcher.shared.start()

        // Deep-link from folder popover → open Settings.
        NotificationCenter.default.addObserver(
            forName: SettingsRouter.openFolder, object: nil, queue: .main
        ) { [weak self] _ in self?.openSettings() }

        prefsObserver = NotificationCenter.default.addObserver(
            forName: Preferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyPresentationMode()
            self?.installStatusItemIfNeeded()
        }

        // Open Settings window on first launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.openSettings()
        }
    }

    private func installDockIcon() {
        let size = NSSize(width: 512, height: 512)
        let img = NSImage(size: size)
        img.lockFocus()
        // Rounded-rect tile background (iOS-style)
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 24, dy: 24)
        let path = NSBezierPath(roundedRect: rect, xRadius: 110, yRadius: 110)
        let grad = NSGradient(colors: [
            NSColor(calibratedRed: 0.30, green: 0.55, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.95, alpha: 1)
        ])
        grad?.draw(in: path, angle: 270)

        // 3x3 mini-grid of white rounded squares
        let cellArea = rect.insetBy(dx: 80, dy: 80)
        let cellSize: CGFloat = (cellArea.width - 24) / 3
        for row in 0..<3 {
            for col in 0..<3 {
                let x = cellArea.minX + CGFloat(col) * (cellSize + 12)
                let y = cellArea.minY + CGFloat(2 - row) * (cellSize + 12)
                let cell = NSRect(x: x, y: y, width: cellSize, height: cellSize)
                let cellPath = NSBezierPath(roundedRect: cell, xRadius: 18, yRadius: 18)
                NSColor.white.withAlphaComponent(0.92).setFill()
                cellPath.fill()
            }
        }
        img.unlockFocus()
        NSApp.applicationIconImage = img
    }

    func applyPresentationMode() {
        // Always show the Focus: Dock icon in the system Dock area while
        // running; the system Dock is hidden anyway when the app takes over.
        NSApp.setActivationPolicy(.regular)
    }

    func installStatusItemIfNeeded() {
        if Preferences.shared.showMenuBarIcon {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let button = item.button {
                    button.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Focus: Dock")
                }
                let menu = NSMenu()
                menu.addItem(withTitle: "Show Dock", action: #selector(showDock), keyEquivalent: "d").target = self
                let editItem = NSMenuItem(title: "Edit Layout (drag dock to an edge)", action: #selector(toggleEditLayout), keyEquivalent: "e")
                editItem.target = self
                editItem.state = Preferences.shared.isEditingLayout ? .on : .off
                menu.addItem(editItem)
                menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
                menu.addItem(.separator())
                menu.addItem(withTitle: "Quit Focus: Dock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
                item.menu = menu
                statusItem = item
            }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc func toggleEditLayout() {
        let new = !Preferences.shared.isEditingLayout
        Preferences.shared.isEditingLayout = new
        // Refresh status menu item state
        installStatusItemIfNeeded()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            installStatusItemIfNeeded()
        }
        // User feedback
        if new {
            let notice = NSAlert()
            notice.messageText = "Edit Layout enabled"
            notice.informativeText = "Drag the dock toward any screen edge — it will snap to the nearest one. Toggle this off from the menu bar (or press it again) when you're done."
            notice.runModal()
        }
    }

    @objc func showDock() {
        dockWindow?.showWindow(nil)
        dockWindow?.window?.orderFrontRegardless()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Restore synchronously on the normal quit path so the Dock comes back
        // before the run loop exits. (applicationWillTerminate is sometimes too late.)
        if SystemDockManager.isHidden {
            SystemDockManager.restoreSystemDock()
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Belt-and-suspenders: if applicationShouldTerminate didn't run (e.g.
        // logout-driven terminate), restore here too. restoreSystemDock is
        // idempotent — calling twice is harmless.
        if SystemDockManager.isHidden {
            SystemDockManager.restoreSystemDock()
        }
    }

    private func promptHideSystemDockIfNeeded() {
        let askedKey = "didPromptHideDock"
        if UserDefaults.standard.bool(forKey: askedKey) { return }
        UserDefaults.standard.set(true, forKey: askedKey)

        let alert = NSAlert()
        alert.messageText = "Take over the macOS Dock?"
        alert.informativeText = """
        Focus: Dock works as a replacement dock that supports iOS-style folder creation.

        It will hide the system Dock while running and automatically restore it when you Quit or uninstall the app.

        Hide the system Dock now?
        """
        alert.addButton(withTitle: "Hide System Dock")
        alert.addButton(withTitle: "Not now")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            SystemDockManager.hideSystemDock()
        }
    }

    @objc func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // Try every known selector across macOS versions.
        let selectors = ["showSettingsWindow:", "showPreferencesWindow:"]
        for name in selectors {
            let sel = Selector(name)
            if NSApp.responds(to: sel) {
                NSApp.sendAction(sel, to: nil, from: nil)
                DispatchQueue.main.async { Self.makeSettingsWindowResizable() }
                return
            }
        }
        // Fallback: simulate Cmd+, against the main menu.
        if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: {
            $0.title.localizedCaseInsensitiveContains("settings") ||
            $0.title.localizedCaseInsensitiveContains("preferences")
        }) {
            NSApp.sendAction(item.action!, to: item.target, from: nil)
            DispatchQueue.main.async { Self.makeSettingsWindowResizable() }
            return
        }
        // Last resort: open the Settings scene by creating it explicitly.
        SettingsWindowFallback.show()
    }

    static func makeSettingsWindowResizable() {
        let apply = {
            for win in NSApp.windows {
                let title = win.title.lowercased()
                let id = win.identifier?.rawValue.lowercased() ?? ""
                let isSettings = title.contains("settings") || title.contains("preferences")
                    || title == "general" || id.contains("settings") || id.contains("com_apple_swiftui")
                if isSettings {
                    win.styleMask.insert(.resizable)
                    win.minSize = NSSize(width: 480, height: 420)
                    win.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                         height: CGFloat.greatestFiniteMagnitude)
                    let autosaveName = "FocusDockSettingsWindow.v2"
                    let defaultsKey = "NSWindow Frame \(autosaveName)"
                    let hasSavedFrame = UserDefaults.standard.string(forKey: defaultsKey) != nil
                    if win.frameAutosaveName != autosaveName {
                        win.setFrameAutosaveName(autosaveName)
                    }
                    if hasSavedFrame {
                        win.setFrameUsingName(autosaveName)
                    } else {
                        let target = NSSize(width: 520, height: 900)
                        var frame = win.frame
                        let screen = win.screen ?? NSScreen.main
                        let visible = screen?.visibleFrame ?? frame
                        let h = min(target.height, visible.height - 20)
                        let w = min(target.width, visible.width - 20)
                        let topY = frame.maxY
                        frame.size = NSSize(width: w, height: h)
                        frame.origin.y = topY - h
                        win.setFrame(frame, display: true, animate: false)
                        win.saveFrame(usingName: autosaveName)
                    }
                }
            }
        }
        DispatchQueue.main.async(execute: apply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: apply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: apply)
    }
}
