import Foundation
import AppKit
import SwiftUI

/// A dock item is either a single app or a folder of apps.
enum DockItem: Identifiable, Equatable {
    case app(AppEntry)
    case folder(FolderEntry)

    var id: UUID {
        switch self {
        case .app(let a): return a.id
        case .folder(let f): return f.id
        }
    }
}

struct AppEntry: Identifiable, Equatable, Codable {
    var id = UUID()
    var path: String
    var name: String

    var url: URL { URL(fileURLWithPath: path) }
    var icon: NSImage { IconCache.shared.icon(for: path) }
}

/// Caches high-resolution app icons so SwiftUI never upscales a tiny rep.
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]
    private let renderSize: CGFloat = 256

    func icon(for path: String) -> NSImage {
        let trashPath = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
        let isTrash = path == trashPath
        if !isTrash, let cached = cache[path] { return cached }
        let raw = rawIcon(for: path)
        let img = NSImage(size: NSSize(width: renderSize, height: renderSize))
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        raw.draw(in: NSRect(x: 0, y: 0, width: renderSize, height: renderSize),
                 from: .zero, operation: .sourceOver, fraction: 1.0)
        img.unlockFocus()
        if !isTrash { cache[path] = img }
        return img
    }

    /// Resolve the raw NSImage for a path. The user's Trash gets the native
    /// trash-bin icon (empty/full) rather than the generic folder icon that
    /// NSWorkspace returns for `~/.Trash`.
    private func rawIcon(for path: String) -> NSImage {
        let trashPath = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
        if path == trashPath {
            // AppKit doesn't actually publish "NSTrashEmpty"/"NSTrashFull" as
            // distinct named images on modern macOS — both fall back to the
            // same generic icon. The canonical empty/full bin icons live in
            // CoreTypes.bundle (these are what Finder & the system Dock use).
            //
            // Emptiness state is maintained by `TrashWatcher` because
            // ~/.Trash is TCC-protected — direct filesystem reads return
            // EPERM without Full Disk Access.
            let icns = AppLibrary.shared.trashIsEmpty
                ? "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/TrashIcon.icns"
                : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FullTrashIcon.icns"
            if let img = NSImage(contentsOfFile: icns) { return img }
        }
        return NSWorkspace.shared.icon(forFile: path)
    }
}

struct FolderEntry: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    var apps: [AppEntry]
    var columns: Int? = nil
}

/// Used to deep-link from a dock folder popover into Settings → Apps with that
/// folder selected/expanded.
enum SettingsRouter {
    static let openFolder = Notification.Name("FocusDock.OpenFolderInSettings")
}

/// Runtime-only badge state for a single app. Keyed by app name (lowercased)
/// because the macOS Dock AX tree exposes apps by display name, not bundle path.
struct AppBadgeState: Equatable {
    var badgeCount: String?
    var needsAttention: Bool
}

final class AppLibrary: ObservableObject {
    static let shared = AppLibrary()

    @Published var items: [DockItem] = [] {
        didSet { save() }
    }

    /// Runtime badge state keyed by lowercased app name. Populated by
    /// `BadgeMonitor` on the main thread. Not persisted.
    @Published var badgeStates: [String: AppBadgeState] = [:]

    /// Set by `TrashWatcher` (which polls Finder via AppleScript, because
    /// `~/.Trash` is TCC-protected and direct filesystem reads return EPERM).
    /// `nil` means we haven't been able to determine state yet — treat as empty
    /// for icon purposes.
    @Published var trashIsEmpty: Bool = true

    func badgeState(for appName: String) -> AppBadgeState? {
        badgeStates[appName.lowercased()]
    }

    private var storageURL: URL {
        ProfileManager.shared.libraryURL(for: ProfileManager.shared.activeID)
    }

    private var suppressSave: Bool = false

    init() {
        // Ensure ProfileManager has run its bootstrap + legacy migration first
        // so storageURL points at the active profile's library.json.
        _ = ProfileManager.shared
        load()
        if items.isEmpty { seedDefaults() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleActiveProfileChanged),
            name: ProfileManager.activeChanged, object: nil)
    }

    @objc private func handleActiveProfileChanged() {
        // Load the new profile's items without triggering save() (didSet) which
        // would write the new profile's data into… the new profile's file. That's
        // actually fine, but we avoid pointless I/O.
        suppressSave = true
        items = []
        load()
        if items.isEmpty { seedDefaults() }
        suppressSave = false
    }

    // MARK: - Persistence
    private struct PersistedItem: Codable {
        var kind: String
        var app: AppEntry?
        var folder: FolderEntry?
    }

    private func save() {
        if suppressSave { return }
        let persisted: [PersistedItem] = items.map { item in
            switch item {
            case .app(let a): return PersistedItem(kind: "app", app: a, folder: nil)
            case .folder(let f): return PersistedItem(kind: "folder", app: nil, folder: f)
            }
        }
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: storageURL)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let persisted = try? JSONDecoder().decode([PersistedItem].self, from: data) else { return }
        items = persisted.compactMap { p in
            switch p.kind {
            case "app": return p.app.map { .app($0) }
            case "folder": return p.folder.map { .folder($0) }
            default: return nil
            }
        }
    }

    private func seedDefaults() {
        // Prefer the user's actual system Dock contents.
        let cloned = SystemDockManager.readSystemDockApps()
        let paths = cloned.isEmpty ? [
            "/System/Applications/Launchpad.app",
            "/System/Applications/Safari.app",
            "/System/Applications/Messages.app",
            "/System/Applications/Mail.app",
            "/System/Applications/Notes.app",
            "/System/Applications/Calendar.app",
            "/System/Applications/System Settings.app",
            "/System/Applications/App Store.app"
        ] : cloned
        items = paths.compactMap { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            return .app(AppEntry(path: path, name: name))
        }
    }

    // MARK: - Mutations

    func addApp(at path: String) {
        let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        items.append(.app(AppEntry(path: path, name: name)))
    }

    func removeItem(id: UUID) {
        items.removeAll { $0.id == id }
    }

    func launch(_ app: AppEntry) {
        NSWorkspace.shared.open(URL(fileURLWithPath: app.path))
    }

    /// Combine two top-level items: if both apps, create a new folder; if target is folder, drop the app in; etc.
    func combine(dragged draggedID: UUID, into targetID: UUID) {
        guard draggedID != targetID,
              let draggedIdx = items.firstIndex(where: { $0.id == draggedID }),
              let targetIdx = items.firstIndex(where: { $0.id == targetID })
        else { return }

        let dragged = items[draggedIdx]
        let target = items[targetIdx]

        switch (dragged, target) {
        case (.app(let dApp), .app(let tApp)):
            let folder = FolderEntry(name: "Folder", apps: [tApp, dApp])
            // Replace target with folder, then remove dragged.
            items[targetIdx] = .folder(folder)
            items.removeAll { $0.id == dApp.id }
        case (.app(let dApp), .folder(var tFolder)):
            tFolder.apps.append(dApp)
            items[targetIdx] = .folder(tFolder)
            items.removeAll { $0.id == dApp.id }
        case (.folder(let dFolder), .app(let tApp)):
            var merged = dFolder
            merged.apps.insert(tApp, at: 0)
            items[targetIdx] = .folder(merged)
            items.removeAll { $0.id == dFolder.id }
        case (.folder(let dFolder), .folder(var tFolder)):
            tFolder.apps.append(contentsOf: dFolder.apps)
            items[targetIdx] = .folder(tFolder)
            items.removeAll { $0.id == dFolder.id }
        }
    }

    /// Find which top-level folder (if any) currently contains an app.
    func folder(containing appID: UUID) -> FolderEntry? {
        for case .folder(let f) in items where f.apps.contains(where: { $0.id == appID }) {
            return f
        }
        return nil
    }

    /// Remove an app from wherever it currently lives in the tree.
    private func detachApp(_ appID: UUID) -> AppEntry? {
        // Top level?
        if let idx = items.firstIndex(where: { $0.id == appID }), case .app(let a) = items[idx] {
            items.remove(at: idx)
            return a
        }
        // Inside a folder?
        for i in 0..<items.count {
            if case .folder(var f) = items[i], let ai = f.apps.firstIndex(where: { $0.id == appID }) {
                let a = f.apps.remove(at: ai)
                if f.apps.isEmpty {
                    items.remove(at: i)
                } else {
                    items[i] = .folder(f)
                }
                return a
            }
        }
        return nil
    }

    func moveApp(_ appID: UUID, intoFolder folderID: UUID) {
        guard let app = detachApp(appID) else { return }
        guard let i = items.firstIndex(where: { $0.id == folderID }), case .folder(var f) = items[i] else {
            // Folder is gone — re-attach at top level as a fallback.
            items.append(.app(app)); return
        }
        f.apps.append(app)
        items[i] = .folder(f)
    }

    func moveAppToTopLevel(_ appID: UUID, at index: Int? = nil) {
        guard let app = detachApp(appID) else { return }
        if let idx = index, idx >= 0, idx <= items.count {
            items.insert(.app(app), at: idx)
        } else {
            items.append(.app(app))
        }
    }

    func renameFolder(_ folderID: UUID, to name: String) {
        guard let i = items.firstIndex(where: { $0.id == folderID }), case .folder(var f) = items[i] else { return }
        f.name = name
        items[i] = .folder(f)
    }

    func setFolderColumns(_ folderID: UUID, columns: Int?) {
        guard let i = items.firstIndex(where: { $0.id == folderID }), case .folder(var f) = items[i] else { return }
        f.columns = columns
        items[i] = .folder(f)
    }

    func reorder(dragged draggedID: UUID, toIndex newIndex: Int) {
        guard let oldIndex = items.firstIndex(where: { $0.id == draggedID }) else { return }
        let clamped = max(0, min(newIndex, items.count - 1))
        if oldIndex == clamped { return }
        let item = items.remove(at: oldIndex)
        items.insert(item, at: clamped)
    }
}
