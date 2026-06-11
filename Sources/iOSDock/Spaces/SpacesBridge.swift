import Foundation
import CoreGraphics

// MARK: - Private SkyLight SPI bridge (spaces enumeration)
//
// CGSCopyManagedDisplaySpaces is the only way to enumerate macOS Spaces
// (Mission Control desktops) — there is no public API. Stable through
// macOS 15 and used by every spaces utility on the platform (Spaceman,
// alt-tab-macos, yabai).
//
// Compiled out of the App Store build (APPSTORE flag) so the shipped binary
// contains no private symbols; an APPSTORE companion in SpacesModel.swift
// returns [] so the desktop-strip feature self-disables there.
//
// NOTE: the SPI decls are `private` (not internal) deliberately — the parser
// lives in this file so file scope is sufficient, and an internal
// CGSMainConnectionID would be an invalid redeclaration against the private
// one in MinimizeAnimator.swift. Same duplicate-private-decl pattern as
// _AXUIElementGetWindow in MinimizeAnimator.swift / MinimizedMonitor.swift.

#if !APPSTORE
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> UInt32

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: UInt32) -> Unmanaged<CFArray>?

@_silgen_name("CGSManagedDisplaySetCurrentSpace")
private func CGSManagedDisplaySetCurrentSpace(_ cid: UInt32, _ display: CFString, _ space: UInt64)

enum SpacesBridge {
    /// Enumerates Spaces per display via SkyLight. Parsing is deliberately
    /// defensive: every cast is optional and unknown shapes are skipped, so
    /// if a macOS update changes the dictionary layout the result degrades
    /// to [] (feature self-disables) rather than crashing.
    ///
    /// Observed shape (macOS 12–15), one dict per display:
    ///   "Display Identifier": String — display UUID, or "Main" when
    ///       "Displays have separate Spaces" is off
    ///   "Current Space": ["uuid": String, "id64": ..., "type": ...]
    ///   "Spaces": [["id64"/"ManagedSpaceID": UInt64, "uuid": String,
    ///               "type": Int], ...]
    static func fetchDisplaySpaces() -> [DisplaySpaces] {
        guard let cfArray = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue(),
              let displayDicts = cfArray as? [[String: Any]],
              !displayDicts.isEmpty else { return [] }

        var result: [DisplaySpaces] = []
        for displayDict in displayDicts {
            guard let displayIdentifier = displayDict["Display Identifier"] as? String,
                  !displayIdentifier.isEmpty else { continue }

            let currentSpaceUUID = (displayDict["Current Space"] as? [String: Any])?["uuid"] as? String

            var spaces: [SpaceInfo] = []
            for spaceDict in (displayDict["Spaces"] as? [[String: Any]] ?? []) {
                guard let uuid = spaceDict["uuid"] as? String, !uuid.isEmpty else { continue }
                guard let id64 = (spaceDict["id64"] as? NSNumber)?.uint64Value
                        ?? (spaceDict["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }
                let type = (spaceDict["type"] as? NSNumber)?.intValue ?? 0
                spaces.append(SpaceInfo(id64: id64, uuid: uuid, type: type))
            }
            guard !spaces.isEmpty else { continue }

            result.append(DisplaySpaces(
                displayIdentifier: displayIdentifier,
                currentSpaceUUID: currentSpaceUUID,
                spaces: spaces))
        }
        return result
    }

    /// Asks SkyLight to make `spaceID` the current space of `displayIdentifier`
    /// (the same "Display Identifier" string fetchDisplaySpaces reports).
    /// Used by SpaceSwitcher's fallback path — macOS 26's Dock ignores
    /// synthetic Ctrl+arrow key events from this process, so walking spaces
    /// with keyboard events is not reliable; this SPI switches directly.
    static func setCurrentSpace(displayIdentifier: String, spaceID: UInt64) {
        CGSManagedDisplaySetCurrentSpace(CGSMainConnectionID(), displayIdentifier as CFString, spaceID)
    }
}
#endif
