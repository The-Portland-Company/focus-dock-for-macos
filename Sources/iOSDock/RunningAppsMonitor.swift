import Foundation
import AppKit
import Combine

/// One running app that is NOT pinned in the user's library — surfaced into
/// the dock as an ephemeral tile (mirrors native macOS Dock behavior, which
/// always shows every running regular app).
struct RunningAppEntry: Identifiable, Equatable {
    let id: UUID
    let pid: pid_t
    let path: String
    let name: String
    let icon: NSImage

    static func == (lhs: RunningAppEntry, rhs: RunningAppEntry) -> Bool {
        lhs.id == rhs.id && lhs.pid == rhs.pid && lhs.path == rhs.path
    }
}

/// Publishes the list of regular running apps that aren't already pinned in
/// `AppLibrary.items`. Native macOS Dock parity: even apps the user hasn't
/// pinned should show up while they're running. Driven by NSWorkspace launch/
/// terminate notifications + a library-change subscription so refreshes are
/// cheap and event-driven (no timer).
final class RunningAppsMonitor: ObservableObject {
    static let shared = RunningAppsMonitor()

    @Published private(set) var apps: [RunningAppEntry] = []
    @Published private(set) var frontmostPath: String? = nil

    private var observers: [NSObjectProtocol] = []
    private var librarySubscription: AnyCancellable?
    private var idCache: [String: UUID] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func start() {
        refresh()
        updateFrontmost()
        let nc = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for n in names {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        // Pinning/unpinning an app should immediately re-partition the list.
        librarySubscription = AppLibrary.shared.$items.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    /// Bring the app to the front (or relaunch it if it was terminated between
    /// the publish and the tap). Mirrors a click on a native Dock running-app
    /// tile.
    func activate(_ entry: RunningAppEntry) {
        if let running = NSRunningApplication(processIdentifier: entry.pid),
           !running.isTerminated {
            running.activate(options: [.activateAllWindows])
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
    }

    private func refresh() {
        let pinnedPaths = pinnedAppPaths()
        var result: [RunningAppEntry] = []
        var seenPaths = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier > 0,
                  app.processIdentifier != ownPID,
                  let url = app.bundleURL else { continue }
            let path = url.resolvingSymlinksInPath().path
            if pinnedPaths.contains(path) { continue }
            // Don't duplicate the virtual Finder slot (always rendered separately).
            if path == "/System/Library/CoreServices/Finder.app" { continue }
            if !seenPaths.insert(path).inserted { continue }
            let key = path
            let id = idCache[key] ?? UUID()
            idCache[key] = id
            let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
            // Route through IconCache so the running-app tile gets the same
            // 256×256 rasterization as pinned items. NSRunningApplication.icon
            // hands back a 32×32 rep which SwiftUI upscales to a blurry mess.
            let icon = IconCache.shared.icon(for: path)
            result.append(RunningAppEntry(id: id, pid: app.processIdentifier, path: path, name: name, icon: icon))
        }
        idCache = idCache.filter { seenPaths.contains($0.key) }
        // Stable ordering by name so tiles don't jump around between refreshes.
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if result != apps { apps = result }
        updateFrontmost()
    }

    private func updateFrontmost() {
        if let front = NSWorkspace.shared.frontmostApplication,
           let url = front.bundleURL?.resolvingSymlinksInPath() {
            frontmostPath = url.path
        } else {
            frontmostPath = nil
        }
    }

    /// Returns true if the given (pinned or folder) app path is the currently frontmost application.
    func isAppActive(_ path: String) -> Bool {
        guard let f = frontmostPath else { return false }
        let normalized = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return normalized == f
    }

    func isFolderActive(_ folder: FolderEntry) -> Bool {
        folder.apps.contains { isAppActive($0.path) }
    }

    private func pinnedAppPaths() -> Set<String> {
        var out: Set<String> = []
        for item in AppLibrary.shared.items {
            switch item {
            case .app(let a):
                out.insert(URL(fileURLWithPath: a.path).resolvingSymlinksInPath().path)
            case .folder(let f):
                for a in f.apps {
                    out.insert(URL(fileURLWithPath: a.path).resolvingSymlinksInPath().path)
                }
            }
        }
        return out
    }
}
