import Foundation

/// User-assigned names for Spaces, keyed by space uuid (uuids are stable
/// across reorder and reboot). Persisted in UserDefaults under a single
/// global key — deliberately NOT per-profile (no `pk()` resolution): desktop
/// names belong to the machine, not to a dock profile.
final class SpaceNameStore {
    static let shared = SpaceNameStore()

    private let defaults: UserDefaults
    private let key = "spaceNames"
    /// Names are tiny; only prune once the dict outgrows this, so names for
    /// temporarily-removed desktops survive normal churn.
    private let pruneThreshold = 100

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var names: [String: String] {
        get {
            guard let raw = defaults.dictionary(forKey: key) else { return [:] }
            return raw.compactMapValues { $0 as? String }
        }
        set { defaults.set(newValue, forKey: key) }
    }

    /// The user's name for the space, or "Desktop N" when none is stored.
    func name(for uuid: String, defaultNumber: Int) -> String {
        if let stored = names[uuid], !stored.isEmpty { return stored }
        return "Desktop \(defaultNumber)"
    }

    /// Stores a trimmed custom name. Setting an empty/whitespace-only name
    /// deletes the entry so the space falls back to its default "Desktop N".
    func setName(_ name: String, for uuid: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var dict = names
        if trimmed.isEmpty {
            dict.removeValue(forKey: uuid)
        } else {
            dict[uuid] = trimmed
        }
        names = dict
    }

    /// Drops entries for uuids no longer present — but only once the dict
    /// exceeds the threshold, so names aren't lost to transient layouts.
    func pruneIfNeeded(keeping liveUUIDs: Set<String>) {
        let dict = names
        guard dict.count > pruneThreshold else { return }
        names = dict.filter { liveUUIDs.contains($0.key) }
    }
}
