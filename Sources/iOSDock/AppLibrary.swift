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
    private var trashEmptyImage: NSImage?
    private var trashFullImage: NSImage?
    private let renderSize: CGFloat = 256

    func clearTrashEmpty() { trashEmptyImage = nil }
    func clearTrashFull()  { trashFullImage = nil }

    func icon(for path: String) -> NSImage {
        let trashPath = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
        let isTrash = path == trashPath

        if isTrash {
            let isEmpty = AppLibrary.shared.trashIsEmpty
            if isEmpty, let cached = trashEmptyImage { return cached }
            if !isEmpty, let cached = trashFullImage { return cached }
        } else if let cached = cache[path] {
            return cached
        }

        let raw = rawIcon(for: path)
        let img = NSImage(size: NSSize(width: renderSize, height: renderSize))
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        raw.draw(in: NSRect(x: 0, y: 0, width: renderSize, height: renderSize),
                 from: .zero, operation: .sourceOver, fraction: 1.0)
        img.unlockFocus()

        if isTrash {
            if AppLibrary.shared.trashIsEmpty {
                trashEmptyImage = img
            } else {
                trashFullImage = img
            }
        } else {
            cache[path] = img
        }
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

/// A user-inserted visual divider bar (bubble/pill) that splits the dock into
/// organized sections. Persisted per-dock alongside items. Visual only (no
/// drag-and-drop barrier behavior yet).
struct DockDividerBar: Identifiable, Equatable, Codable {
    var id = UUID()
    /// If non-nil, this divider appears immediately after the DockItem with this ID
    /// in the pinned list. If nil, it appears at the very start of the user items
    /// (before Finder if shown).
    var afterItemID: UUID? = nil
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
    /// Posted whenever any AppLibrary instance saves to disk. `object` is the
    /// dockID (`UUID`) whose library was written. Other instances bound to the
    /// same dockID reload from disk in response.
    static let libraryChanged = Notification.Name("FocusDock.LibraryChanged")

    /// The singleton edits the **currently-selected dock** (the one shown in
    /// Settings → General/Apps). Per-dock instances are owned by each
    /// `DockWindowController`.
    static let shared = AppLibrary()

    /// When non-nil, this instance is pinned to a specific dock's items file.
    /// Nil tracks `ProfileManager.editingDockID` dynamically.
    let dockID: UUID?

    @Published var items: [DockItem] = [] {
        didSet { save() }
    }

    /// User-inserted visual divider bars. Changes trigger save (which writes
    /// both items + dividers to the same library.json for the dock).
    @Published var dividers: [DockDividerBar] = [] {
        didSet { save() }
    }

    @Published var badgeStates: [String: AppBadgeState] = [:]
    @Published var trashIsEmpty: Bool = true {
        didSet {
            // When the state flips, clear the now-stale cached image for the *other* state
            // so the next icon request renders the correct version.
            if trashIsEmpty {
                IconCache.shared.clearTrashFull()
            } else {
                IconCache.shared.clearTrashEmpty()
            }
        }
    }

    func badgeState(for appName: String) -> AppBadgeState? {
        badgeStates[appName.lowercased()]
    }

    // MARK: - Trash actions (used by dock Trash icon pill, context menu, and settings)

    func openTrash() {
        let trashURL = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".Trash"))
        NSWorkspace.shared.open(trashURL)
    }

    /// Direct (no alert) empty via AppleScript + update state. Used by the
    /// compact "Empty" pill and the right-click context menu on the Trash icon.
    func emptyTrashDirectly() {
        let script = "tell application \"Finder\" to empty the trash"
        if let appleScript = NSAppleScript(source: script) {
            _ = appleScript.executeAndReturnError(nil)
            DispatchQueue.main.async {
                self.trashIsEmpty = true
            }
        }
    }

    /// Called when user drags an app from Finder onto the dock.
    /// Supports dropping .app bundles from /Applications or elsewhere.
    func addDroppedItem(from url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        let path = resolved.path

        guard resolved.pathExtension.lowercased() == "app" else { return }

        // Avoid duplicates
        if items.contains(where: { item in
            if case .app(let a) = item { return a.path == path }
            return false
        }) { return }

        let name = resolved.deletingPathExtension().lastPathComponent
        let entry = AppEntry(id: UUID(), path: path, name: name)
        items.append(.app(entry))
        save()
    }

    func emptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Empty Trash?"
        alert.informativeText = "Are you sure you want to permanently erase the items in the Trash?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            let script = """
            tell application "Finder"
                empty trash
            end tell
            """
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
                if error == nil {
                    DispatchQueue.main.async {
                        self.trashIsEmpty = true
                    }
                }
            }
        }
    }

    private var activeDockID: UUID { dockID ?? ProfileManager.shared.editingDockID }

    private var storageURL: URL {
        ProfileManager.shared.libraryURL(for: activeDockID)
    }

    private var suppressSave: Bool = false

    convenience init(dockID: UUID) { self.init(boundDockID: dockID) }

    private convenience init() { self.init(boundDockID: nil) }

    private init(boundDockID: UUID?) {
        _ = ProfileManager.shared
        self.dockID = boundDockID
        load()
        if items.isEmpty { seedDefaults() }

        if boundDockID == nil {
            // Singleton: swap source when the editing target changes.
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleEditingDockChanged),
                name: ProfileManager.editingDockChanged, object: nil)
        }
        // Reload when any sibling instance writes to the same dock's file.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleLibraryChanged(_:)),
            name: AppLibrary.libraryChanged, object: nil)
    }

    @objc private func handleEditingDockChanged() {
        suppressSave = true
        items = []
        load()
        if items.isEmpty { seedDefaults() }
        suppressSave = false
    }

    @objc private func handleLibraryChanged(_ note: Notification) {
        guard let writtenID = note.object as? UUID else { return }
        guard writtenID == activeDockID else { return }
        // Don't bounce our own write back at us.
        if note.userInfo?["source"] as? ObjectIdentifier == ObjectIdentifier(self) { return }
        suppressSave = true
        load()
        suppressSave = false
    }

    // MARK: - Persistence
    private struct PersistedItem: Codable {
        var kind: String
        var app: AppEntry?
        var folder: FolderEntry?
    }

    /// New persisted container (v2+) that holds both pinned items and user
    /// divider bars. Old saves were a bare array of PersistedItem; we still
    /// read those for backward compatibility.
    private struct PersistedLibrary: Codable {
        var items: [PersistedItem]
        var dividers: [DockDividerBar] = []
    }

    private func save() {
        if suppressSave { return }
        let writtenDockID = activeDockID
        let itemPersisted: [PersistedItem] = items.map { item in
            switch item {
            case .app(let a): return PersistedItem(kind: "app", app: a, folder: nil)
            case .folder(let f): return PersistedItem(kind: "folder", app: nil, folder: f)
            }
        }
        let container = PersistedLibrary(items: itemPersisted, dividers: dividers)
        if let data = try? JSONEncoder().encode(container) {
            try? data.write(to: storageURL)
        }
        NotificationCenter.default.post(
            name: AppLibrary.libraryChanged,
            object: writtenDockID,
            userInfo: ["source": ObjectIdentifier(self)]
        )
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }

        // Try new container format first.
        if let container = try? JSONDecoder().decode(PersistedLibrary.self, from: data) {
            items = container.items.compactMap { p in
                switch p.kind {
                case "app": return p.app.map { .app($0) }
                case "folder": return p.folder.map { .folder($0) }
                default: return nil
                }
            }
            dividers = container.dividers
            return
        }

        // Backward compat: bare array of PersistedItem (pre-divider era).
        if let oldItems = try? JSONDecoder().decode([PersistedItem].self, from: data) {
            items = oldItems.compactMap { p in
                switch p.kind {
                case "app": return p.app.map { .app($0) }
                case "folder": return p.folder.map { .folder($0) }
                default: return nil
                }
            }
            dividers = []
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
        // Clean any divider that was placed after the removed item.
        dividers.removeAll { $0.afterItemID == id }
    }

    func launch(_ app: AppEntry) {
        NSWorkspace.shared.open(URL(fileURLWithPath: app.path))
    }

    // MARK: - Divider helpers (used by Edit Dock mode)

    /// Insert a new visual divider bar after the given item (or at the start if after == nil).
    func insertDivider(after afterID: UUID?) {
        let d = DockDividerBar(afterItemID: afterID)
        // Avoid exact duplicates at same spot (simple guard).
        if !dividers.contains(where: { $0.afterItemID == afterID }) {
            dividers.append(d)
        } else {
            dividers.append(d) // allow stacking multiple dividers if user wants
        }
    }

    func removeDivider(id: UUID) {
        dividers.removeAll { $0.id == id }
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
