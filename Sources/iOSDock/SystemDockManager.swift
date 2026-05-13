import Foundation
import AppKit

/// Reads/disables/restores the system Dock.
enum SystemDockManager {

    /// Read pinned apps from `~/Library/Preferences/com.apple.dock.plist` → `persistent-apps`.
    static func readSystemDockApps() -> [String] {
        guard let dock = UserDefaults(suiteName: "com.apple.dock") else { return [] }
        guard let persistent = dock.array(forKey: "persistent-apps") as? [[String: Any]] else { return [] }
        var paths: [String] = []
        for entry in persistent {
            guard let tileData = entry["tile-data"] as? [String: Any],
                  let fileData = tileData["file-data"] as? [String: Any],
                  let urlString = fileData["_CFURLString"] as? String else { continue }
            var path = urlString
            if let url = URL(string: urlString), url.isFileURL {
                path = url.path
            } else if path.hasPrefix("file://") {
                path = String(path.dropFirst("file://".count)).removingPercentEncoding ?? path
            }
            if path.hasSuffix("/") { path.removeLast() }
            if FileManager.default.fileExists(atPath: path) {
                paths.append(path)
            }
        }
        return paths
    }

    // Persistent state in our app's UserDefaults (NOT com.apple.dock).
    private static let kHidden = "systemDockHidden"
    private static let kSnapshotTaken = "savedDock.snapshotTaken"
    private static let savedKeys = ["autohide", "autohide-delay", "autohide-time-modifier", "no-bouncing", "tilesize", "magnification", "largesize"]
    private static let dockDomain = "com.apple.dock" as CFString

    /// Hide system Dock by writing autohide + huge delay + zero animation, then `killall Dock`.
    static func hideSystemDock() {
        snapshotOriginalsIfNeeded()
        setDockValue("autohide", kCFBooleanTrue)
        setDockValue("autohide-delay", 1000.0 as CFNumber)
        setDockValue("autohide-time-modifier", 0.0 as CFNumber)
        setDockValue("no-bouncing", kCFBooleanTrue)
        // Shrink to the minimum tile size and disable magnification so that when
        // Mission Control / Exposé forcibly reveals the system Dock (Apple's
        // overlay always shows it, ignoring autohide), it appears as a tiny
        // sliver instead of a full-size Dock competing with ours.
        setDockValue("tilesize", 16 as CFNumber)
        setDockValue("magnification", kCFBooleanFalse)
        setDockValue("largesize", 16 as CFNumber)
        CFPreferencesAppSynchronize(dockDomain)
        restartDockSync()
        let d = UserDefaults.standard
        d.set(true, forKey: kHidden)
        d.synchronize()
    }

    /// Capture the user's pre-hide values exactly once. Subsequent calls are no-ops.
    /// Guards against the "we hid the Dock, then on next launch re-read our own hide
    /// values as originals" bug. If the live values already match our hide-state
    /// fingerprint (autohide=true + autohide-delay≈1000 + autohide-time-modifier=0),
    /// the snapshot is treated as clean-default — restoring will delete those keys
    /// and the OS falls back to native defaults.
    private static func snapshotOriginalsIfNeeded() {
        let d = UserDefaults.standard
        if d.bool(forKey: kSnapshotTaken) { return }
        if liveValuesMatchHideFingerprint() {
            // Upgrade path: a pre-fix build already hid the Dock and our originals
            // are gone. Record "no prior values" so restore() deletes the keys.
            for key in savedKeys {
                d.set(false, forKey: "savedDock.\(key).present")
                d.removeObject(forKey: "savedDock.\(key)")
            }
            d.set(true, forKey: kSnapshotTaken)
            d.synchronize()
            return
        }
        for key in savedKeys {
            let value = CFPreferencesCopyAppValue(key as CFString, dockDomain)
            if let v = value {
                d.set(true, forKey: "savedDock.\(key).present")
                d.set(v as Any, forKey: "savedDock.\(key)")
            } else {
                d.set(false, forKey: "savedDock.\(key).present")
                d.removeObject(forKey: "savedDock.\(key)")
            }
        }
        d.set(true, forKey: kSnapshotTaken)
        d.synchronize()
    }

    /// True iff the current com.apple.dock values look like values WE wrote in
    /// `hideSystemDock()`. Used to detect upgrade-from-pre-fix-build pollution.
    private static func liveValuesMatchHideFingerprint() -> Bool {
        let autohide = CFPreferencesCopyAppValue("autohide" as CFString, dockDomain) as? Bool ?? false
        let delay = (CFPreferencesCopyAppValue("autohide-delay" as CFString, dockDomain) as? NSNumber)?.doubleValue ?? 0
        let timeMod = (CFPreferencesCopyAppValue("autohide-time-modifier" as CFString, dockDomain) as? NSNumber)?.doubleValue ?? -1
        return autohide && delay >= 900 && timeMod == 0
    }

    /// Restore the system Dock to its previous state. Fully synchronous on the quit path.
    static func restoreSystemDock() {
        let d = UserDefaults.standard
        for key in savedKeys {
            let present = d.bool(forKey: "savedDock.\(key).present")
            if present, let saved = d.object(forKey: "savedDock.\(key)") {
                CFPreferencesSetAppValue(key as CFString, saved as CFPropertyList, dockDomain)
            } else {
                CFPreferencesSetAppValue(key as CFString, nil, dockDomain)
            }
        }
        CFPreferencesAppSynchronize(dockDomain)
        restartDockSync()
        d.set(false, forKey: kHidden)
        d.set(false, forKey: kSnapshotTaken)
        for key in savedKeys {
            d.removeObject(forKey: "savedDock.\(key)")
            d.removeObject(forKey: "savedDock.\(key).present")
        }
        d.synchronize()
    }

    static var isHidden: Bool { UserDefaults.standard.bool(forKey: kHidden) }

    /// Self-heal at launch:
    /// 1. If a snapshot exists and `kHidden` is set, restore originals first so we
    ///    don't lose them when we re-hide this launch.
    /// 2. If `kHidden` is set but no snapshot exists (upgrade from a pre-fix build),
    ///    treat the system as "originals unknown" and restore to native defaults
    ///    by deleting the keys we wrote.
    /// 3. If the saved snapshot looks like our own hide-state fingerprint (polluted
    ///    snapshot from an earlier broken build), discard it before restoring so
    ///    the restore deletes the keys instead of re-writing the hide values.
    static func selfHealIfStaleHide() {
        let d = UserDefaults.standard
        let hidden = d.bool(forKey: kHidden)
        let hasSnapshot = d.bool(forKey: kSnapshotTaken)
        guard hidden else { return }
        if hasSnapshot && savedSnapshotMatchesHideFingerprint() {
            clearSnapshot()
        }
        restoreSystemDock()
    }

    /// True iff the saved per-key snapshot values are themselves the values WE
    /// would have written in `hideSystemDock()`. Signals a polluted snapshot
    /// captured by an earlier broken build.
    private static func savedSnapshotMatchesHideFingerprint() -> Bool {
        let d = UserDefaults.standard
        let autohide = (d.object(forKey: "savedDock.autohide") as? NSNumber)?.boolValue ?? false
        let delay = (d.object(forKey: "savedDock.autohide-delay") as? NSNumber)?.doubleValue ?? 0
        let timeMod = (d.object(forKey: "savedDock.autohide-time-modifier") as? NSNumber)?.doubleValue ?? -1
        return autohide && delay >= 900 && timeMod == 0
    }

    private static func clearSnapshot() {
        let d = UserDefaults.standard
        d.set(false, forKey: kSnapshotTaken)
        for key in savedKeys {
            d.removeObject(forKey: "savedDock.\(key)")
            d.removeObject(forKey: "savedDock.\(key).present")
        }
        d.synchronize()
    }

    private static func setDockValue(_ key: String, _ value: CFPropertyList?) {
        CFPreferencesSetAppValue(key as CFString, value, dockDomain)
    }

    private static func restartDockSync() {
        let p = Process()
        p.launchPath = "/usr/bin/killall"
        p.arguments = ["Dock"]
        let null = Pipe()
        p.standardError = null
        p.standardOutput = null
        do { try p.run() } catch { return }
        p.waitUntilExit()
    }
}
