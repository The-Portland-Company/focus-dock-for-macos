import Foundation
import AppKit
import ApplicationServices
import os

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
        guard let target = DockTargetLocator.frame(forAppPath: path) else {
            Self.log.info("no dock target for \(path, privacy: .public) — skipping animation")
            return
        }
        let icon = IconCache.shared.icon(for: path)
        // AXObserver callback already runs on main; dispatch to next runloop tick
        // anyway so AppKit can finish handling the OS minimize before our panel
        // tries to order itself in front.
        RunLoop.main.perform(inModes: [.common]) {
            MinimizeFlyOverlay.fly(icon: icon, from: sourceFrame, to: target)
        }
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
    static func fly(icon: NSImage, from sourceRect: CGRect, to target: CGRect) {
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
            })
        })
    }
}
