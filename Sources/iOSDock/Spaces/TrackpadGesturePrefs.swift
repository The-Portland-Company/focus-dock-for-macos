import Foundation
import os

// Compiled out of the App Store build: writing the trackpad-driver prefs is
// part of the private desktop-strip feature (DMG/dev only). Callers go through
// the ungated DesktopStripFeature facade.
#if !APPSTORE

/// Snapshots and disables the system "swipe up for Mission Control" four-finger
/// gesture while the feature runs, so OUR MultitouchSupport detector can own
/// the four-finger swipe-up without the WindowServer ALSO triggering system
/// Mission Control. Restored exactly on quit/disable, with launch self-heal
/// after a crash — the same snapshot pattern as SymbolicHotKeysManager.
///
/// The gesture lives in two driver domains (built-in trackpad + Bluetooth
/// Magic Trackpad). The relevant key is `TrackpadFourFingerVertSwipeGesture`
/// (2 = enabled, 0 = disabled); `TrackpadThreeFingerVertSwipeGesture` mirrors
/// it when the user set the gesture to three fingers, so we manage both verts.
///
/// Persistence (all in OUR UserDefaults, survives crashes):
/// - `savedTrackpadGesture.snapshotTaken`
/// - `savedTrackpadGesture.<domain>.<key>.present` / `.<value>`
/// - `trackpadGesture.managing` — fingerprint (true ⇒ crashed mid-session)
enum TrackpadGesturePrefs {
    private static let log = Logger(subsystem: "com.theportlandcompany.FocusDock", category: "Spaces")

    /// Trackpad driver prefs domains that carry the vertical-swipe gesture.
    private static let domains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    ]
    /// Keys that control "swipe up/down for Mission Control / App Exposé".
    private static let gestureKeys = [
        "TrackpadFourFingerVertSwipeGesture",
        "TrackpadThreeFingerVertSwipeGesture"
    ]

    private static let kSnapshotTaken = "savedTrackpadGesture.snapshotTaken"
    private static let kManaging = "trackpadGesture.managing"
    private static func presentKey(_ d: String, _ k: String) -> String { "savedTrackpadGesture.\(d).\(k).present" }
    private static func savedKey(_ d: String, _ k: String) -> String { "savedTrackpadGesture.\(d).\(k).value" }

    static var hasSnapshot: Bool { UserDefaults.standard.bool(forKey: kSnapshotTaken) }
    static var isManaging: Bool { UserDefaults.standard.bool(forKey: kManaging) }

    // MARK: - Apple-domain plumbing

    private static func readValue(_ key: String, _ domain: String) -> Any? {
        let d = domain as CFString
        CFPreferencesAppSynchronize(d)
        return CFPreferencesCopyAppValue(key as CFString, d)
    }

    @discardableResult
    private static func writeValue(_ value: Any?, _ key: String, _ domain: String) -> Bool {
        let d = domain as CFString
        CFPreferencesSetAppValue(key as CFString, value as CFTypeRef?, d)
        return CFPreferencesAppSynchronize(d)
    }

    // MARK: - Snapshot + disable

    /// Snapshots the gesture keys (once per managed session) then writes 0
    /// (disabled) so the system stops opening Mission Control on a four-finger
    /// swipe up — leaving the gesture for OUR detector. No-op if already
    /// managing. The current-state read of EACH key feeds the snapshot so we
    /// restore exactly (absent before → restore deletes the override).
    static func disableSystemSwipeUp() {
        let ud = UserDefaults.standard
        if !ud.bool(forKey: kSnapshotTaken) {
            for domain in domains {
                for key in gestureKeys {
                    if let value = readValue(key, domain) {
                        ud.set(true, forKey: presentKey(domain, key))
                        ud.set(value, forKey: savedKey(domain, key))
                    } else {
                        ud.set(false, forKey: presentKey(domain, key))
                        ud.removeObject(forKey: savedKey(domain, key))
                    }
                }
            }
            ud.set(true, forKey: kSnapshotTaken)
            log.info("trackpad gesture: snapshot of vert-swipe keys saved")
        }
        for domain in domains {
            for key in gestureKeys {
                writeValue(0 as CFNumber, key, domain)
            }
        }
        ud.set(true, forKey: kManaging)
        ud.synchronize()
        applyTrackpadPrefs()
        log.info("trackpad gesture: system swipe-up for Mission Control disabled")
    }

    // MARK: - Restore

    /// Restores the snapshotted gesture keys exactly (absent before → override
    /// removed) and clears our snapshot/fingerprint. Idempotent.
    static func restore() {
        let ud = UserDefaults.standard
        guard ud.bool(forKey: kSnapshotTaken) else {
            ud.removeObject(forKey: kManaging)
            return
        }
        for domain in domains {
            for key in gestureKeys {
                if ud.bool(forKey: presentKey(domain, key)), let saved = ud.object(forKey: savedKey(domain, key)) {
                    writeValue(saved, key, domain)
                } else {
                    writeValue(nil, key, domain) // delete the override
                }
            }
        }
        applyTrackpadPrefs()
        for domain in domains {
            for key in gestureKeys {
                ud.removeObject(forKey: presentKey(domain, key))
                ud.removeObject(forKey: savedKey(domain, key))
            }
        }
        ud.removeObject(forKey: kSnapshotTaken)
        ud.removeObject(forKey: kManaging)
        ud.synchronize()
        log.info("trackpad gesture: vert-swipe keys restored to pre-launch values")
    }

    /// Launch-time recovery: a stored snapshot at launch means a previous
    /// session disabled the gesture and did not restore it (crash / kill -9).
    /// Restore the originals; if the feature is still enabled this launch the
    /// facade re-disables cleanly right after. Mirrors
    /// SymbolicHotKeysManager.selfHealIfStale().
    static func selfHealIfStale() {
        guard hasSnapshot else { return }
        log.warning("trackpad gesture: stale snapshot at launch (previous session did not restore) — restoring originals")
        restore()
    }

    // MARK: - Apply (make the driver notice)

    /// Push the trackpad pref changes into the running input system. The
    /// trackpad driver re-reads its prefs on a distributed notification; we
    /// also nudge cfprefsd as a backstop.
    private static func applyTrackpadPrefs() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.MultitouchSupport.HID.MTPreferencesChanged"),
            object: nil, userInfo: nil, deliverImmediately: true
        )
        let activate = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
        if FileManager.default.isExecutableFile(atPath: activate) {
            let p = Process()
            p.launchPath = activate
            p.arguments = ["-u"]
            let null = Pipe(); p.standardOutput = null; p.standardError = null
            try? p.run()
            p.waitUntilExit()
        }
    }
}

#endif
