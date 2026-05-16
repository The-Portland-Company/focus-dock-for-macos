import Foundation
import AppKit
import ApplicationServices
import os

// MARK: - Private SkyLight / AX SPI bridges
//
// These let us hide an arbitrary on-screen window (any app, any process) by
// setting its CGS alpha to 0. macOS still runs its own minimize/unminimize
// animation, but on an invisible window — so our custom fly-to-dock animation
// is the only thing the user sees.

private typealias CGSConnection = UInt32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnection

@_silgen_name("CGSSetWindowAlpha")
private func CGSSetWindowAlpha(_ cid: CGSConnection, _ wid: CGWindowID, _ alpha: CGFloat) -> Int32

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Watches every regular running app for `kAXWindowMiniaturizedNotification`
/// and plays a custom overlay animation that flies an icon from the window's
/// last known frame to the matching tile in our custom dock. Complements the
/// system minimize animation (mineffect=scale, set by SystemDockManager) so
/// the user gets clear directional feedback toward our dock — rather than
/// the system Dock's hidden tile location.
final class MinimizeAnimator {
    static let shared = MinimizeAnimator()
    private static let log = Logger(subsystem: "com.theportlandcompany.FocusDock", category: "MinAnim")

    private var observers: [pid_t: AXObserver] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Last visible frame per CGWindowID, captured at the moment of minimize.
    /// Used as the destination for the reverse (unminimize) animation so the
    /// icon flies back to where the window will reappear.
    private var lastFrames: [CGWindowID: CGRect] = [:]
    /// Bundle path per CGWindowID — needed at unminimize time to look up the
    /// matching dock-icon source point and the app icon for the overlay.
    private var bundlePaths: [CGWindowID: String] = [:]

    func start() {
        guard AXIsProcessTrusted() else {
            Self.log.error("Accessibility not granted — minimize animator disabled")
            return
        }
        for app in NSWorkspace.shared.runningApplications {
            installObserver(app)
        }
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.installObserver(app)
            }
        })
        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.observers.removeValue(forKey: app.processIdentifier)
            }
        })
    }

    private func installObserver(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, pid != ownPID, app.activationPolicy == .regular, observers[pid] == nil else { return }
        var observer: AXObserver?
        let createErr = AXObserverCreate(pid, miniaturizeCallback, &observer)
        guard createErr == .success, let observer = observer else {
            Self.log.error("AXObserverCreate failed pid=\(pid) err=\(createErr.rawValue)")
            return
        }
        let axApp = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let addErr = AXObserverAddNotification(observer, axApp, kAXWindowMiniaturizedNotification as CFString, refcon)
        if addErr != .success {
            Self.log.error("AddNotification failed pid=\(pid) err=\(addErr.rawValue)")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    fileprivate func handleMinimize(_ axWindow: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(axWindow, &pid)
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid),
              let bundleURL = app.bundleURL else { return }
        let path = bundleURL.resolvingSymlinksInPath().path

        let sourceFrame = windowAXFrame(axWindow) ?? .zero

        // Cache pre-minimize state so we can fly the icon back to the same
        // spot when the user unminimizes via our dock tile.
        var cgWindowID: CGWindowID = 0
        if _AXUIElementGetWindow(axWindow, &cgWindowID) == .success, cgWindowID != 0 {
            if sourceFrame.width > 1 {
                lastFrames[cgWindowID] = sourceFrame
            }
            bundlePaths[cgWindowID] = path
            // Hide the real window so the OS's own minimize animation plays on
            // an invisible target — only our custom overlay is visible.
            _ = CGSSetWindowAlpha(CGSMainConnectionID(), cgWindowID, 0)
        }

        guard let target = DockTargetLocator.frame(forAppPath: path) else {
            Self.log.info("no dock target for \(path, privacy: .public) — skipping animation")
            return
        }
        let icon = IconCache.shared.icon(for: path)
        RunLoop.main.perform(inModes: [.common]) {
            MinimizeFlyOverlay.fly(icon: icon, from: sourceFrame, to: target, completion: nil)
        }
    }

    /// Called by `MinimizedMonitor.unminimize(_:)` immediately before it sets
    /// `kAXMinimizedAttribute = false`. We fly the icon back from the matching
    /// dock tile to the window's pre-minimize frame, then restore the window's
    /// alpha (which we set to 0 at minimize time) so the real window becomes
    /// visible. Timed so the alpha restore happens after the system's own
    /// unminimize animation has finished — the user only ever sees our flight.
    func willUnminimize(_ window: MinimizedWindow) {
        let wid = window.cgWindowID
        let target = lastFrames[wid] ?? .zero
        let source = DockTargetLocator.frameForMinimizedTile(id: window.id) ?? .zero
        let icon = window.appIcon
        let cid = CGSMainConnectionID()
        let restoreAlpha: () -> Void = {
            _ = CGSSetWindowAlpha(cid, wid, 1)
            self.lastFrames.removeValue(forKey: wid)
            self.bundlePaths.removeValue(forKey: wid)
        }
        if source.width < 1 && target.width < 1 {
            // No useful endpoints — restore alpha after a short delay so the
            // OS unminimize animation completes invisibly first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: restoreAlpha)
            return
        }
        // Fly from dock tile -> window's last visible frame, then reveal.
        // Swap from/to so the icon expands as it flies out (matching native
        // unminimize feel).
        MinimizeFlyOverlay.fly(icon: icon, from: source, to: target.width > 1 ? target : source.insetBy(dx: -120, dy: -120), completion: restoreAlpha)
    }

    /// Returns the window's frame in NSWindow screen coordinates (origin
    /// bottom-left of primary display). AX reports top-left-origin so we flip.
    private func windowAXFrame(_ window: AXUIElement) -> CGRect? {
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posObj = posRef, let sizeObj = sizeRef else { return nil }
        let posVal = posObj as! AXValue
        let sizeVal = sizeObj as! AXValue
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal, .cgPoint, &point)
        AXValueGetValue(sizeVal, .cgSize, &size)
        guard size.width > 1, size.height > 1 else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let flippedY = primaryHeight - point.y - size.height
        return CGRect(x: point.x, y: flippedY, width: size.width, height: size.height)
    }
}

private let miniaturizeCallback: AXObserverCallback = { _, element, notification, refcon in
    let notifString = notification as String
    guard notifString == kAXWindowMiniaturizedNotification, let refcon = refcon else { return }
    let animator = Unmanaged<MinimizeAnimator>.fromOpaque(refcon).takeUnretainedValue()
    animator.handleMinimize(element)
}

// MARK: - Dock target lookup

/// Finds the screen-coordinate frame of the icon in our dock that represents
/// a given app path. Searches running-app tiles first (most likely match for
/// a window being minimized from a non-pinned app), then pinned app tiles,
/// across every dock window managed by this AppDelegate.
enum DockTargetLocator {
    private static let log = Logger(subsystem: "com.theportlandcompany.FocusDock", category: "MinAnim")

    /// Screen frame for a specific minimized-window tile id (the UUID
    /// registered by MinimizedTileView via `trackItemFrame`). Used as the
    /// source position for the reverse fly-out animation on unminimize.
    static func frameForMinimizedTile(id: UUID) -> CGRect? {
        guard let appDel = AppDelegate.shared,
              let f = ItemFrameRegistry.shared.frames[id] else { return nil }
        for ctrl in appDel.dockWindows {
            guard let panelFrame = ctrl.window?.frame else { continue }
            let contentSize = ctrl.window?.contentView?.bounds.size ?? .zero
            return convertToScreen(dockFrame: f, panelFrame: panelFrame, contentSize: contentSize)
        }
        return nil
    }

    static func frame(forAppPath path: String) -> CGRect? {
        let normPath = normalized(path)
        let frames = ItemFrameRegistry.shared.frames
        guard let appDel = AppDelegate.shared else {
            log.info("AppDelegate.shared not set — bailing")
            return nil
        }
        for ctrl in appDel.dockWindows {
            guard let panelFrame = ctrl.window?.frame else { continue }
            for entry in RunningAppsMonitor.shared.apps {
                if normalized(entry.path) == normPath {
                    if let f = frames[entry.id] {
                        let contentSize = ctrl.window?.contentView?.bounds.size ?? .zero
                        return convertToScreen(dockFrame: f, panelFrame: panelFrame, contentSize: contentSize)
                    }
                }
            }
            for item in ctrl.library.items {
                switch item {
                case .app(let a):
                    if normalized(a.path) == normPath, let f = frames[item.id] {
                        let contentSize = ctrl.window?.contentView?.bounds.size ?? .zero
                        return convertToScreen(dockFrame: f, panelFrame: panelFrame, contentSize: contentSize)
                    }
                case .folder(let folder):
                    if folder.apps.contains(where: { normalized($0.path) == normPath }), let f = frames[item.id] {
                        let contentSize = ctrl.window?.contentView?.bounds.size ?? .zero
                        return convertToScreen(dockFrame: f, panelFrame: panelFrame, contentSize: contentSize)
                    }
                }
            }
        }
        return nil
    }

    private static func normalized(_ p: String) -> String {
        URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }

    private static func convertToScreen(dockFrame f: CGRect, panelFrame: CGRect, contentSize: CGSize) -> CGRect {
        // SwiftUI's "dock" coord space lives inside the panel's content view.
        // Y is top-down in SwiftUI; NSWindow screen Y is bottom-up. Flip using
        // the content view's height (NOT the panel's frame height, which can
        // differ when the title bar / chrome contributes to frame height —
        // for a borderless panel they're equal, but be explicit).
        let contentH = contentSize.height > 0 ? contentSize.height : panelFrame.height
        let flippedY = contentH - f.origin.y - f.height
        return CGRect(
            x: panelFrame.origin.x + f.origin.x,
            y: panelFrame.origin.y + flippedY,
            width: f.width,
            height: f.height
        )
    }
}

// MARK: - Animation overlay

/// Borderless transparent NSPanel that draws the app icon and animates its
/// frame from the source window position to the dock-icon target. Fades out
/// at the end so the user reads the motion as "this window landed here."
enum MinimizeFlyOverlay {
    static func fly(icon: NSImage, from sourceRect: CGRect, to target: CGRect, completion: (() -> Void)? = nil) {
        let startFrame: NSRect
        if sourceRect.width > 1, sourceRect.height > 1 {
            // Start as a square sized to fit inside the original window, capped
            // so very large windows don't produce a comically huge starting icon.
            let dim = min(min(sourceRect.width, sourceRect.height), 180)
            startFrame = NSRect(
                x: sourceRect.midX - dim / 2,
                y: sourceRect.midY - dim / 2,
                width: dim,
                height: dim
            )
        } else {
            // Unknown source frame — start at 2× the target size centered on target.
            let dim = max(target.width, target.height) * 2
            startFrame = NSRect(
                x: target.midX - dim / 2,
                y: target.midY - dim / 2,
                width: dim,
                height: dim
            )
        }

        let panel = NSPanel(
            contentRect: startFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 10)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        let iv = NSImageView(image: icon)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.frame = NSRect(origin: .zero, size: startFrame.size)
        iv.autoresizingMask = [.width, .height]
        panel.contentView = iv
        panel.alphaValue = 1
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.30
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.10
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                completion?()
            })
        })
    }
}
