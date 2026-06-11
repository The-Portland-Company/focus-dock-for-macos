import Foundation
import AppKit
import CoreGraphics
import os

// Compiled out of the App Store build: an HID-level CGEventTap that swallows
// system keys is part of the private desktop-strip feature (DMG/dev only) and
// would never pass MAS review. Callers go through the ungated
// DesktopStripFeature facade.
#if !APPSTORE

/// Suppresses the system Mission Control triggers (F3, Ctrl+Up) and opens OUR
/// desktop strip instead, by installing a HID-level `CGEventTap`.
///
/// DISABLED-SAFE design (the app is the user's LIVE dock):
/// - The tap is only installed when the feature is enabled, intercept is on,
///   AND Accessibility is trusted. Without AX the tap is never installed, so
///   system Mission Control keeps working — we never strand the user.
/// - The callback ONLY swallows F3 / Ctrl+Up; every other event passes through
///   untouched (returned as-is).
/// - On `.tapDisabledByTimeout` / `.tapDisabledByUserInput` the tap is
///   re-enabled immediately so a slow callback can never permanently disable
///   the user's Mission Control keys.
/// - `stop()` removes the tap synchronously, instantly restoring the system
///   behavior (the feature/intercept toggle and quit both call it).
enum MissionControlInterceptor {
    private static let log = Logger(subsystem: "com.theportlandcompany.FocusDock", category: "Spaces")

    /// F3 (Mission Control) and Up-arrow virtual key codes.
    private static let keyF3: Int64 = 160
    private static let keyUpArrow: Int64 = 126

    private static var eventTap: CFMachPort?
    private static var runLoopSource: CFRunLoopSource?

    static var isRunning: Bool { eventTap != nil }

    /// Installs the tap if (and only if) all preconditions hold. Idempotent —
    /// a second call while running is a no-op. Returns true when the tap is
    /// active afterwards.
    @discardableResult
    static func start() -> Bool {
        guard eventTap == nil else { return true }
        guard Preferences.shared.desktopStripEnabled,
              Preferences.shared.desktopStripInterceptMissionControl,
              AXIsProcessTrusted() else {
            return false
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // listen + alter/swallow
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                MissionControlInterceptor.handle(type: type, event: event)
            },
            userInfo: nil
        ) else {
            log.error("MissionControlInterceptor: CGEvent.tapCreate FAILED — system Mission Control left intact")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        log.info("MissionControlInterceptor: tap installed (F3 + Ctrl+Up → desktop strip)")
        return true
    }

    /// Removes the tap synchronously — system Mission Control works again the
    /// instant this returns. Idempotent.
    static func stop() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        eventTap = nil
        runLoopSource = nil
        log.info("MissionControlInterceptor: tap removed — system Mission Control restored")
    }

    // MARK: - Tap callback

    private static func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The kernel disables a tap that is too slow or that the user input
        // interrupts. Re-enable immediately so the user's MC keys can never be
        // left permanently swallowed by us.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                log.warning("MissionControlInterceptor: tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user-input") disable")
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Fast path — two cheap comparisons:
        //   F3 alone, or Ctrl+Up (control held). Anything else passes through.
        let isF3 = keyCode == keyF3
        let isCtrlUp = keyCode == keyUpArrow && flags.contains(.maskControl)
        guard isF3 || isCtrlUp else { return Unmanaged.passUnretained(event) }

        // Open OUR strip on the main thread; swallow the system event so
        // Mission Control never fires.
        DispatchQueue.main.async {
            DesktopStripFeature.toggleStrip()
        }
        return nil
    }
}

#endif
