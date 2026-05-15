import Foundation
import AppKit

/// A named bundle of (pinned items + dock-visual preferences).
/// Each profile gets its own library.json and a UserDefaults namespace
/// `profile.<uuid>.<key>`. Switching the active profile reloads the dock.
/// Where a profile's dock(s) appear. `.allScreens` clones one dock onto every
/// connected display. `.main` shows it only on the current main screen.
/// `.specific(uuid, name)` pins it to one screen by `CGDirectDisplayID`-derived
/// stable UUID; `name` is the human-readable display name for the picker UI
/// (may be stale if the screen is renamed or disconnected).
enum ScreenAssignment: Codable, Equatable {
    case allScreens
    case main
    case specific(uuid: String, name: String)

    var label: String {
        switch self {
        case .allScreens: return "All screens"
        case .main: return "Main screen only"
        case .specific(_, let name): return name
        }
    }
}

struct ProfileMeta: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var screen: ScreenAssignment = .allScreens

    // Custom decoder: tolerate the absence of `screen` for pre-Phase-2 profiles.
    enum CodingKeys: String, CodingKey { case id, name, screen }
    init(id: UUID, name: String, screen: ScreenAssignment = .allScreens) {
        self.id = id; self.name = name; self.screen = screen
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.screen = (try? c.decode(ScreenAssignment.self, forKey: .screen)) ?? .allScreens
    }
}

/// Helpers for `NSScreen` → stable identifier used by `ScreenAssignment.specific`.
enum ScreenIdentity {
    /// Stable per-display ID derived from `CGDirectDisplayID`. Survives sleep
    /// and (mostly) hot-plug; the exact same display will return the same ID.
    static func uuid(for screen: NSScreen) -> String? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(num.uint32Value)
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, cfUUID) as String
        }
        // Fallback to the raw display ID as a string. Less stable but better
        // than nothing.
        return String(displayID)
    }

    static func screen(forUUID uuid: String) -> NSScreen? {
        for s in NSScreen.screens {
            if ScreenIdentity.uuid(for: s) == uuid { return s }
        }
        return nil
    }

    static func displayName(for screen: NSScreen) -> String {
        screen.localizedName
    }
}

/// Per-profile dock-visual UserDefaults keys. Anything in this set is
/// stored namespaced; everything else (menu-bar icon visibility, dock-icon
/// visibility, edit-layout flag) is global to the app.
enum ProfileKeys {
    static let perProfile: Set<String> = [
        "dockEdge", "iconSize", "spacing",
        "magnifyOnHover", "magnifySize", "labelMode",
        "marginTop", "marginBottom", "marginLeft", "marginRight",
        "flushBottom", "cornerRadius",
        "tintBackground", "backgroundColor",
        "showBorder", "borderColor", "borderWidth",
        "edgeOffset", "showFinder", "showTrash",
        "autoHideDock", "bounceOnLaunch",
        "showRunningIndicators", "showRecentApps",
        "fillWidth", "paddingUniform", "dockScale"
    ]

    static func isPerProfile(_ key: String) -> Bool { perProfile.contains(key) }
}

final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()
    static let activeChanged = Notification.Name("FocusDock.ActiveProfileChanged")
    static let listChanged = Notification.Name("FocusDock.ProfilesListChanged")

    private let defaults = UserDefaults.standard
    private let kProfiles = "FocusDock.profiles.v1"
    private let kActive = "FocusDock.activeProfile.v1"
    private let kDidMigrate = "FocusDock.profilesDidMigrateLegacy"

    @Published private(set) var profiles: [ProfileMeta] = []
    @Published private(set) var activeID: UUID

    init() {
        // Bootstrap order: load list, migrate legacy if needed, ensure non-empty,
        // select active.
        var loaded = Self.loadProfiles(defaults: defaults, key: kProfiles)
        if loaded.isEmpty {
            // First run with profiles support — create a single "Default" profile.
            let def = ProfileMeta(id: UUID(), name: "Default")
            loaded = [def]
            Self.saveProfiles(loaded, defaults: defaults, key: kProfiles)
            defaults.set(def.id.uuidString, forKey: kActive)
        }
        self.profiles = loaded

        if let stored = defaults.string(forKey: kActive),
           let uuid = UUID(uuidString: stored),
           loaded.contains(where: { $0.id == uuid }) {
            self.activeID = uuid
        } else {
            self.activeID = loaded[0].id
            defaults.set(loaded[0].id.uuidString, forKey: kActive)
        }

        migrateLegacyIfNeeded()
        ensureProfileDir(activeID)
    }

    // MARK: - Storage paths / keys

    private static var profilesRootDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusDock", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var legacyLibraryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusDock", isDirectory: true)
            .appendingPathComponent("library.json")
    }

    func profileDir(_ id: UUID) -> URL {
        let dir = Self.profilesRootDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func libraryURL(for id: UUID) -> URL {
        profileDir(id).appendingPathComponent("library.json")
    }

    /// Namespaced UserDefaults key for the given profile.
    func nsKey(_ key: String, for id: UUID) -> String {
        "profile." + id.uuidString + "." + key
    }

    /// Namespaced UserDefaults key for the active profile.
    func nsKey(_ key: String) -> String { nsKey(key, for: activeID) }

    private func ensureProfileDir(_ id: UUID) { _ = profileDir(id) }

    // MARK: - List ops

    var active: ProfileMeta {
        profiles.first(where: { $0.id == activeID }) ?? profiles[0]
    }

    @discardableResult
    func addProfile(name: String, duplicateFrom sourceID: UUID? = nil) -> UUID {
        let new = ProfileMeta(id: UUID(), name: uniqueName(name))
        profiles.append(new)
        Self.saveProfiles(profiles, defaults: defaults, key: kProfiles)
        ensureProfileDir(new.id)

        if let src = sourceID {
            duplicateProfileData(from: src, to: new.id)
        } else {
            // Seed namespaced visual prefs from current defaults so the new
            // profile starts with sensible values (matches Preferences init seeds).
            seedDefaultsForProfile(new.id)
        }
        NotificationCenter.default.post(name: Self.listChanged, object: nil)
        return new.id
    }

    func setScreen(_ id: UUID, _ screen: ScreenAssignment) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        guard profiles[idx].screen != screen else { return }
        profiles[idx].screen = screen
        Self.saveProfiles(profiles, defaults: defaults, key: kProfiles)
        NotificationCenter.default.post(name: Self.listChanged, object: nil)
        // If this is the active profile, the dock window layout depends on it.
        if id == activeID {
            NotificationCenter.default.post(name: Self.activeChanged, object: nil)
        }
    }

    func renameProfile(_ id: UUID, to newName: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        profiles[idx].name = trimmed
        Self.saveProfiles(profiles, defaults: defaults, key: kProfiles)
        NotificationCenter.default.post(name: Self.listChanged, object: nil)
    }

    func deleteProfile(_ id: UUID) {
        guard profiles.count > 1 else { return } // never delete the last one
        let wasActive = (id == activeID)
        profiles.removeAll { $0.id == id }
        Self.saveProfiles(profiles, defaults: defaults, key: kProfiles)

        // Best-effort: scrub namespaced UserDefaults keys and remove profile dir.
        for key in ProfileKeys.perProfile {
            defaults.removeObject(forKey: nsKey(key, for: id))
        }
        try? FileManager.default.removeItem(at: profileDir(id))

        if wasActive {
            setActive(profiles[0].id)
        }
        NotificationCenter.default.post(name: Self.listChanged, object: nil)
    }

    func setActive(_ id: UUID) {
        guard id != activeID, profiles.contains(where: { $0.id == id }) else { return }
        // Persist current AppLibrary state before switching (AppLibrary saves
        // on every mutation, so this is mostly defensive).
        activeID = id
        defaults.set(id.uuidString, forKey: kActive)
        NotificationCenter.default.post(name: Self.activeChanged, object: nil)
        // Trigger Preferences observers (dock window listens for this and re-lays out).
        NotificationCenter.default.post(name: Preferences.changed, object: nil)
    }

    // MARK: - Private

    private func uniqueName(_ base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "New Profile" : trimmed
        if !profiles.contains(where: { $0.name == candidate }) { return candidate }
        var i = 2
        while profiles.contains(where: { $0.name == "\(candidate) \(i)" }) { i += 1 }
        return "\(candidate) \(i)"
    }

    /// Copy all per-profile UserDefaults values + library.json from src to dst.
    private func duplicateProfileData(from src: UUID, to dst: UUID) {
        for key in ProfileKeys.perProfile {
            if let v = defaults.object(forKey: nsKey(key, for: src)) {
                defaults.set(v, forKey: nsKey(key, for: dst))
            }
        }
        let srcLib = libraryURL(for: src)
        let dstLib = libraryURL(for: dst)
        if FileManager.default.fileExists(atPath: srcLib.path) {
            try? FileManager.default.copyItem(at: srcLib, to: dstLib)
        }
    }

    /// On first launch with profiles support: migrate the existing (pre-profile)
    /// UserDefaults values and library.json into the default profile so the user
    /// sees their existing setup as "Default".
    private func migrateLegacyIfNeeded() {
        if defaults.bool(forKey: kDidMigrate) { return }
        defaults.set(true, forKey: kDidMigrate)

        let target = activeID
        // 1. Copy non-namespaced legacy UserDefaults values into namespace
        //    (only if namespaced value is missing — don't clobber).
        for key in ProfileKeys.perProfile {
            let ns = nsKey(key, for: target)
            if defaults.object(forKey: ns) != nil { continue }
            if let legacy = defaults.object(forKey: key) {
                defaults.set(legacy, forKey: ns)
            }
        }
        // 2. Move legacy library.json into the profile dir.
        let legacy = Self.legacyLibraryURL
        let dst = libraryURL(for: target)
        if FileManager.default.fileExists(atPath: legacy.path),
           !FileManager.default.fileExists(atPath: dst.path) {
            try? FileManager.default.moveItem(at: legacy, to: dst)
        }
    }

    /// For a freshly-created profile (not a duplicate), copy any legacy
    /// (non-namespaced) defaults so the profile inherits the user's current
    /// global settings as its starting point.
    private func seedDefaultsForProfile(_ id: UUID) {
        for key in ProfileKeys.perProfile {
            let ns = nsKey(key, for: id)
            if defaults.object(forKey: ns) != nil { continue }
            // Prefer current ACTIVE profile's value (most relevant), fall back to legacy.
            if let v = defaults.object(forKey: nsKey(key, for: activeID)) {
                defaults.set(v, forKey: ns)
            } else if let v = defaults.object(forKey: key) {
                defaults.set(v, forKey: ns)
            }
        }
    }

    // MARK: - List persistence

    private static func loadProfiles(defaults: UserDefaults, key: String) -> [ProfileMeta] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([ProfileMeta].self, from: data)
        else { return [] }
        return list
    }

    private static func saveProfiles(_ list: [ProfileMeta], defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: key)
        }
    }
}
