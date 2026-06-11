import Foundation
import AppKit
import Combine
import os
#if DEBUG && !APPSTORE
import notify
#endif

/// Ungated facade over the custom desktop-strip feature (Mission-Control
/// replacement). This file compiles in EVERY configuration — callers
/// (iOSDockApp, QuitBackstop, status menu, settings) talk only to this type
/// and never need #if APPSTORE. Under APPSTORE everything is a no-op and
/// `isAvailable` is false.
///
/// M3 scope: the strip switches real Spaces. While the feature is enabled
/// (and `desktopStripManageHotkeys` is on, and Accessibility is granted) the
/// system "Switch to Desktop N" hotkeys are snapshot-then-enabled so
/// SpaceSwitcher can post Ctrl+N; they are restored on quit/disable and
/// self-healed at launch after a crash.
///
/// M4 scope: while the feature is enabled a SpaceThumbnailCache photographs
/// the current desktop (space change / strip open / 60 s timer) so tiles show
/// real screenshots; without Screen Recording permission the cache stays
/// dormant and tiles keep their gradient placeholders. Mission Control
/// interception arrives in M5.
enum DesktopStripFeature {
    private static let log = Logger(subsystem: "com.theportlandcompany.FocusDock", category: "Spaces")

    #if !APPSTORE
    private static var model: SpacesModel?
    private static var logSink: AnyCancellable?
    private static var controller: DesktopStripController?
    private static var thumbnails: SpaceThumbnailCache?
    #endif
    #if DEBUG && !APPSTORE
    private static var debugToggleInstalled = false
    #endif

    /// Whether the desktop strip can work in this build on this system.
    /// False under APPSTORE; false in DMG/dev builds if the private spaces
    /// API stopped returning a parseable layout (feature self-disables).
    static var isAvailable: Bool {
        #if APPSTORE
        return false
        #else
        if let model { return model.isSupported }
        return !SpacesBridge.fetchDisplaySpaces().isEmpty
        #endif
    }

    /// Called once from app startup: starts the spaces model (with the M1
    /// acceptance logging), installs the DEBUG toggle hook, and creates the
    /// strip controller when the preference is on.
    static func startIfEnabled() {
        #if !APPSTORE
        startModelIfNeeded()
        installDebugToggleListenerIfNeeded()
        applySettings()
        #endif
    }

    /// Re-reads preferences and reconfigures the feature. Called from the
    /// Preferences.changed observer, so toggling `desktopStripEnabled`
    /// live-creates/destroys the strip controller without a relaunch.
    static func applySettings() {
        #if !APPSTORE
        startModelIfNeeded()
        defer { reconcileHotkeys() }
        guard Preferences.shared.desktopStripEnabled, isAvailable, let model else {
            controller?.hide()
            controller = nil
            thumbnails?.stop()
            thumbnails = nil
            return
        }
        if thumbnails == nil {
            thumbnails = SpaceThumbnailCache()
        }
        if controller == nil, let thumbnails {
            controller = DesktopStripController(model: model, thumbnails: thumbnails)
        }
        #endif
    }

    /// Restores any system state we changed (the "Switch to Desktop N"
    /// symbolic hotkeys) and dismisses the overlay. Idempotent — safe to call
    /// from both terminate delegate paths AND the QuitBackstop atexit/signal
    /// handlers (UI teardown is skipped off the main thread; the prefs
    /// restore is what matters at process death).
    static func teardownForQuit() {
        #if !APPSTORE
        if Thread.isMainThread {
            controller?.hide()
            controller = nil
            thumbnails?.stop()
            thumbnails = nil
        }
        SymbolicHotKeysManager.restore()
        #endif
    }

    /// Launch-time recovery: if a previous session crashed/was force-quit
    /// while the symbolic hotkeys were managed, restore the user's originals
    /// before this launch (re-)enables them. Mirrors
    /// `SystemDockManager.selfHealIfStaleHide()`.
    static func selfHealIfStale() {
        #if !APPSTORE
        SymbolicHotKeysManager.selfHealIfStale()
        #endif
    }

    /// Shows/hides the desktop strip overlay (status-menu "Show Desktops",
    /// later the intercepted Mission Control keys). Lazily creates the
    /// controller when the feature is enabled + available.
    static func toggleStrip() {
        #if !APPSTORE
        startModelIfNeeded()
        guard Preferences.shared.desktopStripEnabled, isAvailable, let model else {
            log.info("toggleStrip ignored: enabled=\(Preferences.shared.desktopStripEnabled) available=\(isAvailable)")
            return
        }
        if thumbnails == nil {
            thumbnails = SpaceThumbnailCache()
        }
        if controller == nil, let thumbnails {
            controller = DesktopStripController(model: model, thumbnails: thumbnails)
        }
        controller?.toggle()
        if controller?.isVisible == true {
            // M4 trigger (b): refresh the current desktop's thumbnail when
            // the strip opens, so what the user just left is up to date.
            thumbnails?.captureCurrentSpaces(reason: "stripOpen")
        }
        #endif
    }

    /// Switches macOS to the given space. Routed here by tile clicks and the
    /// strip's Return key. Mission Control hides after selection — same here:
    /// hide the strip first, then switch (the panels survive the space change
    /// anyway via .canJoinAllSpaces, but visually MC-dismissal feels right).
    static func requestSwitch(to uuid: String) {
        #if !APPSTORE
        guard SpaceSwitcher.canSwitch else {
            log.warning("requestSwitch(\(uuid, privacy: .public)) ignored: Accessibility not granted")
            return
        }
        // Resolve the target space + owning display from a FRESH fetch (the
        // layout may have changed since the strip was built).
        let displays = SpacesBridge.fetchDisplaySpaces()
        guard let display = displays.first(where: { d in d.spaces.contains { $0.uuid == uuid } }),
              let space = display.spaces.first(where: { $0.uuid == uuid }) else {
            log.error("requestSwitch(\(uuid, privacy: .public)): space not found in current layout")
            return
        }
        controller?.hide()
        SpaceSwitcher.switchTo(space: space, on: display) { success in
            log.info("requestSwitch(\(uuid, privacy: .public)) → \(success ? "switched" : "FAILED", privacy: .public)")
            model?.refresh()
        }
        #endif
    }

    #if !APPSTORE
    /// Brings the managed symbolic-hotkey state in line with the current
    /// preferences + permissions + desktop count:
    /// - feature on + hotkey management on + AX trusted → snapshot once and
    ///   enable Ctrl+1…N for the current desktop count (re-written live when
    ///   desktops are added/removed — the model sink calls this on refresh).
    /// - anything off → restore the user's original hotkey values.
    private static func reconcileHotkeys() {
        let wantManaged = Preferences.shared.desktopStripEnabled
            && Preferences.shared.desktopStripManageHotkeys
            && isAvailable
            && SpaceSwitcher.canSwitch
        let desiredCount = min(9, model?.desktopSpaces.count ?? 0)
        if wantManaged && desiredCount > 0 {
            if SymbolicHotKeysManager.managedCount != desiredCount {
                SymbolicHotKeysManager.enableSwitchHotkeys(count: desiredCount)
            }
        } else if SymbolicHotKeysManager.hasSnapshot {
            SymbolicHotKeysManager.restore()
        }
    }

    private static func startModelIfNeeded() {
        guard model == nil else { return }
        let model = SpacesModel()
        guard model.isSupported else {
            log.error("CGSCopyManagedDisplaySpaces returned no parseable displays — desktop strip self-disabled")
            return
        }
        Self.model = model
        // @Published emits the current value on subscribe, so the initial
        // layout is logged immediately, then again on every refresh. The
        // reconcile keeps the managed Ctrl+N count in sync when desktops are
        // added/removed (cheap no-op otherwise).
        logSink = model.$displays.sink { displays in
            logSnapshot(displays)
            reconcileHotkeys()
        }
        log.info("desktop strip: AXIsProcessTrusted=\(SpaceSwitcher.canSwitch)")
    }

    /// DEBUG automation hook: `notifyutil -p
    /// com.theportlandcompany.FocusDock.debug.toggleStrip` toggles the strip
    /// from the shell — used by milestone verification scripts.
    private static func installDebugToggleListenerIfNeeded() {
        #if DEBUG
        guard !debugToggleInstalled else { return }
        debugToggleInstalled = true
        var token: Int32 = 0
        notify_register_dispatch(
            "com.theportlandcompany.FocusDock.debug.toggleStrip",
            &token,
            DispatchQueue.main
        ) { _ in
            DesktopStripFeature.toggleStrip()
        }
        var walkToken: Int32 = 0
        notify_register_dispatch(
            "com.theportlandcompany.FocusDock.debug.walkRight",
            &walkToken,
            DispatchQueue.main
        ) { _ in
            SpaceSwitcher.debugWalkRight()
        }
        // Switch to global desktop N through the real M3/M4 path:
        //   notifyutil -s …debug.switchToDesktop N -p …debug.switchToDesktop
        // (the notify STATE carries the target desktop number).
        var switchToken: Int32 = 0
        notify_register_dispatch(
            "com.theportlandcompany.FocusDock.debug.switchToDesktop",
            &switchToken,
            DispatchQueue.main
        ) { token in
            var state: UInt64 = 0
            notify_get_state(token, &state)
            let n = Int(state)
            var number = 0
            for display in SpacesBridge.fetchDisplaySpaces() {
                for space in display.spaces where space.isUserDesktop {
                    number += 1
                    guard number == n else { continue }
                    log.info("debug.switchToDesktop \(n) → \(space.uuid, privacy: .public)")
                    requestSwitch(to: space.uuid)
                    return
                }
            }
            log.warning("debug.switchToDesktop \(n): no such desktop")
        }
        #endif
    }

    /// M1 acceptance logging: one line per display, one per space, with the
    /// global Mission-Control desktop number and resolved name.
    private static func logSnapshot(_ displays: [DisplaySpaces]) {
        guard !displays.isEmpty else {
            log.warning("spaces refresh: empty layout (unsupported or shape drift)")
            return
        }
        var number = 0
        for display in displays {
            log.info("spaces: display \(display.displayIdentifier, privacy: .public) current=\(display.currentSpaceUUID ?? "?", privacy: .public) spaces=\(display.spaces.count)")
            for space in display.spaces {
                if space.isUserDesktop {
                    number += 1
                    let name = SpaceNameStore.shared.name(for: space.uuid, defaultNumber: number)
                    log.info("spaces:   #\(number) uuid=\(space.uuid, privacy: .public) type=\(space.type) name=\"\(name, privacy: .public)\"")
                } else {
                    log.info("spaces:   (unnumbered) uuid=\(space.uuid, privacy: .public) type=\(space.type) fullscreen-app")
                }
            }
        }
    }
    #endif
}
