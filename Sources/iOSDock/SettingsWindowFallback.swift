import SwiftUI
import AppKit

/// Fallback that hosts SettingsView in a plain NSWindow if the SwiftUI Settings
/// scene can't be triggered via the standard selectors.
enum SettingsWindowFallback {
    private static var controller: NSWindowController?

    static func show() {
        if let c = controller {
            c.showWindow(nil)
            c.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = SettingsView()
            .environmentObject(AppLibrary.shared)
            .environmentObject(Preferences.shared)
        let host = NSHostingController(rootView: root)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Focus: Dock Settings"
        win.contentViewController = host
        win.center()
        let c = NSWindowController(window: win)
        controller = c
        c.showWindow(nil)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
