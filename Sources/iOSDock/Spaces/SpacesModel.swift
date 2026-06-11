import Foundation
import AppKit

// MARK: - Value types (ungated — compile in every config, including APPSTORE,
// so the rest of the app never needs #if around spaces types)

/// One macOS Space as reported by SkyLight.
/// `type` 0 = user desktop, 4 = fullscreen-app space.
struct SpaceInfo: Equatable {
    let id64: UInt64
    let uuid: String
    let type: Int

    var isUserDesktop: Bool { type == 0 }
}

/// The Spaces belonging to one display, in Mission Control order.
struct DisplaySpaces: Equatable {
    /// Display UUID string, or "Main" when "Displays have separate Spaces"
    /// is off (single shared space list).
    let displayIdentifier: String
    let currentSpaceUUID: String?
    let spaces: [SpaceInfo]
}

#if APPSTORE
/// App Store companion for the SkyLight bridge (the real one in
/// SpacesBridge.swift is compiled out). Returns no data so the desktop-strip
/// feature self-disables without any caller needing #if.
enum SpacesBridge {
    static func fetchDisplaySpaces() -> [DisplaySpaces] { [] }
}
#endif

// MARK: - Observable model

/// Observable snapshot of the system's Spaces layout. Refreshes whenever the
/// active Space changes (public NSWorkspace notification) or the display
/// configuration changes. Empty (`isSupported == false`) in the App Store
/// build or when the SkyLight dictionary shape has drifted.
final class SpacesModel: ObservableObject {
    @Published private(set) var displays: [DisplaySpaces] = []

    private var workspaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    init() {
        refresh()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    deinit {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    /// False in the App Store build, and in DMG/dev builds when the private
    /// API returned nothing parseable (macOS shape drift → self-disable).
    var isSupported: Bool {
        #if APPSTORE
        return false
        #else
        return !displays.isEmpty
        #endif
    }

    /// Flat list of user desktops (type 0) across all displays, in global
    /// Mission Control order.
    var desktopSpaces: [SpaceInfo] {
        displays.flatMap { $0.spaces.filter(\.isUserDesktop) }
    }

    func refresh() {
        // Unconditional assignment on purpose: every refresh re-publishes so
        // observers (logging in M1, thumbnails/strip later) get a tick even
        // when the layout is unchanged.
        displays = SpacesBridge.fetchDisplaySpaces()
    }

    /// Global Mission-Control numbering: desktops are numbered 1..N counting
    /// type-0 spaces in display order across all displays — exactly how MC
    /// labels "Desktop N" when "Displays have separate Spaces" is on.
    /// Fullscreen-app spaces have no number (returns nil).
    func desktopNumber(for uuid: String) -> Int? {
        var number = 0
        for display in displays {
            for space in display.spaces where space.isUserDesktop {
                number += 1
                if space.uuid == uuid { return number }
            }
        }
        return nil
    }

    /// Resolves the NSScreen showing the given display entry.
    func screen(for display: DisplaySpaces) -> NSScreen? {
        Self.screen(forDisplayIdentifier: display.displayIdentifier)
    }

    /// Matches a SkyLight display identifier (a display UUID string, or
    /// "Main") to an NSScreen via ScreenIdentity (ProfileManager.swift),
    /// which converts NSScreenNumber → CGDisplayCreateUUIDFromDisplayID.
    static func screen(forDisplayIdentifier identifier: String) -> NSScreen? {
        if identifier == "Main" { return NSScreen.screens.first }
        if let exact = ScreenIdentity.screen(forUUID: identifier) { return exact }
        // Defensive: CFUUID strings are uppercase; tolerate case drift.
        for s in NSScreen.screens
        where ScreenIdentity.uuid(for: s)?.caseInsensitiveCompare(identifier) == .orderedSame {
            return s
        }
        return nil
    }
}
