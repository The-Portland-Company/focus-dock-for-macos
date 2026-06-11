import Foundation
import AppKit
import Combine
import os

/// Ungated facade over the custom desktop-strip feature (Mission-Control
/// replacement). This file compiles in EVERY configuration — callers
/// (iOSDockApp, QuitBackstop, status menu, settings) talk only to this type
/// and never need #if APPSTORE. Under APPSTORE everything is a no-op and
/// `isAvailable` is false.
///
/// M1 scope: instantiate the spaces model and log the parsed desktop list on
/// every refresh (the M1 acceptance test). UI, switching, thumbnails and
/// Mission Control interception arrive in M2–M5; applySettings/teardown/
/// selfHeal get real bodies in M3.
enum DesktopStripFeature {
    private static let log = Logger(subsystem: "com.theportlandcompany.FocusDock", category: "Spaces")

    #if !APPSTORE
    private static var model: SpacesModel?
    private static var logSink: AnyCancellable?
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

    /// Called once from app startup. M1: starts the model and logs the
    /// parsed space list on every refresh (initial snapshot + every
    /// activeSpaceDidChange / screen-parameter change).
    static func startIfEnabled() {
        #if !APPSTORE
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
        #endif
    }

    /// Re-reads preferences and reconfigures the feature. Real body in M3.
    static func applySettings() {}

    /// Restores any system state we changed (symbolic hotkeys). Idempotent.
    /// Real body in M3.
    static func teardownForQuit() {}

    /// Launch-time recovery after a crash/force-quit left system state
    /// modified. Real body in M3.
    static func selfHealIfStale() {}

    /// Shows/hides the desktop strip overlay. Real body in M2.
    static func toggleStrip() {}

    #if !APPSTORE
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
