import Foundation
import os

// Compiled out of the App Store build: writing com.apple.symbolichotkeys is
// impossible from the sandbox and the whole desktop-switching feature is
// DMG/dev-only. Callers go through the ungated DesktopStripFeature facade.
#if !APPSTORE

/// Manages the "Switch to Desktop N" symbolic hotkeys (IDs 118–126 in
/// `com.apple.symbolichotkeys`, key `AppleSymbolicHotKeys`) so SpaceSwitcher
/// can post Ctrl+1…9 for direct desktop switching. They are off by default on
/// macOS — we snapshot the user's values, merge-enable the ones we need, and
/// restore the snapshot exactly on quit (same snapshot/self-heal pattern as
/// SystemDockManager for com.apple.dock).
///
/// Persistence model (all in OUR UserDefaults, so it survives crashes):
/// - `savedSymHotkeys.snapshotTaken` — a snapshot of IDs 118–126 exists
/// - `savedSymHotkeys.<id>.present` / `savedSymHotkeys.<id>` — pre-change
///   value per ID (absent before → restore removes the entry)
/// - `symHotkeys.managedCount` — fingerprint: how many IDs we enabled
///   (0 = not currently managing). Non-zero at launch ⇒ crashed mid-session.
/// - `symHotkeys.unreliable` — functional probe failed; SpaceSwitcher must
///   use the direct SPI switch until hotkeys are re-enabled successfully.
enum SymbolicHotKeysManager {
    private static let log = Logger(subsystem: "com.theportlandcompany.FocusDock", category: "Spaces")

    /// Symbolic hotkey IDs for "Switch to Desktop 1…9".
    static let switchDesktopIDs = Array(118...126)
    /// ANSI keycodes for the digit row 1…9 (kVK_ANSI_1 … kVK_ANSI_9).
    static let digitKeyCodes: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    /// Modifier mask for the hotkey parameters: Ctrl.
    private static let ctrlModifier = 262144

    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let hotkeysKey = "AppleSymbolicHotKeys" as CFString

    // Our-prefs keys (UserDefaults.standard).
    private static let kSnapshotTaken = "savedSymHotkeys.snapshotTaken"
    private static let kManagedCount = "symHotkeys.managedCount"
    private static let kUnreliable = "symHotkeys.unreliable"
    private static func savedKey(_ id: Int) -> String { "savedSymHotkeys.\(id)" }
    private static func presentKey(_ id: Int) -> String { "savedSymHotkeys.\(id).present" }

    // MARK: - State

    /// Number of desktop hotkeys we currently manage (0 = none / restored).
    static var managedCount: Int {
        UserDefaults.standard.integer(forKey: kManagedCount)
    }

    /// True while a pre-change snapshot of IDs 118–126 is stored.
    static var hasSnapshot: Bool {
        UserDefaults.standard.bool(forKey: kSnapshotTaken)
    }

    /// True when a functional probe failed and Ctrl+N must not be trusted.
    static var isUnreliable: Bool {
        UserDefaults.standard.bool(forKey: kUnreliable)
    }

    /// Persisted flag: the Ctrl+N path failed verification → SpaceSwitcher
    /// switches via the direct SPI permanently until hotkeys are
    /// successfully re-enabled.
    static func markUnreliable() {
        UserDefaults.standard.set(true, forKey: kUnreliable)
        UserDefaults.standard.synchronize()
        log.error("symbolic hotkeys marked UNRELIABLE — falling back to direct SPI switching")
    }

    private static func clearUnreliable() {
        UserDefaults.standard.removeObject(forKey: kUnreliable)
    }

    // MARK: - Apple-domain plumbing

    /// The full AppleSymbolicHotKeys dict as currently stored (may be empty —
    /// a fresh account has no entry until something is customized).
    private static func readHotkeysDict() -> [String: Any] {
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyAppValue(hotkeysKey, domain)
        return value as? [String: Any] ?? [:]
    }

    /// Writes the WHOLE dict back (merge happens in callers — never clobber
    /// IDs we don't manage) and synchronizes the domain.
    private static func writeHotkeysDict(_ dict: [String: Any]) -> Bool {
        CFPreferencesSetAppValue(hotkeysKey, dict as CFDictionary, domain)
        return CFPreferencesAppSynchronize(domain)
    }

    // MARK: - Snapshot

    /// Captures the user's current values for IDs 118–126 into OUR prefs.
    /// Exactly once per managed session (no-op while a snapshot exists) so we
    /// never overwrite the true originals with our own enabled entries.
    static func snapshot() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: kSnapshotTaken) else { return }
        let dict = readHotkeysDict()
        for id in switchDesktopIDs {
            if let value = dict[String(id)] {
                d.set(true, forKey: presentKey(id))
                d.set(value, forKey: savedKey(id))
            } else {
                // Absent = system default (off). Restore must delete the entry.
                d.set(false, forKey: presentKey(id))
                d.removeObject(forKey: savedKey(id))
            }
        }
        d.set(true, forKey: kSnapshotTaken)
        d.synchronize()
        log.info("symbolichotkeys: snapshot of IDs 118–126 saved")
    }

    // MARK: - Enable / restore

    /// Merge-writes enabled "Switch to Desktop n" entries for n = 1...count
    /// (capped at 9). Reads the full dict, replaces only our IDs, writes the
    /// whole dict back. Returns false when the prefs write failed.
    @discardableResult
    static func enableSwitchHotkeys(count: Int) -> Bool {
        let n = max(0, min(count, 9))
        guard n > 0 else { return false }
        let freshSession = !hasSnapshot
        snapshot() // idempotent — first call this session captures originals

        var dict = readHotkeysDict()
        for i in 0..<n {
            let id = switchDesktopIDs[i]
            // Same shape System Settings writes: enabled as integer 1,
            // parameters [ascii('1'+i), kVK digit, Ctrl mask].
            dict[String(id)] = [
                "enabled": 1,
                "value": [
                    "parameters": [49 + i, Int(digitKeyCodes[i]), ctrlModifier],
                    "type": "standard"
                ]
            ]
        }
        guard writeHotkeysDict(dict) else {
            log.error("symbolichotkeys: CFPreferences write FAILED — leaving hotkeys unmanaged")
            return false
        }
        UserDefaults.standard.set(n, forKey: kManagedCount)
        // A fresh managed session gets a fresh chance: clear the unreliable
        // flag so the next switch re-runs the Ctrl+N functional probe.
        if freshSession { clearUnreliable() }
        UserDefaults.standard.synchronize()
        apply()
        log.info("symbolichotkeys: enabled Ctrl+1…\(n) (IDs 118–\(118 + n - 1))")
        return true
    }

    /// Writes the snapshotted 118–126 entries back exactly (absent before →
    /// entry removed), synchronizes + applies, then clears our snapshot and
    /// fingerprint. Idempotent: a second call finds no snapshot and returns.
    static func restore() {
        let d = UserDefaults.standard
        guard d.bool(forKey: kSnapshotTaken) else {
            // Nothing snapshotted — make sure the fingerprint is clean too.
            d.removeObject(forKey: kManagedCount)
            return
        }
        var dict = readHotkeysDict()
        for id in switchDesktopIDs {
            if d.bool(forKey: presentKey(id)), let saved = d.object(forKey: savedKey(id)) {
                dict[String(id)] = saved
            } else {
                dict.removeValue(forKey: String(id))
            }
        }
        if writeHotkeysDict(dict) {
            log.info("symbolichotkeys: restored IDs 118–126 to pre-launch values")
        } else {
            log.error("symbolichotkeys: restore write FAILED — system may keep our Ctrl+N entries")
        }
        apply()
        d.removeObject(forKey: kSnapshotTaken)
        d.removeObject(forKey: kManagedCount)
        for id in switchDesktopIDs {
            d.removeObject(forKey: savedKey(id))
            d.removeObject(forKey: presentKey(id))
        }
        d.synchronize()
    }

    // MARK: - Apply (make the system notice)

    /// Pushes the new prefs into the running hotkey machinery. activateSettings
    /// is the canonical way (same one System Settings uses); if it is missing
    /// or fails we nudge cfprefsd. We deliberately do NOT killall Dock here —
    /// it owns Mission Control state and our SystemDockManager hide settings;
    /// restarting it mid-session is disruptive. The functional probe in
    /// SpaceSwitcher catches the (unobserved so far) case where neither works.
    static func apply() {
        let activate = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
        if FileManager.default.isExecutableFile(atPath: activate),
           runProcess(activate, ["-u"]) == 0 {
            return
        }
        log.warning("symbolichotkeys: activateSettings unavailable/failed — falling back to cfprefsd nudge")
        _ = runProcess("/usr/bin/killall", ["cfprefsd"])
    }

    @discardableResult
    private static func runProcess(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.launchPath = path
        p.arguments = args
        let null = Pipe()
        p.standardOutput = null
        p.standardError = null
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: - Self-heal

    /// Launch-time recovery: a stored snapshot means a previous session
    /// changed the hotkeys and did NOT restore them (crash / kill -9 / power
    /// loss). Restore the originals first; if the feature is (still) enabled
    /// this launch, DesktopStripFeature re-snapshots + re-enables cleanly
    /// right after. Mirrors SystemDockManager.selfHealIfStaleHide().
    static func selfHealIfStale() {
        guard hasSnapshot else { return }
        log.warning("symbolichotkeys: stale snapshot found at launch (previous session did not restore) — restoring originals")
        restore()
    }

    /// Successful enable + verified switch ⇒ the Ctrl+N path works again.
    static func markReliable() {
        clearUnreliable()
    }
}

#endif
