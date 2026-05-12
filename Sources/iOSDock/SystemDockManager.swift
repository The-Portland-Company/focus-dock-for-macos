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
            // URLs are usually file:// — strip scheme
            var path = urlString
            if let url = URL(string: urlString), url.isFileURL {
                path = url.path
            } else if path.hasPrefix("file://") {
                path = String(path.dropFirst("file://".count)).removingPercentEncoding ?? path
            }
            // Trim trailing slash
            if path.hasSuffix("/") { path.removeLast() }
            if FileManager.default.fileExists(atPath: path) {
                paths.append(path)
            }
        }
        return paths
    }

    private static let kHidden = "systemDockHidden"

    /// Hide system Dock by writing autohide + huge delay + zero animation, then `killall Dock`.
    static func hideSystemDock() {
        let d = UserDefaults.standard
        // Save previous values so we can restore.
        if let dock = UserDefaults(suiteName: "com.apple.dock") {
            if d.object(forKey: "savedDock.autohide") == nil {
                d.set(dock.object(forKey: "autohide"), forKey: "savedDock.autohide")
                d.set(dock.object(forKey: "autohide-delay"), forKey: "savedDock.autohide-delay")
                d.set(dock.object(forKey: "autohide-time-modifier"), forKey: "savedDock.autohide-time-modifier")
                d.set(dock.object(forKey: "no-bouncing"), forKey: "savedDock.no-bouncing")
            }
        }
        run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"])
        run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-delay", "-float", "1000"])
        run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-time-modifier", "-float", "0"])
        run("/usr/bin/defaults", ["write", "com.apple.dock", "no-bouncing", "-bool", "true"])
        run("/usr/bin/killall", ["Dock"])
        d.set(true, forKey: kHidden)
    }

    /// Restore the system Dock to its previous state.
    static func restoreSystemDock() {
        let d = UserDefaults.standard
        let saved = (
            autohide: d.object(forKey: "savedDock.autohide"),
            delay: d.object(forKey: "savedDock.autohide-delay"),
            mod: d.object(forKey: "savedDock.autohide-time-modifier")
        )
        // Reset to saved or defaults.
        if let v = saved.autohide as? Bool {
            run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", v ? "true" : "false"])
        } else {
            run("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide"])
        }
        if let v = saved.delay as? Double {
            run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-delay", "-float", String(v)])
        } else {
            run("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide-delay"])
        }
        if let v = saved.mod as? Double {
            run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-time-modifier", "-float", String(v)])
        } else {
            run("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide-time-modifier"])
        }
        if let v = d.object(forKey: "savedDock.no-bouncing") as? Bool {
            run("/usr/bin/defaults", ["write", "com.apple.dock", "no-bouncing", "-bool", v ? "true" : "false"])
        } else {
            run("/usr/bin/defaults", ["delete", "com.apple.dock", "no-bouncing"])
        }
        run("/usr/bin/killall", ["Dock"])
        d.set(false, forKey: kHidden)
    }

    static var isHidden: Bool { UserDefaults.standard.bool(forKey: kHidden) }

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.launchPath = launchPath
        p.arguments = args
        let null = Pipe()
        p.standardError = null
        p.standardOutput = null
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
