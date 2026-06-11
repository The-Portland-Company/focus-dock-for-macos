import AppKit
import SwiftUI

// Entire file is compiled out of the App Store build: the strip is part of
// the private-API desktop feature (DMG/dev only). Callers go through the
// ungated DesktopStripFeature facade.
#if !APPSTORE

// MARK: - Shared UI state

/// State shared between the controller (key handling, hide policy) and the
/// SwiftUI tiles (selection ring, inline rename). One instance per controller,
/// shared by every per-screen panel so selection/rename are globally unique.
final class DesktopStripUIState: ObservableObject {
    /// Space uuid highlighted by ←/→ keyboard navigation (nil = none).
    @Published var selectedUUID: String?

    /// Space uuid currently being renamed inline (nil = none). While non-nil
    /// the controller suppresses hide-on-resign-key so the rename field can
    /// hold first-responder without dismissing the strip.
    @Published var renamingUUID: String? {
        didSet { onRenamingChanged?(renamingUUID != nil) }
    }

    var onRenamingChanged: ((Bool) -> Void)?
}

// MARK: - Layout metrics

/// Sizing shared by the controller (panel frames) and DesktopStripView
/// (tile layout) so the SwiftUI bar fills the panel exactly.
enum DesktopStripMetrics {
    static let tileSpacing: CGFloat = 14
    static let horizontalPadding: CGFloat = 18
    static let verticalPadding: CGFloat = 14
    static let labelGap: CGFloat = 6
    static let labelHeight: CGFloat = 20
    static let cornerRadius: CGFloat = 18
    static let maxTileWidth: CGFloat = 176
    static let minTileWidth: CGFloat = 90
    /// Gap between the menu bar (visibleFrame top) and the bar.
    static let topMargin: CGFloat = 12
    static let screenSideMargin: CGFloat = 20

    /// 16:10 thumbnails, shrunk evenly when many spaces must fit the screen.
    static func tileWidth(spaceCount: Int, on screen: NSScreen) -> CGFloat {
        let count = CGFloat(max(1, spaceCount))
        let avail = screen.visibleFrame.width
            - 2 * screenSideMargin
            - 2 * horizontalPadding
            - (count - 1) * tileSpacing
        return min(maxTileWidth, max(minTileWidth, avail / count))
    }

    static func barFrame(spaceCount: Int, on screen: NSScreen) -> NSRect {
        let count = CGFloat(max(1, spaceCount))
        let tile = tileWidth(spaceCount: spaceCount, on: screen)
        let width = count * tile + (count - 1) * tileSpacing + 2 * horizontalPadding
        let thumbHeight = tile * 10 / 16
        let height = 2 * verticalPadding + thumbHeight + labelGap + labelHeight
        let visible = screen.visibleFrame
        return NSRect(
            x: (visible.midX - width / 2).rounded(),
            y: (visible.maxY - topMargin - height).rounded(),
            width: width.rounded(),
            height: height.rounded()
        )
    }
}

// MARK: - Panel

/// Spotlight-style overlay panel: borderless + non-activating, but CAN become
/// key — so the inline rename TextField can take keyboard focus without the
/// app activating (the frontmost app keeps focus). Joins all spaces so the
/// strip survives space switches (needed when M3 starts switching from it).
final class DesktopStripPanel: NSPanel {
    /// SkyLight display identifier whose spaces this panel renders
    /// (display UUID string, or "Main" when separate Spaces are off).
    var displayIdentifier: String = ""

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

/// Owns one DesktopStripPanel per screen and the show/hide lifecycle:
/// - show: orderFrontRegardless() all panels, makeKey() the one under the
///   mouse — NEVER NSApp.activate (frontmost app must keep focus).
/// - hide: Esc, key-resign (suppressed mid-rename), or any click outside.
/// - keyboard: ←/→ move the selection ring, Return switches to the selected
///   space (SpaceSwitcher via the facade), Esc closes (when not renaming).
final class DesktopStripController: NSObject, NSWindowDelegate {
    private let model: SpacesModel
    private let thumbnails: SpaceThumbnailCache
    private let uiState = DesktopStripUIState()
    private var panels: [DesktopStripPanel] = []
    private(set) var isVisible = false
    /// Mirrors uiState.renamingUUID != nil; gates hide-on-resign-key and lets
    /// the local key monitor pass events through to the rename field editor.
    private var isRenaming = false
    private var keyMonitor: Any?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    init(model: SpacesModel, thumbnails: SpaceThumbnailCache) {
        self.model = model
        self.thumbnails = thumbnails
        super.init()
        uiState.onRenamingChanged = { [weak self] renaming in
            self?.isRenaming = renaming
        }
    }

    deinit {
        removeMonitors()
        for panel in panels {
            panel.delegate = nil
            panel.orderOut(nil)
        }
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard !isVisible else { return }
        model.refresh()
        buildPanels()
        guard !panels.isEmpty else { return }
        isVisible = true
        uiState.selectedUUID = nil

        let mouse = NSEvent.mouseLocation
        var keyPanel: DesktopStripPanel?
        for panel in panels {
            panel.orderFrontRegardless()
            if let screen = panel.screen, screen.frame.contains(mouse) {
                keyPanel = panel
            }
        }
        // Key WITHOUT activating: keyboard (Esc/arrows/rename) routes to the
        // panel while the previously frontmost app stays frontmost.
        (keyPanel ?? panels.first)?.makeKey()
        installMonitors()
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        isRenaming = false
        uiState.renamingUUID = nil
        uiState.selectedUUID = nil
        removeMonitors()
        for panel in panels {
            panel.delegate = nil
            panel.orderOut(nil)
        }
        panels.removeAll()
    }

    // MARK: Panels

    private func buildPanels() {
        let displays = model.displays
        guard !displays.isEmpty else { return }
        if displays.count == 1 && displays[0].displayIdentifier == "Main" {
            // "Displays have separate Spaces" is OFF: one shared space list —
            // mirror the same strip on every screen.
            for screen in NSScreen.screens {
                makePanel(for: displays[0], on: screen)
            }
        } else {
            for display in displays {
                guard let screen = model.screen(for: display) else { continue }
                makePanel(for: display, on: screen)
            }
        }
    }

    private func makePanel(for display: DisplaySpaces, on screen: NSScreen) {
        let frame = DesktopStripMetrics.barFrame(spaceCount: display.spaces.count, on: screen)
        let panel = DesktopStripPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.displayIdentifier = display.displayIdentifier
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the dock panels (.floating), below MinimizeFlyOverlay
        // (shielding − 10, MinimizeAnimator.swift).
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 20)
        // Must survive space switches (M3 switches spaces while it's open).
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self

        let tileWidth = DesktopStripMetrics.tileWidth(spaceCount: display.spaces.count, on: screen)
        let host = NSHostingView(rootView: DesktopStripView(
            model: model,
            uiState: uiState,
            thumbnails: thumbnails,
            displayIdentifier: display.displayIdentifier,
            tileWidth: tileWidth
        ))
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panels.append(panel)
    }

    // MARK: Event monitors

    private func installMonitors() {
        // Keyboard while a strip panel is key. Deployment target is 13.0, so
        // no .onKeyPress (macOS 14+) — a local monitor covers every tile.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            guard !self.isRenaming else { return event } // rename field owns the keyboard
            switch event.keyCode {
            case 53: // Esc
                self.hide()
                return nil
            case 123: // ←
                self.moveSelection(by: -1)
                return nil
            case 124: // →
                self.moveSelection(by: 1)
                return nil
            case 36, 76: // Return / keypad Enter → switch to selected tile
                if let uuid = self.uiState.selectedUUID {
                    DesktopStripFeature.requestSwitch(to: uuid)
                }
                return nil
            default:
                return event
            }
        }
        // Click outside (other apps) → hide.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hide()
        }
        // Click on one of OUR other windows (dock panel, settings) → hide too;
        // clicks inside a strip panel pass through untouched.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if let win = event.window, self.panels.contains(where: { $0 === win }) {
                return event
            }
            self.hide()
            return event
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        keyMonitor = nil
        localClickMonitor = nil
        globalClickMonitor = nil
    }

    // MARK: Keyboard selection

    private func moveSelection(by delta: Int) {
        let panel = panels.first(where: { $0.isKeyWindow }) ?? panels.first
        guard let panel,
              let display = model.displays.first(where: { $0.displayIdentifier == panel.displayIdentifier })
        else { return }
        let uuids = display.spaces.map(\.uuid)
        guard !uuids.isEmpty else { return }

        var index: Int
        if let selected = uiState.selectedUUID, let i = uuids.firstIndex(of: selected) {
            index = i + delta
        } else if let current = display.currentSpaceUUID, let i = uuids.firstIndex(of: current) {
            // First arrow press: start from the current space.
            index = i + delta
        } else {
            index = delta > 0 ? 0 : uuids.count - 1
        }
        index = max(0, min(uuids.count - 1, index))
        uiState.selectedUUID = uuids[index]
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible, !isRenaming else { return }
        // Key may legitimately move between OUR strip panels (clicking the
        // strip on another screen). Defer one runloop tick and only hide when
        // key landed outside the strip.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isRenaming else { return }
            if let key = NSApp.keyWindow, self.panels.contains(where: { $0 === key }) { return }
            self.hide()
        }
    }
}

#endif
