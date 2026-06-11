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
/// M2 scope: read-only strip overlay (gradient placeholders + inline rename)
/// behind the `desktopStripEnabled` preference. Real switching, thumbnails
/// and Mission Control interception arrive in M3–M5; teardown/selfHeal get
/// real bodies in M3 when system state (symbolic hotkeys) is first modified.
enum DesktopStripFeature {
    private static let log = Logger(subsystem: "com.theportlandcompany.FocusDock", category: "Spaces")

    #if !APPSTORE
    private static var model: SpacesModel?
    private static var logSink: AnyCancellable?
    private static var controller: DesktopStripController?
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
        guard Preferences.shared.desktopStripEnabled, isAvailable, let model else {
            controller?.hide()
            controller = nil
            return
        }
        if controller == nil {
            controller = DesktopStripController(model: model)
        }
        #endif
    }

    /// Restores any system state we changed (symbolic hotkeys — M3) and
    /// dismisses the overlay. Idempotent.
    static func teardownForQuit() {
        #if !APPSTORE
        controller?.hide()
        #endif
    }

    /// Launch-time recovery after a crash/force-quit left system state
    /// modified. Real body in M3 (nothing persistent is changed yet).
    static func selfHealIfStale() {}

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
        if controller == nil {
            controller = DesktopStripController(model: model)
        }
        controller?.toggle()
        #endif
    }

    /// M3 hook: switch macOS to the given space (SpaceSwitcher). M2 logs only —
    /// the strip's Return key and (later) tile clicks route through here.
    static func requestSwitch(to uuid: String) {
        #if !APPSTORE
        log.info("requestSwitch(to: \(uuid, privacy: .public)) — real switching lands in M3")
        #endif
    }

    #if !APPSTORE
    private static func startModelIfNeeded() {
        guard model == nil else { return }
        let model = SpacesModel()
        guard model.isSupported else {
            log.error("CGSCopyManagedDisplaySpaces returned no parseable displays — desktop strip self-disabled")
            return
        }
        Self.model = model
        // @Published emits the current value on subscribe, so the initial
        // layout is logged immediately, then again on every refresh.
        logSink = model.$displays.sink { displays in
            logSnapshot(displays)
        }
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
