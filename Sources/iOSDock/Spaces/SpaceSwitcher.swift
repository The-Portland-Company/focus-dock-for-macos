import Foundation
import AppKit
import CoreGraphics
import os

// Compiled out of the App Store build: synthesizing keyboard events for
// desktop switching is part of the private desktop-strip feature (DMG/dev
// only). Callers go through the ungated DesktopStripFeature facade.
#if !APPSTORE

/// Switches macOS to a target Space:
/// - Fast path: synthesize Ctrl+N (the "Switch to Desktop N" symbolic
///   hotkeys that SymbolicHotKeysManager temporarily enabled), verified
///   against SpacesBridge within 700 ms — gives the native slide animation.
///   First verified switch doubles as the functional probe; failure marks
///   the hotkeys unreliable (persisted).
/// - Fallback (fullscreen spaces, hotkey management off/unreliable):
///   CGSManagedDisplaySetCurrentSpace — instant, no animation. The plan
///   called for a Ctrl+←/→ arrow-walk here, but macOS 26's Dock silently
///   ignores synthetic Ctrl+arrow events from this process (verified
///   empirically against hotkeys 79/81 with every event recipe, while the
///   same events fired the digit hotkeys fine), so the walk cannot be made
///   reliable; the SPI switch is in the same SkyLight family the bridge
///   already uses and is verified the same way.
///
/// Key events require Accessibility trust (`canSwitch`); the strip shows
/// tiles dimmed when it's missing.
enum SpaceSwitcher {
    private static let log = Logger(subsystem: "com.theportlandcompany.FocusDock", category: "Spaces")

    /// Serial background queue: verification polls sleep, so never block main.
    private static let queue = DispatchQueue(label: "com.theportlandcompany.FocusDock.SpaceSwitcher", qos: .userInteractive)
    /// Re-entrancy guard — ignore clicks while a switch is still in flight.
    private static var switchInProgress = false

    /// Posting keyboard events needs Accessibility trust (already required by
    /// the app's minimize/badge features).
    static var canSwitch: Bool { AXIsProcessTrusted() }

    // MARK: - Entry point

    /// Switches to `space` (which lives on `display`). Asynchronous; calls
    /// `completion(success)` on the main queue. On failure the caller gets
    /// audible feedback (beep) before completion runs.
    static func switchTo(space: SpaceInfo, on display: DisplaySpaces, completion: ((Bool) -> Void)? = nil) {
        guard canSwitch else {
            log.warning("switchTo ignored: Accessibility not granted")
            DispatchQueue.main.async { completion?(false) }
            return
        }
        guard space.uuid != display.currentSpaceUUID else {
            DispatchQueue.main.async { completion?(true) }
            return
        }
        guard !switchInProgress else {
            log.info("switchTo ignored: another switch is in flight")
            DispatchQueue.main.async { completion?(false) }
            return
        }
        switchInProgress = true

        // Resolve the Ctrl+N desktop number on the MAIN thread (model data),
        // then do the post+verify work on the background queue.
        let desktopNumber = globalDesktopNumber(for: space.uuid)
        let useHotkey = space.isUserDesktop
            && Preferences.shared.desktopStripManageHotkeys
            && !SymbolicHotKeysManager.isUnreliable
            && desktopNumber != nil
            && desktopNumber! <= SymbolicHotKeysManager.managedCount

        queue.async {
            var success = false
            if useHotkey, let n = desktopNumber {
                success = switchViaHotkey(desktopNumber: n, targetUUID: space.uuid, displayIdentifier: display.displayIdentifier)
                if !success {
                    // Functional probe failed → never trust Ctrl+N again this
                    // configuration; switch directly instead, this very gesture.
                    SymbolicHotKeysManager.markUnreliable()
                    success = directSwitch(to: space, displayIdentifier: display.displayIdentifier)
                }
            } else {
                success = directSwitch(to: space, displayIdentifier: display.displayIdentifier)
            }
            DispatchQueue.main.async {
                switchInProgress = false
                if !success {
                    // M3 failure feedback: audible beep + log (the strip is
                    // already hidden when switching starts, so a tile shake
                    // would be invisible anyway).
                    NSSound.beep()
                    log.error("switchTo(\(space.uuid, privacy: .public)) FAILED")
                }
                completion?(success)
            }
        }
    }

    // MARK: - Ctrl+N fast path

    /// Posts Ctrl+N and polls SpacesBridge (every ~100 ms, up to 700 ms) until
    /// the display's current space uuid equals the target. This IS the
    /// functional probe for the symbolic-hotkey write: verified success marks
    /// the mechanism reliable.
    private static func switchViaHotkey(desktopNumber n: Int, targetUUID: String, displayIdentifier: String) -> Bool {
        guard (1...9).contains(n) else { return false }
        let keyCode = CGKeyCode(SymbolicHotKeysManager.digitKeyCodes[n - 1])
        postKey(keyCode, flags: .maskControl)
        if verifyCurrentSpace(equals: targetUUID, onDisplay: displayIdentifier, timeout: 0.7) {
            SymbolicHotKeysManager.markReliable()
            log.info("switch: Ctrl+\(n) verified → \(targetUUID, privacy: .public)")
            return true
        }
        log.error("switch: Ctrl+\(n) posted but space did not change within 700 ms (functional probe FAILED)")
        return false
    }

    // MARK: - Direct-switch fallback (SkyLight)

    /// Switches via CGSManagedDisplaySetCurrentSpace and verifies the result
    /// the same way as the hotkey path. Instant (no slide animation). Used
    /// for fullscreen-app spaces, when hotkey management is off, and when
    /// the Ctrl+N probe failed.
    private static func directSwitch(to space: SpaceInfo, displayIdentifier: String) -> Bool {
        SpacesBridge.setCurrentSpace(displayIdentifier: displayIdentifier, spaceID: space.id64)
        if verifyCurrentSpace(equals: space.uuid, onDisplay: displayIdentifier, timeout: 0.7) {
            log.info("switch: direct SPI verified → \(space.uuid, privacy: .public)")
            return true
        }
        log.error("switch: CGSManagedDisplaySetCurrentSpace did not take within 700 ms")
        return false
    }

    // MARK: - Event posting + verification

    /// Posts a keydown/keyup pair at the HID level with the given modifier
    /// FLAGS set directly on the events (no separate modifier press).
    ///
    /// Recipe note (macOS 26, verified empirically): the SkyLight-registered
    /// Ctrl+digit hotkeys (118+) fire reliably for these flag-only events.
    /// The Ctrl+arrow hotkeys (79/81) are the opposite — they ignore
    /// flag-only events AND (almost always) real bracketed modifier presses
    /// from this process, which is why the fallback path uses
    /// CGSManagedDisplaySetCurrentSpace instead of an arrow-walk.
    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            log.error("postKey: CGEvent creation failed for keyCode \(keyCode)")
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        // Small gap so the down/up don't coalesce.
        usleep(20_000)
        up.post(tap: .cghidEventTap)
    }

    private static func verifyCurrentSpace(equals targetUUID: String, onDisplay displayIdentifier: String, timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) { fetchDisplay(displayIdentifier)?.currentSpaceUUID == targetUUID }
    }

    /// Polls `condition` every ~100 ms until true or `timeout` elapses.
    /// Runs on the background queue — sleeping is fine.
    private static func poll(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            usleep(100_000)
            if condition() { return true }
        }
        return condition()
    }

    private static func fetchDisplay(_ identifier: String) -> DisplaySpaces? {
        SpacesBridge.fetchDisplaySpaces().first { $0.displayIdentifier == identifier }
    }

    #if DEBUG
    /// Debug-only: move one space right via the SPI fallback path with no
    /// strip/verify involvement — used by milestone verification scripts.
    static func debugWalkRight() {
        queue.async {
            guard let display = SpacesBridge.fetchDisplaySpaces().first,
                  let current = display.currentSpaceUUID,
                  let idx = display.spaces.firstIndex(where: { $0.uuid == current }),
                  idx + 1 < display.spaces.count else {
                log.info("debugWalkRight: no space to the right")
                return
            }
            let next = display.spaces[idx + 1]
            log.info("debugWalkRight: CGSManagedDisplaySetCurrentSpace → \(next.uuid, privacy: .public)")
            SpacesBridge.setCurrentSpace(displayIdentifier: display.displayIdentifier, spaceID: next.id64)
        }
    }
    #endif

    /// Global Mission-Control desktop number for the Ctrl+N hotkey: type-0
    /// spaces counted in display order across all displays (fresh fetch, not
    /// the possibly-stale model).
    private static func globalDesktopNumber(for uuid: String) -> Int? {
        var number = 0
        for display in SpacesBridge.fetchDisplaySpaces() {
            for space in display.spaces where space.isUserDesktop {
                number += 1
                if space.uuid == uuid { return number }
            }
        }
        return nil
    }
}

#endif
