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
    /// Primary dock window (also tracked in `dockWindows[0]`). Kept as a
    /// backwards-compatible alias for code paths that need "any" dock — e.g.
    /// the menu-bar "Show Dock" command.
    var dockWindow: DockWindowController? { dockWindows.first }
    var dockWindows: [DockWindowController] = []
    private var screenObserver: NSObjectProtocol?
    var statusItem: NSStatusItem?
    private var prefsObserver: NSObjectProtocol?
    private var profilesObserver: NSObjectProtocol?
    private var editModeOverlayWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { _ in Self.makeSettingsWindowResizable() }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { _ in Self.makeSettingsWindowResizable() }

        // Show dock window(s) for the active profile's screen assignment.
        rebuildDockWindows()
        // Rebuild when the user switches profile (changes screen assignment) or
        // when displays are added/removed/reconfigured.
        NotificationCenter.default.addObserver(
            forName: ProfileManager.activeChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildDockWindows() }
        NotificationCenter.default.addObserver(
            forName: ProfileManager.listChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildDockWindows() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildDockWindows() }

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
            self?.updateEditModeOverlay()
        }

        profilesObserver = NotificationCenter.default.addObserver(
            forName: ProfileManager.listChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildStatusItemMenu()
        }
        NotificationCenter.default.addObserver(
            forName: ProfileManager.activeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildStatusItemMenu()
        }
        NotificationCenter.default.addObserver(
            forName: ProfileManager.editingDockChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildStatusItemMenu()
        }

        // First-launch onboarding: auto-open Settings + force dock visible (so user sees
        // the replacement dock next to settings on day one). Guarded so this only happens
        // for real first launches by end-users.
        // - If running from DerivedData (all dev builds/relaunches): never auto-open.
        // - Else if our "didFirstLaunch" sentinel not set: open Settings, set sentinel.
        // Uses Apple-native UserDefaults + Bundle path check. Survives rebuilds, clean DerivedData,
        // and ensures zero Settings popups during iteration while preserving real-user UX.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if !Self.isDeveloperBuild(),
               !UserDefaults.standard.bool(forKey: "FocusDock.didCompleteFirstLaunch") {
                UserDefaults.standard.set(true, forKey: "FocusDock.didCompleteFirstLaunch")
                self.openSettings()
                for dw in self.dockWindows {
                    dw.prefs.autoHideDock = false
                    dw.forceReveal()
                }
            }
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
                    button.target = self
                    button.action = #selector(statusItemClicked(_:))
                    // We handle left vs right click manually for reliable behavior
                    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                }

                statusItem = item
            }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Focus: Dock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        return menu
    }

    private func rebuildStatusItemMenu() {
        // We no longer use item.menu for the primary behavior.
        // Click handling is done manually in statusItemClicked.
    }

    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            openSettings()
            return
        }

        // Right-click or Control-click → show Quit menu
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            if let statusItem = statusItem {
                statusItem.popUpMenu(buildMinimalQuitMenu())
            }
        } else {
            // Normal left-click → open Settings directly
            openSettings()
        }
    }

    private func buildMinimalQuitMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit Focus: Dock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc func selectEditingDock(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let uuid = UUID(uuidString: s) else { return }
        ProfileManager.shared.setEditingDock(uuid)
    }



    @objc func addDockToActive() {
        let mgr = ProfileManager.shared
        guard let name = promptForString(title: "Add Dock", message: "Name for the new dock:", defaultValue: "New Dock") else { return }
        _ = mgr.addDock(name: name, in: mgr.activeProfileID)

        // Make the new floating dock immediately draggable so the user can
        // snap it to an edge right away (matches the "center floating with prompt" UX).
        if !Preferences.shared.isEditingLayout {
            Preferences.shared.isEditingLayout = true
        }
    }



    @objc func selectProfile(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let uuid = UUID(uuidString: s) else { return }
        ProfileManager.shared.setActiveProfile(uuid)
    }

    @objc func newProfile() {
        guard let name = promptForString(title: "New Profile", message: "Name for the new profile:", defaultValue: "New Profile") else { return }
        ProfileManager.shared.addProfile(name: name)
    }

    @objc func duplicateProfile() {
        let current = ProfileManager.shared.activeProfile
        guard let name = promptForString(title: "Duplicate Profile", message: "Name for the copy of \(current.name):", defaultValue: current.name + " Copy") else { return }
        ProfileManager.shared.addProfile(name: name, duplicateFrom: current.id)
    }

    @objc func renameProfile() {
        let current = ProfileManager.shared.activeProfile
        guard let name = promptForString(title: "Rename Profile", message: "New name:", defaultValue: current.name) else { return }
        ProfileManager.shared.renameProfile(current.id, to: name)
    }

    @objc func deleteProfile() {
        let mgr = ProfileManager.shared
        guard mgr.profiles.count > 1 else { return }
        let current = mgr.activeProfile
        let alert = NSAlert()
        alert.messageText = "Delete profile \"\(current.name)\"?"
        alert.informativeText = "This removes its pinned apps and dock settings. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            mgr.deleteProfile(current.id)
        }
    }

    private func promptForString(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        tf.stringValue = defaultValue
        alert.accessoryView = tf
        // Focus the text field on present.
        DispatchQueue.main.async { alert.window.makeFirstResponder(tf) }
        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return nil }
        let v = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
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
        for dock in dockWindows {
            dock.showWindow(nil)
            dock.forceReveal()
        }
    }

    /// Tear down and recreate the dock windows based on the active profile's
    /// `ScreenAssignment` and the currently-connected `NSScreen.screens`. Called
    /// at launch, on profile switch / list change, and when displays are
    /// reconfigured.
    func rebuildDockWindows() {
        // Close existing.
        for dock in dockWindows { dock.close() }
        dockWindows.removeAll()

        let mgr = ProfileManager.shared
        let activeDocks = mgr.activeDocks
        guard !activeDocks.isEmpty else {
            // No docks at all — bootstrap one on the main screen.
            if let main = NSScreen.main {
                let fallbackID = mgr.docks.first?.id ?? UUID()
                let ctrl = DockWindowController(dockID: fallbackID, targetScreen: main)
                ctrl.showWindow(nil)
                dockWindows.append(ctrl)
            }
            return
        }
        for dock in activeDocks {
            let screens = targetScreens(for: dock.screen)
            if screens.isEmpty {
                // Pinned screen disconnected — fall back to main so the user
                // doesn't end up with this dock invisible.
                if let main = NSScreen.main {
                    let ctrl = DockWindowController(dockID: dock.id, targetScreen: main)
                    ctrl.showWindow(nil)
                    dockWindows.append(ctrl)
                }
                continue
            }
            for screen in screens {
                let ctrl = DockWindowController(dockID: dock.id, targetScreen: screen)
                ctrl.showWindow(nil)
                dockWindows.append(ctrl)
            }
        }
    }

    private func targetScreens(for assignment: ScreenAssignment) -> [NSScreen] {
        switch assignment {
        case .allScreens: return NSScreen.screens
        case .main: return NSScreen.main.map { [$0] } ?? []
        case .specific(let uuid, _):
            if let s = ScreenIdentity.screen(forUUID: uuid) { return [s] }
            return []
        }
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

    /// Returns true when this binary lives inside an Xcode DerivedData tree.
    /// All developer builds (xcodebuild, Xcode Run, clean builds) use this path.
    /// Production installs (DMG, /Applications, App Store) never contain "DerivedData".
    /// Used to suppress first-launch Settings popup (and similar dev friction) while
    /// preserving the intended UX for real users on their first run.
    private static func isDeveloperBuild() -> Bool {
        Bundle.main.bundlePath.contains("DerivedData")
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

    // MARK: - Edit Layout global overlay

    private func updateEditModeOverlay() {
        let isEditing = Preferences.shared.isEditingLayout

        if isEditing {
            showEditModeOverlay()
        } else {
            hideEditModeOverlay()
        }
    }

    private func showEditModeOverlay() {
        if editModeOverlayWindow != nil { return }

        guard let screen = NSScreen.main else { return }

        let overlay = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlay.backgroundColor = NSColor.black.withAlphaComponent(0.18)
        overlay.isOpaque = false
        overlay.hasShadow = false
        overlay.level = .floating
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        overlay.setFrame(screen.frame, display: true)
        overlay.orderFrontRegardless()

        editModeOverlayWindow = overlay
    }

    private func hideEditModeOverlay() {
        editModeOverlayWindow?.orderOut(nil)
        editModeOverlayWindow = nil
    }
}
