import Foundation
import AppKit
import ApplicationServices

// Private SPI: bridges an AX window element to its CGWindowID. Stable across
// macOS 12–15 and used by every dock replacement on the platform. The symbol
// lives in HIServices but isn't exported in the public headers.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ axUiElement: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

// CGWindowListCreateImage was marked unavailable in the Swift overlay starting
// macOS 14 (Apple's preferred path is ScreenCaptureKit, which is async and
// requires Screen Recording permission). The C symbol still ships and works,
// so we re-import it under a fresh name to bypass the Swift availability
// gate. We use it only to snapshot the last-visible frame of a window we're
// about to lose to minimization — no continuous screen capture.
@_silgen_name("CGWindowListCreateImage")
private func _CGWindowListCreateImage(_ screenBounds: CGRect,
                                       _ listOption: CGWindowListOption,
                                       _ windowID: CGWindowID,
                                       _ imageOption: CGWindowImageOption) -> Unmanaged<CGImage>?

/// One minimized window, surfaced into the dock as a tile in the protected
/// right-side section. Has a UUID stable across renders so SwiftUI's ForEach
/// identity is preserved while the window is still minimized.
struct MinimizedWindow: Identifiable, Equatable {
    let id: UUID
    let cgWindowID: CGWindowID
    let pid: pid_t
    let appName: String
    let appIcon: NSImage
    let title: String
    let preview: NSImage?

    static func == (lhs: MinimizedWindow, rhs: MinimizedWindow) -> Bool {
        lhs.id == rhs.id && lhs.cgWindowID == rhs.cgWindowID && lhs.title == rhs.title
    }
}

/// Polls Accessibility for minimized windows of every regular running app and
/// publishes the list. Captures a last-visible CGWindow image just before a
/// window is hidden, so the tile shows a real thumbnail rather than just the
/// app icon. Requires Accessibility permission; gracefully no-ops if denied
/// (BadgeMonitor already drives the system permission prompt).
final class MinimizedMonitor: ObservableObject {
    static let shared = MinimizedMonitor()

    @Published private(set) var windows: [MinimizedWindow] = []

    private var timer: Timer?
    private let pollInterval: TimeInterval = 1.5
    // Stable UUID per (pid, cgWindowID) so SwiftUI keeps view identity across ticks.
    private var idCache: [String: UUID] = [:]
    // Last-visible bitmap per cgWindowID, refreshed each tick while the window
    // is on-screen. When the window flips to minimized, the cached image is
    // surfaced as the preview.
    private var lastVisibleImage: [CGWindowID: NSImage] = [:]
    private let ownPID: pid_t = ProcessInfo.processInfo.processIdentifier

    func start() {
        stop()
        tick()
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Restore the window: clear AXMinimized, then activate the app so the
    /// window comes to the front. Mirrors a click on a native dock genie tile.
    func unminimize(_ window: MinimizedWindow) {
        // Let MinimizeAnimator run the reverse fly-out animation and restore
        // the window's CGS alpha (set to 0 at minimize time so the OS
        // animation played invisibly).
        MinimizeAnimator.shared.willUnminimize(window)
        let axApp = AXUIElementCreateApplication(window.pid)
        guard let axWindows = copyAttribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else { return }
        for w in axWindows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(w, &wid) == .success, wid == window.cgWindowID {
                AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                if let running = NSRunningApplication(processIdentifier: window.pid) {
                    running.activate(options: [.activateAllWindows])
                }
                return
            }
        }
    }

    // MARK: - Polling

    private func tick() {
        guard AXIsProcessTrusted() else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let (minimized, visibleImagesToCache) = self.scan()
            DispatchQueue.main.async {
                // Cache visible-window bitmaps so we have something to show when
                // they minimize on a future tick.
                for (wid, img) in visibleImagesToCache {
                    self.lastVisibleImage[wid] = img
                }
                // Drop cache entries for windows that no longer exist.
                let liveIDs = Set(visibleImagesToCache.keys).union(minimized.map { $0.cgWindowID })
                self.lastVisibleImage = self.lastVisibleImage.filter { liveIDs.contains($0.key) }
                self.windows = minimized
            }
        }
    }

    private func scan() -> (minimized: [MinimizedWindow], visibleImages: [CGWindowID: NSImage]) {
        var minimized: [MinimizedWindow] = []
        var visibleImages: [CGWindowID: NSImage] = [:]

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier > 0,
                  app.processIdentifier != ownPID else { continue }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let axWindows = copyAttribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else { continue }

            for w in axWindows {
                var wid: CGWindowID = 0
                guard _AXUIElementGetWindow(w, &wid) == .success, wid != 0 else { continue }

                let isMinimized = (copyAttribute(w, kAXMinimizedAttribute) as? Bool) ?? false
                let title = (copyAttribute(w, kAXTitleAttribute) as? String) ?? (app.localizedName ?? "")

                if isMinimized {
                    let key = "\(app.processIdentifier):\(wid)"
                    let id = idCache[key] ?? {
                        let new = UUID()
                        idCache[key] = new
                        return new
                    }()
                    let preview = lastVisibleImage[wid] ?? captureWindow(id: wid)
                    let appIcon = app.icon ?? NSWorkspace.shared.icon(forFile: app.bundleURL?.path ?? "")
                    minimized.append(MinimizedWindow(
                        id: id,
                        cgWindowID: wid,
                        pid: app.processIdentifier,
                        appName: app.localizedName ?? "",
                        appIcon: appIcon,
                        title: title,
                        preview: preview
                    ))
                } else {
                    // Refresh the cached bitmap while the window is visible so
                    // the eventual minimization has a thumbnail ready.
                    if let img = captureWindow(id: wid) {
                        visibleImages[wid] = img
                    }
                }
            }
        }

        // Drop stale id-cache entries for windows that disappeared.
        let liveKeys = Set(minimized.map { "\($0.pid):\($0.cgWindowID)" })
        idCache = idCache.filter { liveKeys.contains($0.key) }
        return (minimized, visibleImages)
    }

    private func captureWindow(id: CGWindowID) -> NSImage? {
        let opts: CGWindowImageOption = [.boundsIgnoreFraming, .nominalResolution]
        guard let cgRef = _CGWindowListCreateImage(.null, .optionIncludingWindow, id, opts) else { return nil }
        let cg = cgRef.takeRetainedValue()
        let size = NSSize(width: cg.width, height: cg.height)
        guard size.width > 1, size.height > 1 else { return nil }
        return NSImage(cgImage: cg, size: size)
    }
}

// MARK: - Helpers

private func copyAttribute(_ el: AXUIElement, _ attr: String) -> AnyObject? {
    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(el, attr as CFString, &value)
    return err == .success ? value : nil
}
