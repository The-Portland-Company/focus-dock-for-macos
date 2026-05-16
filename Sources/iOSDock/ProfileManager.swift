import Foundation
import AppKit

// MARK: - Screen identity / assignment

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

enum ScreenIdentity {
    static func uuid(for screen: NSScreen) -> String? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(num.uint32Value)
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, cfUUID) as String
        }
        return String(displayID)
    }
    static func screen(forUUID uuid: String) -> NSScreen? {
        for s in NSScreen.screens where ScreenIdentity.uuid(for: s) == uuid { return s }
        return nil
    }
    static func displayName(for screen: NSScreen) -> String { screen.localizedName }
}

// MARK: - Models

/// A single dock window source. Has its own name, screen, settings
/// (UserDefaults namespace `dock.<id>.<key>`), and pinned items
/// (`FocusDock/docks/<id>/library.json`).
struct DockInstance: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var screen: ScreenAssignment = .allScreens

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

/// A named group of DockInstance IDs. Switching the active profile shows
/// every dock in this group and hides the rest. A profile may contain a
/// single dock (the common case after migration) or many.
struct Profile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var dockIDs: [UUID]
}

// MARK: - Per-dock UserDefaults key namespace

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
        "showRunningIndicators", "indicatorStyle", "showRecentApps",
        "fillWidth", "paddingUniform", "dockScale"
    ]
    static func isPerProfile(_ key: String) -> Bool { perProfile.contains(key) }
}

// MARK: - Manager

final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    // Notifications
    static let activeChanged = Notification.Name("FocusDock.ActiveProfileChanged")
    static let listChanged = Notification.Name("FocusDock.ProfilesListChanged")
    static let editingDockChanged = Notification.Name("FocusDock.EditingDockChanged")

    private let defaults = UserDefaults.standard
    // Storage keys
    private let kProfilesLegacy = "FocusDock.profiles.v1"
    private let kProfilesGroups = "FocusDock.profileGroups.v1"
    private let kDocks = "FocusDock.docks.v1"
    private let kActive = "FocusDock.activeProfile.v1"
    private let kEditingDock = "FocusDock.editingDock.v1"
    private let kDidMigrateLegacy = "FocusDock.profilesDidMigrateLegacy"
    private let kDidMigrateV2 = "FocusDock.profilesDidMigrateV2"

    @Published private(set) var docks: [DockInstance] = []
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var activeProfileID: UUID
    @Published private(set) var editingDockID: UUID

    init() {
        // 1. Load existing v2 storage, if any.
        var loadedDocks: [DockInstance] = Self.loadCodable(kDocks, defaults: defaults) ?? []
        var loadedProfiles: [Profile] = Self.loadCodable(kProfilesGroups, defaults: defaults) ?? []

        // 2. If v2 storage is empty, attempt migration from v1 (Phase-2 schema).
        if loadedProfiles.isEmpty || loadedDocks.isEmpty {
            let migrated = Self.migrateFromV1(defaults: defaults, legacyKey: kProfilesLegacy)
            if !migrated.profiles.isEmpty {
                loadedDocks = migrated.docks
                loadedProfiles = migrated.profiles
            }
        }

        // 3. If still empty, bootstrap a default.
        if loadedProfiles.isEmpty {
            let dock = DockInstance(id: UUID(), name: "Default")
            let profile = Profile(id: UUID(), name: "Default", dockIDs: [dock.id])
            loadedDocks = [dock]
            loadedProfiles = [profile]
        }

        self.docks = loadedDocks
        self.profiles = loadedProfiles

        Self.saveCodable(loadedDocks, key: kDocks, defaults: defaults)
        Self.saveCodable(loadedProfiles, key: kProfilesGroups, defaults: defaults)

        // 4. Active profile.
        let resolvedActive: UUID
        if let stored = defaults.string(forKey: kActive),
           let uuid = UUID(uuidString: stored),
           loadedProfiles.contains(where: { $0.id == uuid }) {
            resolvedActive = uuid
        } else {
            resolvedActive = loadedProfiles[0].id
            defaults.set(resolvedActive.uuidString, forKey: kActive)
        }

        // 5. Editing dock — defaults to active profile's first dock.
        let activeProfileObj = loadedProfiles.first(where: { $0.id == resolvedActive }) ?? loadedProfiles[0]
        let resolvedEditing: UUID
        if let stored = defaults.string(forKey: kEditingDock),
           let uuid = UUID(uuidString: stored),
           loadedDocks.contains(where: { $0.id == uuid }) {
            resolvedEditing = uuid
        } else {
            resolvedEditing = activeProfileObj.dockIDs.first ?? loadedDocks[0].id
            defaults.set(resolvedEditing.uuidString, forKey: kEditingDock)
        }
        self.activeProfileID = resolvedActive
        self.editingDockID = resolvedEditing

        // One-time legacy UserDefaults / library-file migration (pre-Phase-1 → v1).
        migrateLegacyPhase1IfNeeded()
        // One-time per-dock UserDefaults / library-file migration (v1 → v2).
        migrateV2IfNeeded()
        ensureDockDir(editingDockID)
    }

    // MARK: - Convenience

    var activeProfile: Profile {
        profiles.first(where: { $0.id == activeProfileID }) ?? profiles[0]
    }

    var editingDock: DockInstance {
        docks.first(where: { $0.id == editingDockID }) ?? docks[0]
    }

    func dock(id: UUID) -> DockInstance? { docks.first(where: { $0.id == id }) }
    func profile(id: UUID) -> Profile? { profiles.first(where: { $0.id == id }) }

    /// Docks that should currently be visible (members of the active profile).
    var activeDocks: [DockInstance] {
        activeProfile.dockIDs.compactMap { id in docks.first(where: { $0.id == id }) }
    }

    // MARK: - Paths / keys

    private static var rootDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var docksRootDir: URL {
        let dir = rootDir.appendingPathComponent("docks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var legacyLibraryURL: URL { rootDir.appendingPathComponent("library.json") }
    private static func legacyProfilesDir() -> URL { rootDir.appendingPathComponent("profiles", isDirectory: true) }
    private static func legacyProfileLibraryURL(for profileID: UUID) -> URL {
        legacyProfilesDir().appendingPathComponent(profileID.uuidString, isDirectory: true).appendingPathComponent("library.json")
    }

    func dockDir(_ id: UUID) -> URL {
        let dir = Self.docksRootDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func libraryURL(for dockID: UUID) -> URL {
        dockDir(dockID).appendingPathComponent("library.json")
    }
    func nsKey(_ key: String, for dockID: UUID) -> String { "dock." + dockID.uuidString + "." + key }
    func nsKey(_ key: String) -> String { nsKey(key, for: editingDockID) }
    private func ensureDockDir(_ id: UUID) { _ = dockDir(id) }

    // MARK: - Mutations: docks

    @discardableResult
    func addDock(name: String, in profileID: UUID? = nil, duplicateFrom sourceID: UUID? = nil, screen: ScreenAssignment = .allScreens) -> UUID {
        let newDock = DockInstance(id: UUID(), name: uniqueDockName(name), screen: screen)
        docks.append(newDock)
        Self.saveCodable(docks, key: kDocks, defaults: defaults)
        ensureDockDir(newDock.id)

        if let src = sourceID { copyDockData(from: src, to: newDock.id) }
        else { seedDockDefaults(newDock.id) }

        // Attach to the requested profile (or the active one).
        let targetProfile = profileID ?? activeProfileID
        if let idx = profiles.firstIndex(where: { $0.id == targetProfile }) {
            profiles[idx].dockIDs.append(newDock.id)
            Self.saveCodable(profiles, key: kProfilesGroups, defaults: defaults)
        }
        NotificationCenter.default.post(name: Self.listChanged, object: nil)
        if targetProfile == activeProfileID {
            NotificationCenter.default.post(name: Self.activeChanged, object: nil)
        }
        return newDock.id
    }

    func removeDock(_ id: UUID) {
        // Don't allow removing the last dock in the active profile.
        if let p = profiles.first(where: { $0.id == activeProfileID }),
           p.dockIDs == [id] { return }
        // Detach from every profile.
        for i in 0..<profiles.count {
            profiles[i].dockIDs.removeAll { $0 == id }
        }
        // Drop the orphan dock if no profile references it anymore.
        let stillReferenced = profiles.contains { $0.dockIDs.contains(id) }
        if !stillReferenced {
            docks.removeAll { $0.id == id }
            for key in ProfileKeys.perProfile { defaults.removeObject(forKey: nsKey(key, for: id)) }
            try? FileManager.default.removeItem(at: dockDir(id))
        }
        // If we deleted the editing target, pick another from active profile.
        if id == editingDockID {
            editingDockID = activeProfile.dockIDs.first ?? docks.first?.id ?? id
            defaults.set(editingDockID.uuidString, forKey: kEditingDock)
            NotificationCenter.default.post(name: Self.editingDockChanged, object: nil)
        }
        Self.saveCodable(docks, key: kDocks, defaults: defaults)
        Self.saveCodable(profiles, key: kProfilesGroups, defaults: defaults)
        NotificationCenter.default.post(name: Self.listChanged, object: nil)
        NotificationCenter.default.post(name: Self.activeChanged, object: nil)
    }

    func renameDock(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = docks.firstIndex(where: { $0.id == id }) else { return }
        docks[idx].name = trimmed
        Self.saveCodable(docks, key: kDocks, defaults: defaults)
        NotificationCenter.default.post(name: Self.listChanged, object: nil)
    }

    func setDockScreen(_ id: UUID, _ screen: ScreenAssignment) {
        guard let idx = docks.firstIndex(where: { $0.id == id }), docks[idx].screen != screen else { return }
        docks[idx].screen = screen
        Self.saveCodable(docks, key: kDocks, defaults: defaults)
        NotificationCenter.default.post(name: Self.listChanged, object: nil)
        // Affects layout if the dock is currently visible.
        if activeProfile.dockIDs.contains(id) {
            NotificationCenter.default.post(name: Self.activeChanged, object: nil)
        }
    }

    func setEditingDock(_ id: UUID) {
        guard id != editingDockID, docks.contains(where: { $0.id == id }) else { return }
        editingDockID = id
        defaults.set(id.uuidString, forKey: kEditingDock)
        NotificationCenter.default.post(name: Self.editingDockChanged, object: nil)
        // Pref/library singletons re-read for the new dock.
        NotificationCenter.default.post(name: Preferences.changed, object: nil)
    }

    // MARK: - Mutations: profiles (groups)

    @discardableResult
    func addProfile(name: String, duplicateFrom sourceID: UUID? = nil) -> UUID {
        let unique = uniqueProfileName(name)
        if let src = sourceID, let srcProfile = profiles.first(where: { $0.id == src }) {
            // Duplicate: clone every member dock.
            var newDockIDs: [UUID] = []
            for dockID in srcProfile.dockIDs {
                if let srcDock = docks.first(where: { $0.id == dockID }) {
                    let newID = UUID()
                    let cloned = DockInstance(id: newID, name: srcDock.name, screen: srcDock.screen)
                    docks.append(cloned)
                    ensureDockDir(newID)
                    copyDockData(from: srcDock.id, to: newID)
                    newDockIDs.append(newID)
                }
            }
            let new = Profile(id: UUID(), name: unique, dockIDs: newDockIDs)
            profiles.append(new)
            Self.saveCodable(docks, key: kDocks, defaults: defaults)
            Self.saveCodable(profiles, key: kProfilesGroups, defaults: defaults)
            NotificationCenter.default.post(name: Self.listChanged, object: nil)
            return new.id
        } else {
            // Fresh profile: seed with one new dock cloned from current editing dock so the
            // user gets a useful starting point (same look as their current setup).
            let newDockID = UUID()
            let newDock = DockInstance(id: newDockID, name: "Main", screen: .allScreens)
            docks.append(newDock)
            ensureDockDir(newDockID)
            copyDockData(from: editingDockID, to: newDockID)
            let new = Profile(id: UUID(), name: unique, dockIDs: [newDockID])
            profiles.append(new)
            Self.saveCodable(docks, key: kDocks, defaults: defaults)
            Self.saveCodable(profiles, key: kProfilesGroups, defaults: defaults)
            NotificationCenter.default.post(name: Self.listChanged, object: nil)
            return new.id
        }
    }

    func renameProfile(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].name = trimmed
        Self.saveCodable(profiles, key: kProfilesGroups, defaults: defaults)
        NotificationCenter.default.post(name: Self.listChanged, object: nil)
    }

    func deleteProfile(_ id: UUID) {
        guard profiles.count > 1 else { return }
        let wasActive = (id == activeProfileID)
        // Collect docks unique to this profile so we can drop their storage too.
        let p = profiles.first { $0.id == id }
        profiles.removeAll { $0.id == id }
        if let p {
            for dockID in p.dockIDs {
                let stillReferenced = profiles.contains { $0.dockIDs.contains(dockID) }
                if !stillReferenced {
                    docks.removeAll { $0.id == dockID }
                    for key in ProfileKeys.perProfile { defaults.removeObject(forKey: nsKey(key, for: dockID)) }
                    try? FileManager.default.removeItem(at: dockDir(dockID))
                }
            }
        }
        Self.saveCodable(docks, key: kDocks, defaults: defaults)
        Self.saveCodable(profiles, key: kProfilesGroups, defaults: defaults)

        if wasActive { setActiveProfile(profiles[0].id) }
        NotificationCenter.default.post(name: Self.listChanged, object: nil)
    }

    func setActiveProfile(_ id: UUID) {
        guard id != activeProfileID, profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        defaults.set(id.uuidString, forKey: kActive)
        // Editing target: prefer something inside the new active profile.
        let p = profiles.first { $0.id == id }!
        if !p.dockIDs.contains(editingDockID), let first = p.dockIDs.first {
            editingDockID = first
            defaults.set(first.uuidString, forKey: kEditingDock)
            NotificationCenter.default.post(name: Self.editingDockChanged, object: nil)
        }
        NotificationCenter.default.post(name: Self.activeChanged, object: nil)
        NotificationCenter.default.post(name: Preferences.changed, object: nil)
    }

    // MARK: - Naming helpers

    private func uniqueDockName(_ base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "New Dock" : trimmed
        if !docks.contains(where: { $0.name == candidate }) { return candidate }
        var i = 2
        while docks.contains(where: { $0.name == "\(candidate) \(i)" }) { i += 1 }
        return "\(candidate) \(i)"
    }

    private func uniqueProfileName(_ base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "New Profile" : trimmed
        if !profiles.contains(where: { $0.name == candidate }) { return candidate }
        var i = 2
        while profiles.contains(where: { $0.name == "\(candidate) \(i)" }) { i += 1 }
        return "\(candidate) \(i)"
    }

    private func copyDockData(from src: UUID, to dst: UUID) {
        for key in ProfileKeys.perProfile {
            if let v = defaults.object(forKey: nsKey(key, for: src)) {
                defaults.set(v, forKey: nsKey(key, for: dst))
            }
        }
        let srcLib = libraryURL(for: src)
        let dstLib = libraryURL(for: dst)
        if FileManager.default.fileExists(atPath: srcLib.path),
           !FileManager.default.fileExists(atPath: dstLib.path) {
            try? FileManager.default.copyItem(at: srcLib, to: dstLib)
        }
    }

    private func seedDockDefaults(_ id: UUID) {
        // Inherit from current editing dock so the new one starts familiar.
        for key in ProfileKeys.perProfile {
            let ns = nsKey(key, for: id)
            if defaults.object(forKey: ns) != nil { continue }
            if let v = defaults.object(forKey: nsKey(key, for: editingDockID)) {
                defaults.set(v, forKey: ns)
            } else if let v = defaults.object(forKey: key) {
                defaults.set(v, forKey: ns)
            }
        }
    }

    // MARK: - Migration

    /// V1 schema (Phase 1 & 2): each "profile" was a single dock. Promote it
    /// 1:1 into a Profile-group containing a single DockInstance with the same
    /// UUID — preserving every UserDefaults key (still namespaced by that UUID)
    /// and every library.json path (when we move them in `migrateV2IfNeeded`).
    private static func migrateFromV1(defaults: UserDefaults, legacyKey: String) -> (docks: [DockInstance], profiles: [Profile]) {
        guard let data = defaults.data(forKey: legacyKey),
              let legacy = try? JSONDecoder().decode([LegacyProfileMeta].self, from: data),
              !legacy.isEmpty
        else { return ([], []) }
        var docks: [DockInstance] = []
        var profiles: [Profile] = []
        for entry in legacy {
            let dock = DockInstance(id: entry.id, name: entry.name, screen: entry.screen ?? .allScreens)
            docks.append(dock)
            profiles.append(Profile(id: entry.id, name: entry.name, dockIDs: [entry.id]))
        }
        return (docks, profiles)
    }

    /// Pre-Phase-1 → Phase-1: copy un-namespaced UserDefaults values into the
    /// first dock's namespace, and move the legacy `library.json` into its
    /// dock folder. Idempotent.
    private func migrateLegacyPhase1IfNeeded() {
        if defaults.bool(forKey: kDidMigrateLegacy) { return }
        defaults.set(true, forKey: kDidMigrateLegacy)
        let target = docks.first?.id ?? editingDockID
        for key in ProfileKeys.perProfile {
            let ns = nsKey(key, for: target)
            if defaults.object(forKey: ns) != nil { continue }
            if let legacy = defaults.object(forKey: key) {
                defaults.set(legacy, forKey: ns)
            }
        }
        let legacy = Self.legacyLibraryURL
        let dst = libraryURL(for: target)
        if FileManager.default.fileExists(atPath: legacy.path),
           !FileManager.default.fileExists(atPath: dst.path) {
            try? FileManager.default.moveItem(at: legacy, to: dst)
        }
    }

    /// V1 → V2: each old `profile.<uuid>.<key>` becomes `dock.<uuid>.<key>` and
    /// the file at `profiles/<uuid>/library.json` moves to `docks/<uuid>/library.json`.
    /// Same UUIDs are used so no re-keying is required, just renaming.
    private func migrateV2IfNeeded() {
        if defaults.bool(forKey: kDidMigrateV2) { return }
        defaults.set(true, forKey: kDidMigrateV2)
        for dock in docks {
            // UserDefaults rename.
            for key in ProfileKeys.perProfile {
                let oldKey = "profile." + dock.id.uuidString + "." + key
                let newKey = nsKey(key, for: dock.id)
                if let v = defaults.object(forKey: oldKey), defaults.object(forKey: newKey) == nil {
                    defaults.set(v, forKey: newKey)
                    defaults.removeObject(forKey: oldKey)
                }
            }
            // Library file move.
            let oldLib = Self.legacyProfileLibraryURL(for: dock.id)
            let newLib = libraryURL(for: dock.id)
            if FileManager.default.fileExists(atPath: oldLib.path),
               !FileManager.default.fileExists(atPath: newLib.path) {
                try? FileManager.default.moveItem(at: oldLib, to: newLib)
            }
        }
        // Best-effort: remove the now-empty legacy profiles directory.
        try? FileManager.default.removeItem(at: Self.legacyProfilesDir())
    }

    // MARK: - Codable storage helpers

    private static func loadCodable<T: Decodable>(_ key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private static func saveCodable<T: Encodable>(_ value: T, key: String, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    // Pre-Phase-3 ProfileMeta — used only for migration. Mirrors the Codable
    // shape that v1 ProfileManager wrote (with tolerant `screen` decoding).
    private struct LegacyProfileMeta: Codable {
        var id: UUID
        var name: String
        var screen: ScreenAssignment?
        enum CodingKeys: String, CodingKey { case id, name, screen }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(UUID.self, forKey: .id)
            self.name = try c.decode(String.self, forKey: .name)
            self.screen = try? c.decode(ScreenAssignment.self, forKey: .screen)
        }
    }
}
