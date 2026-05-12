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
        // Show dock window
        dockWindow = DockWindowController()
        dockWindow?.showWindow(nil)

        applyPresentationMode()
        installStatusItemIfNeeded()
        installDockIcon()

        // Offer to hide system Dock (so this dock can take over).
        promptHideSystemDockIfNeeded()

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
        let showDockIcon = Preferences.shared.showDockIcon
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
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

    func applicationWillTerminate(_ notification: Notification) {
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
                return
            }
        }
        // Fallback: simulate Cmd+, against the main menu.
        if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: {
            $0.title.localizedCaseInsensitiveContains("settings") ||
            $0.title.localizedCaseInsensitiveContains("preferences")
        }) {
            NSApp.sendAction(item.action!, to: item.target, from: nil)
            return
        }
        // Last resort: open the Settings scene by creating it explicitly.
        SettingsWindowFallback.show()
    }
}
