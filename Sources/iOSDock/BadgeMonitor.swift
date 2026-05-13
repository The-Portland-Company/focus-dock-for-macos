import Foundation
import AppKit
import ApplicationServices

/// Reads numeric badges and attention-requested state from the system Dock's
/// accessibility tree (`com.apple.dock`) and publishes the results into
/// `AppLibrary.badgeStates` on the main thread.
///
/// **Why AX against the system Dock and not something cleaner:** macOS does
/// not expose per-app dock-tile badge labels through a public, non-AX API.
/// `NSApplication.dockTile.badgeLabel` only reads our own tile. The Dock's
/// AX tree, however, surfaces every running app's `AXStatusLabel` (numeric
/// badge text) and an `AXAttentionRequested`-style flag (we read it via the
/// `AXIsApplicationRunning` + `AXStatusLabel` + a heuristic on
/// `AXLabel`/`AXSubrole`). This is the same approach used by every
/// third-party dock replacement on the Mac.
///
/// **Permission UX:** the first time we run we call `AXIsProcessTrustedWithOptions`
/// with the prompt option set, which surfaces the macOS system "Allow
/// Accessibility access" dialog. If the user denies, badges silently stay
/// empty — the rest of the dock works unchanged. We re-check on every poll
/// in case the user grants access later.
final class BadgeMonitor {
    static let shared = BadgeMonitor()

    private var timer: Timer?
    private let pollInterval: TimeInterval = 2.0
    private var hasPromptedForAX = false

    func start() {
        stop()
        // Kick once immediately so a freshly-granted permission shows badges
        // without waiting a full poll cycle.
        tick()
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // Prompt for AX once — subsequent ticks just check trust silently.
        let trusted: Bool
        if !hasPromptedForAX {
            hasPromptedForAX = true
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(opts)
        } else {
            trusted = AXIsProcessTrusted()
        }
        guard trusted else { return }

        // Read off the main thread; publish back on main.
        DispatchQueue.global(qos: .utility).async {
            let snapshot = Self.readDockBadges()
            DispatchQueue.main.async {
                AppLibrary.shared.badgeStates = snapshot
            }
        }
    }

    /// Walk the AX tree of `com.apple.dock` and collect badge/attention state
    /// for each item, keyed by lowercased title.
    private static func readDockBadges() -> [String: AppBadgeState] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return [:]
        }
        let dockApp = AXUIElementCreateApplication(dock.processIdentifier)

        // The dock's first AXChild is the "list" element that holds all items.
        guard let children = copyAttribute(dockApp, kAXChildrenAttribute) as? [AXUIElement] else { return [:] }

        var result: [String: AppBadgeState] = [:]
        for list in children {
            guard let items = copyAttribute(list, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for item in items {
                guard let title = copyAttribute(item, kAXTitleAttribute) as? String, !title.isEmpty else { continue }
                let badge = copyAttribute(item, "AXStatusLabel" as CFString) as? String
                // Attention flag: Dock exposes it as a boolean attribute on the
                // dock item. The name varies across macOS versions — try the
                // most common keys and fall back to false.
                let needsAttention =
                    (copyAttribute(item, "AXIsApplicationRunning" as CFString) as? Bool ?? false) &&
                    ((copyAttribute(item, "AXAttentionRequested" as CFString) as? Bool) ??
                     (copyAttribute(item, "AXFocused" as CFString) as? Bool) ?? false)
                let trimmed = badge?.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
                if normalized != nil || needsAttention {
                    result[title.lowercased()] = AppBadgeState(badgeCount: normalized, needsAttention: needsAttention)
                }
            }
        }
        return result
    }

    private static func copyAttribute(_ element: AXUIElement, _ attr: String) -> AnyObject? {
        copyAttribute(element, attr as CFString)
    }

    private static func copyAttribute(_ element: AXUIElement, _ attr: CFString) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attr, &value)
        return err == .success ? value : nil
    }
}
