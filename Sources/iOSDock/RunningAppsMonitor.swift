import Foundation
import AppKit
import ApplicationServices
import Combine
import os

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

/// Lightweight state describing whether a pinned (or folder-contained) app path
/// has one or more running processes, and whether it is currently the frontmost
/// application. Used to drive differentiated subtle vs. strong glows (or dots
/// vs. underlines in classic indicator mode).
struct AppRunningState: Equatable {
    let isRunning: Bool
    let isFrontmost: Bool
}

/// Publishes the list of regular running apps that aren't already pinned in
/// `AppLibrary.items`. Native macOS Dock parity: even apps the user hasn't
/// pinned should show up while they're running. Driven by NSWorkspace launch/
/// terminate notifications + a library-change subscription so refreshes are
/// cheap and event-driven (no timer).
final class RunningAppsMonitor: ObservableObject {
    static let shared = RunningAppsMonitor()
    private static let log = Logger(subsystem: "com.theportlandcompany.FocusDock", category: "RunningApps")

    @Published private(set) var apps: [RunningAppEntry] = []
    @Published private(set) var frontmostPath: String? = nil
    /// All paths (normalized) of currently running regular apps (Finder, pinned, and
    /// ephemeral). Used for fast isAppRunning checks and to trigger dock re-renders
    /// when a pinned app launches or quits.
    @Published private(set) var runningAppPaths: Set<String> = []

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
    /// tile — including unminimizing a window (genie effect) when all of the
    /// app's windows are currently minimized.
    func activate(_ entry: RunningAppEntry) {
        Self.log.info("activate \(entry.name, privacy: .public) pid=\(entry.pid)")
        let url = URL(fileURLWithPath: entry.path)

        guard let running = NSRunningApplication(processIdentifier: entry.pid),
              !running.isTerminated else {
            Self.log.info("relaunching \(entry.name, privacy: .public) (terminated)")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            return
        }

        running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        // Native-dock parity: if every window is minimized, restore the most
        // recently minimized one with a genie effect. AXMinimized=false is
        // what triggers the system animation.
        let axApp = AXUIElementCreateApplication(entry.pid)
        guard let axWindows = copyAXAttribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else {
            Self.log.info("no AX windows for \(entry.name, privacy: .public) — accessibility denied?")
            return
        }
        var minimizedWindows: [AXUIElement] = []
        var hasVisibleWindow = false
        for w in axWindows {
            let isMin = (copyAXAttribute(w, kAXMinimizedAttribute) as? Bool) ?? false
            if isMin {
                minimizedWindows.append(w)
            } else {
                hasVisibleWindow = true
            }
        }
        Self.log.info("\(entry.name, privacy: .public) windows visible=\(hasVisibleWindow) minimized=\(minimizedWindows.count)")
        if !hasVisibleWindow, let target = minimizedWindows.first {
            let setErr = AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(target, kAXRaiseAction as CFString)
            Self.log.info("unminimize result=\(setErr.rawValue) for \(entry.name, privacy: .public)")
            // Re-activate so we end up frontmost after the genie completes.
            running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }

    private func copyAXAttribute(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(el, attr as CFString, &value)
        return err == .success ? value : nil
    }

    private func refresh() {
        let pinnedPaths = pinnedAppPaths()
        var result: [RunningAppEntry] = []
        var seenPaths = Set<String>()
        var allRunningPaths: Set<String> = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier > 0,
                  app.processIdentifier != ownPID,
                  let url = app.bundleURL else { continue }
            let path = url.resolvingSymlinksInPath().path
            allRunningPaths.insert(path)
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
        if allRunningPaths != runningAppPaths { runningAppPaths = allRunningPaths }
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

    private func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Returns the running + frontmost state for a single app path (used by both
    /// main dock items and ephemeral running-app tiles).
    func runningState(for path: String) -> AppRunningState {
        let norm = normalized(path)
        let fm = frontmostPath
        let isFM = (fm != nil && norm == fm)
        let isRun = runningAppPaths.contains(norm) || isFM
        return AppRunningState(isRunning: isRun, isFrontmost: isFM)
    }

    /// Returns the aggregate running + frontmost state for a folder (any contained
    /// app running → subtle; the frontmost app inside → strong glow/underline).
    func runningState(for folder: FolderEntry) -> AppRunningState {
        var hasRun = false
        var hasFM = false
        for a in folder.apps {
            let st = runningState(for: a.path)
            if st.isFrontmost { hasFM = true; hasRun = true; break }
            if st.isRunning { hasRun = true }
        }
        return AppRunningState(isRunning: hasRun, isFrontmost: hasFM)
    }

    /// Legacy wrapper retained for compatibility during transition.
    func isAppActive(_ path: String) -> Bool {
        runningState(for: path).isFrontmost
    }

    func isFolderActive(_ folder: FolderEntry) -> Bool {
        runningState(for: folder).isFrontmost
    }

    /// Convenience: true when the path has at least one running process.
    func isAppRunning(_ path: String) -> Bool {
        runningState(for: path).isRunning
    }

    func folderHasRunningApps(_ folder: FolderEntry) -> Bool {
        runningState(for: folder).isRunning
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
