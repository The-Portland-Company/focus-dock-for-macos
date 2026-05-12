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
    private static let savedKeys = ["autohide", "autohide-delay", "autohide-time-modifier", "no-bouncing"]
    private static let dockDomain = "com.apple.dock" as CFString

    /// Hide system Dock by writing autohide + huge delay + zero animation, then `killall Dock`.
    static func hideSystemDock() {
        snapshotOriginalsIfNeeded()
        setDockValue("autohide", kCFBooleanTrue)
        setDockValue("autohide-delay", 1000.0 as CFNumber)
        setDockValue("autohide-time-modifier", 0.0 as CFNumber)
        setDockValue("no-bouncing", kCFBooleanTrue)
        CFPreferencesAppSynchronize(dockDomain)
        restartDockSync()
        let d = UserDefaults.standard
        d.set(true, forKey: kHidden)
        d.synchronize()
    }

    /// Capture the user's pre-hide values exactly once. Subsequent calls are no-ops.
    /// Guards against the "we hid the Dock, then on next launch re-read our own hide
    /// values as originals" bug.
    private static func snapshotOriginalsIfNeeded() {
        let d = UserDefaults.standard
        if d.bool(forKey: kSnapshotTaken) { return }
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

    /// Self-heal at launch: if a previous run was force-quit (or crashed) while
    /// the Dock was hidden, our snapshot is still valid. Restore originals first
    /// so we don't lose them when we re-hide.
    static func selfHealIfStaleHide() {
        let d = UserDefaults.standard
        if d.bool(forKey: kSnapshotTaken) && d.bool(forKey: kHidden) {
            restoreSystemDock()
        }
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
