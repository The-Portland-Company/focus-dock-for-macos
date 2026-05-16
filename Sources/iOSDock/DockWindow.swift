import SwiftUI
import AppKit
import Combine

/// Hosting controller that hard-zeros every safe-area inset path SwiftUI may
/// otherwise apply to a borderless `NSPanel`. The Flush-with-Edge bug kept
/// reappearing because SwiftUI was insetting the root view by a few points
/// for safe areas it inferred from the host window — leaving a visible gap
/// between the dock chrome and the screen edge. `.ignoresSafeArea()` inside
/// the SwiftUI tree is not always sufficient, so we belt-and-suspender it at
/// the AppKit level too.
final class DockHostingController<Content: View>: NSHostingController<Content> {
    override func viewWillAppear() {
        super.viewWillAppear()
        zeroSafeArea()
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        zeroSafeArea()
    }
    private func zeroSafeArea() {
        // Negate any safe-area insets the system tries to introduce on the
        // hosting view. Setting additionalSafeAreaInsets to the negative of
        // the current safeAreaInsets nets to zero.
        let s = view.safeAreaInsets
        view.additionalSafeAreaInsets = NSEdgeInsets(
            top: -s.top, left: -s.left, bottom: -s.bottom, right: -s.right
        )
    }
}

final class DockWindowController: NSWindowController, NSWindowDelegate {
    private var prefsObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var minimizedObserver: NSKeyValueObservation?
    private var minimizedSubscription: Any?
    private var runningAppsSubscription: Any?
    private var snapWorkItem: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var escapeMonitor: Any?

    // Auto-hide state. `shownFrame` is the laid-out frame as if the dock were
    // visible; the window itself may be parked at `hiddenFrame(for:)` instead.
    private var shownFrame: NSRect = .zero
    private var isAutoHidden: Bool = false
    private var autoHideTimer: Timer?
    private var hideWorkItem: DispatchWorkItem?
    /// Wall-clock time until which auto-hide is suppressed. Used by manual
    /// reveals ("Show Dock" menu item) so the dock stays visible long enough
    /// for the user to mouse over it before it parks itself again.
    private var suppressHideUntil: Date = .distantPast

    /// When non-nil, this dock window is pinned to a specific screen. All
    /// layout calculations (frame, hidden frame, reveal zone) use this screen
    /// instead of falling back to `NSScreen.main`. Setting this also moves the
    /// window onto the target screen at init.
    var targetScreen: NSScreen?

    /// The DockInstance this controller renders. Each controller has its own
    /// `Preferences` and `AppLibrary` instance pinned to this dock so multiple
    /// docks can run simultaneously with independent settings + items.
    let dockID: UUID
    let prefs: Preferences
    let library: AppLibrary

    private var activeScreen: NSScreen? {
        targetScreen ?? NSScreen.main ?? window?.screen
    }

    init(dockID: UUID, targetScreen: NSScreen? = nil) {
        let prefs = Preferences(dockID: dockID)
        let library = AppLibrary(dockID: dockID)
        self.dockID = dockID
        self.prefs = prefs
        self.library = library

        let content = DockView()
            .environmentObject(library)
            .environmentObject(prefs)
            .environment(\.dockID, dockID)
        let host = DockHostingController(rootView: content)

        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 130),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.contentViewController = host

        super.init(window: win)
        self.targetScreen = targetScreen
        win.delegate = self
        DockTooltipPanel.dockWindow = win
        applyLayout()
        // Re-layout on any settings change (cheap and idempotent — we read our
        // own per-dock prefs, so other docks' edits don't actually move us).
        prefsObserver = NotificationCenter.default.addObserver(
            forName: Preferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyLayout()
            self?.updateEscapeMonitor()
        }
        // Re-layout when our own items change (other dock instances' changes
        // are filtered out by dockID match in AppLibrary itself).
        library.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyLayout() }
        }.store(in: &cancellables)
        // Re-run layout when the screen's usable area changes — e.g. when the
        // system Dock is hidden during launch (which shifts visibleFrame.minY),
        // when displays are reconfigured, or when the menu bar's safe-area
        // changes. Without this, the dock keeps its initial-launch frame and
        // edgeOffset appears not to apply until the user nudges any pref.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.applyLayout() }

        // For freshly created unplaced ("New Dock") windows, force them in front
        // of the Settings window so the user immediately sees the header + X
        // and knows they have a draggable floating bar to place.
        if !prefs.isPlaced {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
                guard let w = self?.window else { return }
                w.orderFrontRegardless()
                w.makeKey()
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        updateEscapeMonitor()

        // Re-run layout when the minimized-window list changes so the dock
        // grows/shrinks to accommodate new tiles.
        minimizedSubscription = MinimizedMonitor.shared.$windows.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyLayout() }
        }
        runningAppsSubscription = RunningAppsMonitor.shared.$apps.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyLayout() }
        }
        startAutoHideTimer()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        autoHideTimer?.invalidate()
        if let prefsObserver { NotificationCenter.default.removeObserver(prefsObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// Compute the proper window size and origin for the configured edge.
    func applyLayout() {
        guard let win = window, let screen = activeScreen else { return }

        // --- Unplaced / "New Dock" floating preview state ---
        if !prefs.isPlaced {
            win.isMovableByWindowBackground = true
            win.isMovable = true

            let previewW: CGFloat = max(520, min(680, screen.frame.width * 0.42))
            let previewH: CGFloat = 105
            let x = screen.frame.midX - previewW / 2
            let y = screen.frame.midY - previewH / 2 + 30
            let floating = NSRect(x: x, y: y, width: previewW, height: previewH)

            shownFrame = floating
            win.setFrame(floating, display: true, animate: false)
            return
        }

        let edge = self.prefs.edge
        let isEditing = self.prefs.isEditingLayout
        win.isMovableByWindowBackground = isEditing
        win.isMovable = isEditing

        let prefs = self.prefs
        let useFlush = prefs.flushBottom
        let area: NSRect = useFlush ? screen.frame : screen.visibleFrame

        // If the user dismissed the "New Dock" prompt with X (without dragging
        // to an edge), keep the current centered position.
        let currentCenter = CGPoint(x: win.frame.midX, y: win.frame.midY)
        let dBottom = abs(currentCenter.y - area.minY)
        let dTop    = abs(area.maxY - currentCenter.y)
        let dLeft   = abs(currentCenter.x - area.minX)
        let dRight  = abs(area.maxX - currentCenter.x)
        if min(dBottom, dTop, dLeft, dRight) > 100 {
            shownFrame = win.frame
            win.setFrame(win.frame, display: true, animate: false)
            return
        }

        let pt = CGFloat(prefs.effectivePaddingTop), pb = CGFloat(prefs.effectivePaddingBottom)
        let pl = CGFloat(prefs.effectivePaddingLeft), pr = CGFloat(prefs.effectivePaddingRight)
        let offset = CGFloat(prefs.edgeOffset)

        let mins = MinimizedMonitor.shared.windows.count
        let runningCount = RunningAppsMonitor.shared.apps.count
        // +1 for each divider that's present (one before running apps, one before minimized).
        let dividerCount = (mins > 0 ? 1 : 0) + (runningCount > 0 ? 1 : 0)
        let count = max(1, self.library.items.count + (prefs.showFinder ? 1 : 0) + (prefs.showTrash ? 1 : 0) + mins + runningCount + dividerCount)
        let iconSize = CGFloat(prefs.effectiveIconSize)
        let spacing = CGFloat(prefs.effectiveSpacing)
        let isVerticalEdge = (edge == .left || edge == .right)
        let perpInside = CGFloat(isVerticalEdge ? prefs.effectivePaddingLeft + prefs.effectivePaddingRight : prefs.effectivePaddingTop + prefs.effectivePaddingBottom)
        let alongPaddingSum: CGFloat = isVerticalEdge
            ? CGFloat(prefs.effectivePaddingTop + prefs.effectivePaddingBottom)
            : CGFloat(prefs.effectivePaddingLeft + prefs.effectivePaddingRight)
        let totalIcons = CGFloat(count) * iconSize + CGFloat(max(0, count - 1)) * spacing

        // The icons may be compressed to fit; the *effective* icon size is what
        // actually appears on screen. Dock thickness is derived from the effective
        // size so the slider value doesn't grow the dock past what's visible.
        let maxAlong = (isVerticalEdge ? area.height : area.width) - alongPaddingSum
        let desiredAlong = totalIcons
        let alongScale: CGFloat = desiredAlong <= maxAlong ? 1 : max(0.4, maxAlong / desiredAlong)
        let effectiveIcon = iconSize * alongScale
        let magnified = prefs.magnifyOnHover ? CGFloat(prefs.effectiveMagnifySize) : effectiveIcon

        // Dock thickness = (magnified icon head-room) + (perpendicular padding) + small inset.
        let thicknessHorizontal = max(magnified, effectiveIcon) + pt + pb + 8
        let thicknessVertical = max(magnified, effectiveIcon) + pl + pr + 8
        _ = perpInside // silence unused warning if not referenced below

        // Flush "bleed": when flush-with-edge is on we extend the window a few
        // points past the screen edge in the perpendicular axis so the dock
        // chrome (which is anchored to that edge via the SwiftUI ZStack) covers
        // the edge unconditionally. This is the bulletproof half of the
        // belt-and-suspender — even if SwiftUI silently insets a pixel for
        // safe-area or rounding reasons, the bleed swallows it. The bleed is
        // off-screen, so it has no visible cost.
        let bleed: CGFloat = useFlush ? 3 : 0
        // Magnification headroom along the dock axis: when an edge icon
        // magnifies, the centered icon stack expands by (magnifySize -
        // effectiveIcon). Reserve that growth in the window length so the
        // rounded chrome corners stay outside the magnified icon — otherwise
        // the icon overlaps the corner and the dock visually "goes square"
        // at the hovered end.
        let alongHeadroom: CGFloat = prefs.magnifyOnHover ? max(0, CGFloat(prefs.magnifySize) - effectiveIcon) : 0

        // The user's Left/Right (or Top/Bottom for vertical docks) padding
        // settings are the *only* source of side margin. No hard-coded buffer.
        let maxLen = (isVerticalEdge ? area.height : area.width) - alongPaddingSum

        let frame: NSRect
        switch edge {
        case .bottom:
            let desired = totalIcons + pl + pr + alongHeadroom
            let length = prefs.fillWidth ? maxLen : min(max(desired, 240), maxLen)
            let y = useFlush ? area.minY - bleed : area.minY + offset
            frame = NSRect(x: area.midX - length / 2, y: y, width: length, height: thicknessHorizontal + bleed)
        case .top:
            let desired = totalIcons + pl + pr + alongHeadroom
            let length = prefs.fillWidth ? maxLen : min(max(desired, 240), maxLen)
            let y = useFlush ? area.maxY - thicknessHorizontal : area.maxY - thicknessHorizontal - offset
            frame = NSRect(x: area.midX - length / 2, y: y, width: length, height: thicknessHorizontal + bleed)
        case .left:
            let desired = totalIcons + pt + pb + alongHeadroom
            let length = prefs.fillWidth ? maxLen : min(max(desired, 240), maxLen)
            let x = useFlush ? area.minX - bleed : area.minX + offset
            frame = NSRect(x: x, y: area.midY - length / 2, width: thicknessVertical + bleed, height: length)
        case .right:
            let desired = totalIcons + pt + pb + alongHeadroom
            let length = prefs.fillWidth ? maxLen : min(max(desired, 240), maxLen)
            let x = useFlush ? area.maxX - thicknessVertical : area.maxX - thicknessVertical - offset
            frame = NSRect(x: x, y: area.midY - length / 2, width: thicknessVertical + bleed, height: length)
        }
        shownFrame = frame
        // While the user is editing layout, always show the dock regardless of
        // autohide so they can see what they're dragging.
        let shouldHide = prefs.autoHideDock && !prefs.isEditingLayout && isAutoHidden
        let target = shouldHide ? hiddenFrame(from: frame, edge: edge, on: screen) : frame
        win.setFrame(target, display: true, animate: false)

        // Notify that the dock just auto-hid (so any open folder popovers can close)
        if shouldHide {
            NotificationCenter.default.post(name: .dockDidAutoHide, object: nil)
        }
    }

    // MARK: - Auto-hide

    private func startAutoHideTimer() {
        autoHideTimer?.invalidate()
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.evaluateAutoHide()
        }
    }

    private func evaluateAutoHide() {
        let prefs = self.prefs
        guard prefs.autoHideDock, !prefs.isEditingLayout else {
            if isAutoHidden { reveal() }
            return
        }
        guard let win = window, let screen = activeScreen else { return }
        _ = win
        let mouse = NSEvent.mouseLocation
        let edge = prefs.edge
        if isAutoHidden {
            if revealZone(from: shownFrame, edge: edge, on: screen).contains(mouse) {
                reveal()
            }
        } else {
            // Keep visible if the cursor is over the dock or in its reveal zone,
            // or if a manual reveal is suppressing hide.
            let active = shownFrame.insetBy(dx: -2, dy: -2)
            if Date() < suppressHideUntil || active.contains(mouse) {
                hideWorkItem?.cancel()
                hideWorkItem = nil
            } else {
                scheduleHide()
            }
        }
    }

    /// Force the dock visible immediately and keep it visible for a short
    /// grace period so the user can mouse onto it. Invoked by the "Show Dock"
    /// menu item.
    func forceReveal() {
        suppressHideUntil = Date().addingTimeInterval(3.0)
        hideWorkItem?.cancel()
        hideWorkItem = nil
        if isAutoHidden {
            reveal()
        } else if let win = window {
            win.setFrame(shownFrame, display: true, animate: false)
        }
        window?.orderFrontRegardless()
    }

    private func scheduleHide() {
        guard hideWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWorkItem = nil
            let prefs = self.prefs
            guard prefs.autoHideDock, !prefs.isEditingLayout else { return }
            // Re-check the cursor position at fire-time so a quick re-entry
            // cancels the hide.
            if self.shownFrame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) { return }
            self.hide()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func hide() {
        guard !isAutoHidden, let win = window, let screen = activeScreen else { return }
        isAutoHidden = true
        DockTooltipPanel.shared.hideAll()
        let target = hiddenFrame(from: shownFrame, edge: self.prefs.edge, on: screen)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            win.animator().setFrame(target, display: true)
        }
    }

    private func reveal() {
        guard isAutoHidden, let win = window else { return }
        isAutoHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            win.animator().setFrame(shownFrame, display: true)
        }
    }

    /// Frame that parks the dock just off the active edge, leaving a 2pt strip
    /// on-screen as the reveal trigger.
    private func hiddenFrame(from shown: NSRect, edge: Preferences.Edge, on screen: NSScreen) -> NSRect {
        let strip: CGFloat = 2
        let s = screen.frame
        switch edge {
        case .bottom: return NSRect(x: shown.minX, y: s.minY - shown.height + strip, width: shown.width, height: shown.height)
        case .top:    return NSRect(x: shown.minX, y: s.maxY - strip, width: shown.width, height: shown.height)
        case .left:   return NSRect(x: s.minX - shown.width + strip, y: shown.minY, width: shown.width, height: shown.height)
        case .right:  return NSRect(x: s.maxX - strip, y: shown.minY, width: shown.width, height: shown.height)
        }
    }

    /// Thin strip at the screen edge across the dock's span — the cursor enters
    /// this region to reveal a hidden dock.
    private func revealZone(from shown: NSRect, edge: Preferences.Edge, on screen: NSScreen) -> NSRect {
        let strip: CGFloat = 3
        let s = screen.frame
        switch edge {
        case .bottom: return NSRect(x: shown.minX, y: s.minY, width: shown.width, height: strip)
        case .top:    return NSRect(x: shown.minX, y: s.maxY - strip, width: shown.width, height: strip)
        case .left:   return NSRect(x: s.minX, y: shown.minY, width: strip, height: shown.height)
        case .right:  return NSRect(x: s.maxX - strip, y: shown.minY, width: strip, height: shown.height)
        }
    }

    // Live snap-to-nearest-edge while dragging in edit mode.
    func windowDidMove(_ notification: Notification) {
        guard self.prefs.isEditingLayout, let win = window, let screen = activeScreen else { return }
        snapWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let vf = screen.visibleFrame
            let f = win.frame
            let center = NSPoint(x: f.midX, y: f.midY)
            let dBottom = abs(center.y - vf.minY)
            let dTop = abs(vf.maxY - center.y)
            let dLeft = abs(center.x - vf.minX)
            let dRight = abs(vf.maxX - center.x)
            let minDist = min(dBottom, dTop, dLeft, dRight)
            let newEdge: Preferences.Edge =
                minDist == dBottom ? .bottom :
                minDist == dTop ? .top :
                minDist == dLeft ? .left : .right
            if newEdge != self.prefs.edge {
                self.prefs.edge = newEdge
            }
            if !self.prefs.isPlaced {
                self.prefs.isPlaced = true   // First snap "activates" the dock
            }
            self.applyLayout()   // always refresh after a snap in edit mode
        }
        snapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    // MARK: - Escape key handling for Edit Layout mode

    private func updateEscapeMonitor() {
        // Remove any existing monitor
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }

        guard prefs.isEditingLayout else { return }

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Escape key (keyCode 53)
            if event.keyCode == 53 {
                Preferences.shared.isEditingLayout = false
                return nil // consume the event
            }
            return event
        }
    }
}

// MARK: - DockView

/// Wrapper around the heterogeneous things that can appear in the dock: a
/// regular DockItem (app/folder), a minimized-window tile, or a fixed divider
/// separating the right-side protected zone from the regular apps.
enum DockSlot: Identifiable {
    case item(DockItem)
    case runningApp(RunningAppEntry)
    case minimized(MinimizedWindow)
    case divider
    case runningDivider

    var id: AnyHashable {
        switch self {
        case .item(let i): return AnyHashable(i.id)
        case .runningApp(let r): return AnyHashable(r.id)
        case .minimized(let w): return AnyHashable(w.id)
        case .divider: return AnyHashable("divider")
        case .runningDivider: return AnyHashable("running-divider")
        }
    }

    /// True if this slot participates in drag-to-reorder / folder-merge.
    /// Minimized tiles and dividers are protected — they can't be dragged
    /// and other items can't be dropped onto them.
    var isReorderable: Bool {
        if case .item = self { return true }
        return false
    }
}

struct DockView: View {
    @EnvironmentObject var library: AppLibrary
    @EnvironmentObject var prefs: Preferences
    @Environment(\.dockID) private var dockID: UUID?
    @State private var isEditingDocks = Preferences.shared.isEditingDocks

    @StateObject private var dragState = DragState()
    @StateObject private var minimized = MinimizedMonitor.shared
    @StateObject private var runningApps = RunningAppsMonitor.shared
    @State private var hoverPoint: CGPoint? = nil
    @State private var smoothedHoverPoint: CGPoint? = nil  // Low-pass filtered for buttery smooth magnification

    private var iconSize: CGFloat { CGFloat(prefs.effectiveIconSize) }
    private var spacing: CGFloat { CGFloat(prefs.effectiveSpacing) }
    private var magnifyMax: CGFloat { CGFloat(prefs.effectiveMagnifySize) }

    private var isVertical: Bool {
        prefs.edge == .left || prefs.edge == .right
    }

    // Stable UUID for the virtual Finder entry so SwiftUI doesn't churn the
    // view identity on every render (which was causing the hover-jump).
    private static let finderID = UUID(uuidString: "F1DE0000-0000-0000-0000-000000000001")!
    private static let finderEntry = AppEntry(id: finderID,
                                              path: "/System/Library/CoreServices/Finder.app",
                                              name: "Finder")

    static func isReservedID(_ id: UUID) -> Bool {
        id == finderID || id == trashID
    }

    static func isTrash(_ item: DockItem) -> Bool {
        if case .app(let a) = item { return a.id == trashID }
        return false
    }

    private static let trashID = UUID(uuidString: "F1DE0000-0000-0000-0000-000000000002")!
    private static let trashEntry = AppEntry(id: trashID,
                                             path: (NSHomeDirectory() as NSString).appendingPathComponent(".Trash"),
                                             name: "Trash")

    /// All items rendered in the dock, optionally prepended by a virtual Finder
    /// item and/or appended with a virtual Trash item.
    private var renderedItems: [DockItem] {
        var result: [DockItem] = []
        if prefs.showFinder { result.append(.app(Self.finderEntry)) }
        result.append(contentsOf: library.items)
        if prefs.showTrash { result.append(.app(Self.trashEntry)) }
        return result
    }

    /// Full slot list: regular items, then a divider + minimized-window tiles
    /// inserted in the protected zone just before the Trash icon (or at the
    /// end if Trash is hidden). The divider and minimized tiles only appear
    /// when at least one window is minimized.
    private var renderedSlots: [DockSlot] {
        var result: [DockSlot] = []
        if prefs.showFinder { result.append(.item(.app(Self.finderEntry))) }
        result.append(contentsOf: library.items.map { DockSlot.item($0) })
        let running = runningApps.apps
        if !running.isEmpty {
            result.append(.runningDivider)
            result.append(contentsOf: running.map { DockSlot.runningApp($0) })
        }
        let mins = minimized.windows
        if !mins.isEmpty {
            result.append(.divider)
            result.append(contentsOf: mins.map { DockSlot.minimized($0) })
        }
        if prefs.showTrash { result.append(.item(.app(Self.trashEntry))) }
        return result
    }

    /// Effective per-icon scale to fit content within the dock window length.
    private func effectiveScale(in available: CGFloat) -> CGFloat {
        let n = max(1, renderedSlots.count)
        let interior = max(0, available - CGFloat(isVertical ? prefs.effectivePaddingTop + prefs.effectivePaddingBottom : prefs.effectivePaddingLeft + prefs.effectivePaddingRight))
        let desired = CGFloat(n) * iconSize + CGFloat(max(0, n - 1)) * spacing
        if desired <= interior { return 1 }
        return max(0.4, interior / desired)
    }

    private var dockAlignment: Alignment {
        switch prefs.edge {
        case .bottom: return .bottom
        case .top: return .top
        case .left: return .leading
        case .right: return .trailing
        }
    }

    /// Dock-panel shape with corners squared off on the edge that's flush to
    /// the screen, so it matches the native Dock when Flush-with-Edge is on.
    private var dockShape: UnevenRoundedRectangle {
        let r = CGFloat(prefs.cornerRadius)
        let flush = prefs.flushBottom
        var topL: CGFloat = r, topR: CGFloat = r, botL: CGFloat = r, botR: CGFloat = r
        if flush {
            switch prefs.edge {
            case .bottom: botL = 0; botR = 0
            case .top:    topL = 0; topR = 0
            case .left:   topL = 0; botL = 0
            case .right:  topR = 0; botR = 0
            }
        }
        return UnevenRoundedRectangle(
            topLeadingRadius: topL,
            bottomLeadingRadius: botL,
            bottomTrailingRadius: botR,
            topTrailingRadius: topR,
            style: .continuous
        )
    }

    /// Native-Dock-style chrome: behind-window blur, optional tint, hairline border.
    @ViewBuilder
    private var dockChrome: some View {
        let editing = prefs.isEditingLayout
        let bd = prefs.borderColor
        let bg = prefs.backgroundColor
        let baseBorder = prefs.showBorder
            ? Color(.sRGB, red: bd.r, green: bd.g, blue: bd.b, opacity: bd.a)
            : Color.clear
        let borderColor = editing ? Color.accentColor.opacity(0.9) : baseBorder
        let borderWidth: CGFloat = editing ? 2 : CGFloat(prefs.borderWidth)

        ZStack {
            VisualEffectBlur(material: .popover, blendingMode: .behindWindow)
                .clipShape(dockShape)
            if prefs.tintBackground {
                dockShape
                    .fill(Color(.sRGB, red: bg.r, green: bg.g, blue: bg.b, opacity: bg.a))
            }
            dockShape
                .strokeBorder(borderColor, lineWidth: borderWidth)
        }
    }

    /// Resting thickness of the dock panel — used to keep the chrome size
    /// stable as icons magnify (only the icons grow, not the panel).
    private var restingThickness: CGFloat {
        iconSize + CGFloat(isVertical ? prefs.effectivePaddingLeft + prefs.effectivePaddingRight : prefs.effectivePaddingTop + prefs.effectivePaddingBottom) + 8
    }

    /// Alignment opposite the dock edge — used to park transient UI (e.g. the
    /// edit-mode pill) in the magnification headroom so it never overlaps icons.
    private var oppositeAlignment: Alignment {
        switch prefs.edge {
        case .bottom: return .top
        case .top: return .bottom
        case .left: return .trailing
        case .right: return .leading
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let avail = isVertical ? proxy.size.height : proxy.size.width
            let scale = effectiveScale(in: avail)
            let scaledIcon = iconSize * scale
            // When "Fill width" is on, compute spacing automatically so the icons
            // are evenly distributed across the available interior width.
            let interior = max(0, avail - CGFloat(isVertical ? prefs.effectivePaddingTop + prefs.effectivePaddingBottom : prefs.effectivePaddingLeft + prefs.effectivePaddingRight))
            let n = max(1, renderedSlots.count)
            let autoSpacing: CGFloat = n > 1 ? max(0, (interior - CGFloat(n) * scaledIcon) / CGFloat(n - 1)) : 0
            let scaledSpacing = prefs.fillWidth ? autoSpacing : spacing * scale

            // Account for headroom-induced centering of the icon row inside the
            // window (length includes alongHeadroom so end icons can magnify without
            // clipping the rounded chrome). Without this, resting centers are
            // underestimated by headroom/2, causing the mag gaussian peak to bias
            // rightward (right neighbor appears more magnified than the hovered item).
            let contentAlong = CGFloat(n) * scaledIcon + CGFloat(max(0, n - 1)) * scaledSpacing + (isVertical ? (CGFloat(prefs.effectivePaddingTop) + CGFloat(prefs.effectivePaddingBottom)) : (CGFloat(prefs.effectivePaddingLeft) + CGFloat(prefs.effectivePaddingRight)))
            let extraCenter = max(0, avail - contentAlong) / 2
            let effectiveIconLeading = (isVertical ? CGFloat(prefs.effectivePaddingTop) : CGFloat(prefs.effectivePaddingLeft)) + extraCenter

            ZStack(alignment: dockAlignment) {
                // Native-Dock-style chrome sized to the resting thickness so it
                // doesn't grow with icon magnification.
                dockChrome
                    .frame(
                        width: isVertical ? restingThickness : nil,
                        height: isVertical ? nil : restingThickness
                    )

                // Delete mode: big red X / trash in the top center of the dock
                if isEditingDocks, let id = dockID {
                    VStack {
                        Button {
                            // Remove this specific dock (with safety checks inside removeDock)
                            ProfileManager.shared.removeDock(id)
                        } label: {
                            Image(systemName: "trash.circle.fill")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundStyle(.white)
                                .background(
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 38, height: 38)
                                )
                                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .help("Delete this dock")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 4)
                }

                Group {
                    if isVertical {
                        VStack(spacing: scaledSpacing) { itemViews(iconSize: scaledIcon, spacing: scaledSpacing) }
                            .padding(.top, CGFloat(prefs.effectivePaddingTop))
                            .padding(.bottom, CGFloat(prefs.effectivePaddingBottom))
                            .padding(.leading, CGFloat(prefs.effectivePaddingLeft))
                            .padding(.trailing, CGFloat(prefs.effectivePaddingRight))
                    } else {
                        HStack(spacing: scaledSpacing) { itemViews(iconSize: scaledIcon, spacing: scaledSpacing) }
                            .padding(.top, CGFloat(prefs.effectivePaddingTop))
                            .padding(.bottom, CGFloat(prefs.effectivePaddingBottom))
                            .padding(.leading, CGFloat(prefs.effectivePaddingLeft))
                            .padding(.trailing, CGFloat(prefs.effectivePaddingRight))
                    }
                }
                if prefs.isEditingLayout {
                    EditModePill()
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: oppositeAlignment)
                }

                // Special "New / Unplaced" floating preview state.
                // Thin header (drag handle + X) + small non-blocking instruction badge.
                if !prefs.isPlaced {
                    VStack(spacing: 0) {
                        // Thin header bar — clear drag zone + X button
                        HStack {
                            Text("New Dock")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.85))

                            Spacer()

                            Button {
                                prefs.isPlaced = true
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .help("Dismiss instruction (dock stays floating)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.22))

                        Spacer(minLength: 6)

                        // Small instruction badge (not covering the header)
                        Text("Drag to any edge to activate")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.4)))
                            .padding(.bottom, 6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.black.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: dockAlignment)
        }
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: Preferences.changed)) { _ in
            isEditingDocks = Preferences.shared.isEditingDocks
        }
        .coordinateSpace(name: "dock")
        .onContinuousHover(coordinateSpace: .named("dock")) { phase in
            switch phase {
            case .active(let p):
                // Light exponential smoothing for buttery-smooth magnification (native-like feel)
                let alpha: CGFloat = 0.22
                if let current = smoothedHoverPoint {
                    smoothedHoverPoint = CGPoint(
                        x: current.x * (1 - alpha) + p.x * alpha,
                        y: current.y * (1 - alpha) + p.y * alpha
                    )
                } else {
                    smoothedHoverPoint = p
                }

                // Only spring on first enter for nice "pop"
                if hoverPoint == nil {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.82)) {
                        hoverPoint = smoothedHoverPoint
                    }
                } else {
                    hoverPoint = smoothedHoverPoint
                }
                updateTooltipFor(point: p)
            case .ended:
                smoothedHoverPoint = nil
                withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                    hoverPoint = nil
                }
                DockTooltipPanel.shared.hideAll()
            }
        }
        .environmentObject(dragState)
        .environment(\.dockHoverPoint, smoothedHoverPoint ?? hoverPoint)
        .environment(\.dockIsVertical, isVertical)
        .environment(\.dockMagnifyEnabled, prefs.magnifyOnHover)
        .environment(\.dockMagnifyMax, magnifyMax)
        .environment(\.dockLeadingPad, CGFloat(isVertical ? prefs.effectivePaddingTop : prefs.effectivePaddingLeft))
        .environment(\.dockFrontmostPath, runningApps.frontmostPath)
    }

    /// Pick the item under the cursor (by frame in "dock" space) and show
    /// a floating tooltip bubble for it. Driven from onContinuousHover at
    /// the DockView level — the only hover hook that fires reliably for
    /// a non-activating NSPanel.
    private func updateTooltipFor(point: CGPoint) {
        guard prefs.labelMode == .tooltip else {
            DockTooltipPanel.shared.hideAll()
            return
        }
        let pad: CGFloat = 14
        var picked: (id: UUID, name: String)? = nil
        let frames = ItemFrameRegistry.shared.frames
        let items = renderedItems
        for item in items {
            if let f = frames[item.id], f.insetBy(dx: -pad, dy: -pad).contains(point) {
                picked = (item.id, itemLabel(item))
                break
            }
        }
        if let p = picked {
            DockTooltipPanel.shared.show(text: p.name, near: p.id, edge: prefs.edge)
        } else {
            DockTooltipPanel.shared.hideAll()
        }
    }

    private func itemLabel(_ item: DockItem) -> String {
        switch item {
        case .app(let a): return a.name
        case .folder(let f): return f.name
        }
    }

    @ViewBuilder private func itemViews(iconSize: CGFloat, spacing: CGFloat) -> some View {
        ForEach(Array(renderedSlots.enumerated()), id: \.element.id) { idx, slot in
            switch slot {
            case .item(let item):
                DockItemView(
                    item: item,
                    index: idx,
                    iconSize: iconSize,
                    spacing: spacing,
                    dragState: dragState
                )
            case .runningApp(let entry):
                RunningAppTileView(entry: entry, iconSize: iconSize, index: idx, spacing: spacing)
            case .minimized(let window):
                MinimizedTileView(window: window, iconSize: iconSize, index: idx, spacing: spacing, isVertical: isVertical)
            case .divider, .runningDivider:
                DockDivider(isVertical: isVertical, iconSize: iconSize)
            }
        }
    }
}

// MARK: - Minimized tile & divider

/// Renders a single minimized window as a small thumbnail with the app icon
/// inset in the corner — matches the iOS-dock visual language of this app.
/// Click restores the window. Tiles are not draggable and are excluded from
/// the regular-item drop / reorder system.
struct MinimizedTileView: View {
    let window: MinimizedWindow
    let iconSize: CGFloat
    let index: Int
    let spacing: CGFloat
    let isVertical: Bool

    @Environment(\.dockHoverPoint) private var hoverPoint
    @Environment(\.dockMagnifyEnabled) private var magnifyEnabled
    @Environment(\.dockMagnifyMax) private var magnifyMax
    @Environment(\.dockLeadingPad) private var leadingPad

    private var restingCenterAlongAxis: CGFloat {
        leadingPad + CGFloat(index) * (iconSize + spacing) + iconSize / 2
    }

    private var magnificationScale: CGFloat {
        guard magnifyEnabled, let hp = hoverPoint else { return 1 }
        let mouse = isVertical ? hp.y : hp.x
        let dist = abs(mouse - restingCenterAlongAxis)
        let sigma = iconSize * 1.8
        let g = exp(-(dist * dist) / (2 * sigma * sigma))
        let maxScale = max(1.0, magnifyMax / iconSize)
        return 1 + (maxScale - 1) * g * 0.9
    }

    var body: some View {
        let scale = magnificationScale
        let displaySize = iconSize * scale

        let cellW = isVertical ? iconSize : max(iconSize, displaySize)
        let cellH = isVertical ? iconSize : max(iconSize, displaySize)

        ZStack(alignment: .bottomTrailing) {
            // Preview thumbnail (rounded), with app icon fallback.
            RoundedRectangle(cornerRadius: iconSize * 0.18, style: .continuous)
                .fill(Color.black.opacity(0.25))
            Group {
                if let preview = window.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(nsImage: window.appIcon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(iconSize * 0.12)
                }
            }
            .frame(width: cellW, height: cellH)
            .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: iconSize * 0.18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
            )

            // Small app-icon badge in the corner
            Image(nsImage: window.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: displaySize * 0.42, height: displaySize * 0.42)
                .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                .offset(x: 2, y: 2)
        }
        .frame(width: cellW, height: cellH)
        .contentShape(Rectangle())
        .onTapGesture { MinimizedMonitor.shared.unminimize(window) }
        .help(window.title.isEmpty ? window.appName : window.title)
        // Direct tracking via smoothed hoverPoint (no per-frame spring for responsiveness)
    }
}

/// Renders a running-but-not-pinned app as a regular icon with a running-
/// indicator dot. Tap brings the app forward (or relaunches if it terminated).
struct RunningAppTileView: View {
    let entry: RunningAppEntry
    let iconSize: CGFloat
    let index: Int
    let spacing: CGFloat

    @EnvironmentObject var prefs: Preferences
    @Environment(\.dockHoverPoint) private var hoverPoint
    @Environment(\.dockIsVertical) private var isVertical
    @Environment(\.dockMagnifyEnabled) private var magnifyEnabled
    @Environment(\.dockMagnifyMax) private var magnifyMax
    @Environment(\.dockLeadingPad) private var leadingPad
    @Environment(\.dockFrontmostPath) private var frontmostPath

    private var isActive: Bool {
        entry.path == frontmostPath
    }

    private var restingCenterAlongAxis: CGFloat {
        leadingPad + CGFloat(index) * (iconSize + spacing) + iconSize / 2
    }

    private var magnificationScale: CGFloat {
        guard magnifyEnabled, let hp = hoverPoint else { return 1 }
        let mouse = isVertical ? hp.y : hp.x
        let dist = abs(mouse - restingCenterAlongAxis)
        // Falloff tuned for secondary section (slightly softer)
        let sigma = iconSize * 1.8
        let g = exp(-(dist * dist) / (2 * sigma * sigma))
        let maxScale = max(1.0, magnifyMax / iconSize)
        return 1 + (maxScale - 1) * g * 0.85
    }

    var body: some View {
        let scale = magnificationScale
        let displaySize = iconSize * scale
        let style = prefs.openAppVisualStyle

        VStack(spacing: 4) {
            Image(nsImage: entry.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: displaySize, height: displaySize)
                .if(style == .glowAndDarken && isActive) { view in
                    view.shadow(color: Color.accentColor.opacity(0.75), radius: 8, x: 0, y: 0)
                }
                .if(style == .glowAndDarken && !isActive) { view in
                    view.opacity(0.6)
                }
            if prefs.showRunningIndicators && style == .dot {
                Circle()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: 4 * scale, height: 4 * scale)
            }
        }
        .frame(width: max(iconSize, displaySize), height: max(iconSize, displaySize))
        .contentShape(Rectangle())
        .onTapGesture { RunningAppsMonitor.shared.activate(entry) }
        .help(entry.name)
        // Direct tracking via smoothed hoverPoint (no per-frame spring for responsiveness)
    }
}

/// Vertical (or horizontal when the dock is on a side) divider line marking
/// the start of the protected minimized-windows zone. Sized relative to the
/// icon footprint so it scales with the dock.
struct DockDivider: View {
    let isVertical: Bool
    let iconSize: CGFloat

    var body: some View {
        // The divider occupies a thin layout cell along the dock axis. The
        // surrounding HStack/VStack adds the normal spacing on each side, so
        // the divider naturally sits between the protected zone and the
        // regular apps.
        Group {
            if isVertical {
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: iconSize * 0.6, height: 1)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 1, height: iconSize * 0.6)
            }
        }
        .frame(width: isVertical ? iconSize : 8, height: isVertical ? 8 : iconSize, alignment: .center)
        .allowsHitTesting(false)
    }
}

private struct EditModePill: View {
    @EnvironmentObject private var prefs: Preferences
    @State private var pulse = false

    var body: some View {
        Button {
            prefs.isEditingLayout = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                Text("Exit Edit Layout")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.95))
                    .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 2)
            )
        }
        .buttonStyle(.plain)
        .opacity(pulse ? 1.0 : 0.85)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .help("Click to exit Edit Layout mode (or press Esc)")
    }
}

// MARK: - Magnification environment

private struct DockHoverPointKey: EnvironmentKey { static let defaultValue: CGPoint? = nil }
private struct DockIsVerticalKey: EnvironmentKey { static let defaultValue: Bool = false }
private struct DockMagnifyEnabledKey: EnvironmentKey { static let defaultValue: Bool = true }
private struct DockMagnifyMaxKey: EnvironmentKey { static let defaultValue: CGFloat = 110 }
private struct DockLeadingPadKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct DockFrontmostPathKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct DockIDKey: EnvironmentKey { static let defaultValue: UUID? = nil }

extension View {
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

extension EnvironmentValues {
    var dockHoverPoint: CGPoint? {
        get { self[DockHoverPointKey.self] }
        set { self[DockHoverPointKey.self] = newValue }
    }
    var dockIsVertical: Bool {
        get { self[DockIsVerticalKey.self] }
        set { self[DockIsVerticalKey.self] = newValue }
    }
    var dockMagnifyEnabled: Bool {
        get { self[DockMagnifyEnabledKey.self] }
        set { self[DockMagnifyEnabledKey.self] = newValue }
    }
    var dockMagnifyMax: CGFloat {
        get { self[DockMagnifyMaxKey.self] }
        set { self[DockMagnifyMaxKey.self] = newValue }
    }
    var dockLeadingPad: CGFloat {
        get { self[DockLeadingPadKey.self] }
        set { self[DockLeadingPadKey.self] = newValue }
    }

    var dockFrontmostPath: String? {
        get { self[DockFrontmostPathKey.self] }
        set { self[DockFrontmostPathKey.self] = newValue }
    }

    var dockID: UUID? {
        get { self[DockIDKey.self] }
        set { self[DockIDKey.self] = newValue }
    }
}

// MARK: - Drag State

final class DragState: ObservableObject {
    @Published var draggingID: UUID? = nil
    @Published var dragOffset: CGSize = .zero
    @Published var hoverTargetID: UUID? = nil
    @Published var hoverStarted: Date? = nil
    @Published var wiggle: Bool = false
    @Published var folderForming: UUID? = nil // target id when threshold reached
    /// True while the cursor is far enough outside the dock window that
    /// releasing would remove the dragged item (native-Dock drag-off behavior).
    @Published var draggedOutside: Bool = false
    /// timestamp when first hover began (for the *current* hover target)
    var hoverTimer: Timer?

    func cancelHoverTimer() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }
}

// MARK: - DockItemView

struct DockItemView: View {
    let item: DockItem
    let index: Int
    let iconSize: CGFloat
    let spacing: CGFloat
    @ObservedObject var dragState: DragState
    @EnvironmentObject var library: AppLibrary

    @State private var frameInDock: CGRect = .zero
    @State private var showFolderPopover: Bool = false

    // Automatically close any open folder popover when the user starts dragging
    // or enters Edit Layout mode (good UX, prevents confusing states).
    private func closeFolderPopoverIfNeeded() {
        if showFolderPopover && (prefs.isEditingLayout || dragState.draggingID != nil) {
            showFolderPopover = false
        }
    }
    @State private var folderFormProgress: CGFloat = 0
    @EnvironmentObject var prefs: Preferences
    @StateObject private var runningMonitor = RunningAppsMonitor.shared
    @Environment(\.dockHoverPoint) private var hoverPoint
    @Environment(\.dockIsVertical) private var isVertical
    @Environment(\.dockMagnifyEnabled) private var magnifyEnabled
    @Environment(\.dockMagnifyMax) private var magnifyMax
    @Environment(\.dockLeadingPad) private var leadingPad
    @Environment(\.dockFrontmostPath) private var frontmostPath

    /// Resting center of this item along the dock axis. Derived purely from
    /// layout inputs (padding + index*(icon+spacing) + icon/2) so that
    /// neighbor magnification — which reflows the HStack/VStack — does NOT
    /// change this item's own scale. Using the live `frameInDock` here caused
    /// a feedback loop (neighbor scales → cell width grows → this item's
    /// frame shifts → this item's scale recomputes → neighbors shift again),
    /// which produced the glitchy/blinky magnification animation.
    private var restingCenterAlongAxis: CGFloat {
        leadingPad + CGFloat(index) * (iconSize + spacing) + iconSize / 2
    }

    private var magnificationScale: CGFloat {
        guard magnifyEnabled, let hp = hoverPoint else { return 1 }
        let mouse = isVertical ? hp.y : hp.x
        let dist = abs(mouse - restingCenterAlongAxis)
        // Falloff over ~2.5x the icon size
        let sigma = iconSize * 1.6
        let g = exp(-(dist * dist) / (2 * sigma * sigma))
        let maxScale = max(1.0, magnifyMax / iconSize)
        return 1 + (maxScale - 1) * g
    }

    var body: some View {
        let isDragging = dragState.draggingID == item.id
        let isHoverTarget = dragState.hoverTargetID == item.id
        let isFormingFolder = dragState.folderForming == item.id
        let magScale = magnificationScale
        // While the dragged item is outside the dock, collapse its layout cell
        // so neighbors close the gap — matches native Dock drag-off behavior.
        let isDetached = isDragging && dragState.draggedOutside && !DockView.isReservedID(item.id)

        VStack(spacing: 4) {
            if prefs.labelMode == .above {
                labelText
            }
            ZStack {
                // Folder formation halo
                if isHoverTarget && !isDragging {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: iconSize + 16, height: iconSize + 16)
                        .scaleEffect(isFormingFolder ? 1.15 : 1.0)
                        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: isFormingFolder)
                }

                // Layout cell grows along the dock axis with the displayed icon
                // size, so magnified icons push neighbors aside instead of
                // overlapping them (matches macOS Dock magnification).
                let scale = isDragging ? max(1.1, magScale) : (isHoverTarget ? 0.92 : magScale)
                let displaySize = iconSize * scale
                let cellW = isDetached ? 0 : (isVertical ? iconSize : max(iconSize, displaySize))
                let cellH = isDetached ? 0 : (isVertical ? max(iconSize, displaySize) : iconSize)
                Color.clear
                    .frame(width: cellW, height: cellH)
                    .overlay(alignment: isVertical ? .leading : .bottom) {
                        iconContent(size: displaySize)
                            .opacity(isDetached ? 0 : (isDragging ? 0.85 : 1.0))
                            // Badge rides the actual displayed icon's top-right
                            // corner so it stays pinned to the corner whether
                            // the icon is at rest or magnified.
                            .overlay(alignment: .topTrailing) {
                                badgeOverlay(displaySize: displaySize)
                            }
                            // No per-frame spring here — the smoothed hoverPoint in DockView + direct state update gives 1:1 responsive tracking.
                            // Spring is only used on hover enter/exit in the parent for the "pop" feel.
                    }
                    // Badge anchored to the resting cell's top-right, NOT the
                    // magnified icon's, so it stays put when the icon grows
                    // upward on hover. Size still scales with displaySize for
                    // legibility — only the anchor point is stable.
                    .overlay(alignment: .topTrailing) {
                        let scale = isDragging ? max(1.1, magScale) : (isHoverTarget ? 0.92 : magScale)
                        badgeOverlay(displaySize: iconSize * scale)
                    }
            }
            .background(
                GeometryReader { proxy -> Color in
                    let f = proxy.frame(in: .named("dock"))
                    DispatchQueue.main.async {
                        self.frameInDock = f
                        ItemFrameRegistry.shared.frames[item.id] = f
                    }
                    return Color.clear
                }
            )
            // iOS-style wiggle when in edit mode
            .modifier(WiggleModifier(active: dragState.wiggle && !isDragging))
            .offset(isDragging ? dragState.dragOffset : .zero)

            if prefs.labelMode == .below {
                labelText
            }

            // Open app visual treatment
            let style = prefs.openAppVisualStyle
            if isAppRunning {
                if style == .glowAndDarken {
                    // Glow for active, darken for inactive open apps (no dot)
                    if isActiveApp {
                        Circle()
                            .fill(Color.accentColor.opacity(0.0))
                            .frame(width: iconSize * 1.15, height: iconSize * 1.15)
                            .shadow(color: Color.accentColor.opacity(0.7), radius: 7, x: 0, y: 0)
                    }
                } else if prefs.showRunningIndicators {
                    // Classic dot
                    Circle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 4, height: 4)
                }
            }
        }
        .coordinateSpace(name: "item-\(item.id)")
        .gesture(
            DragGesture(coordinateSpace: .named("dock"))
                .onChanged { value in
                    if dragState.draggingID != item.id {
                        dragState.draggingID = item.id
                    }
                    dragState.dragOffset = CGSize(
                        width: value.translation.width,
                        height: value.translation.height
                    )
                    updateHoverTarget(dragLocation: value.location)
                }
                .onEnded { value in
                    finishDrag(at: value.location)
                }
        )
        .onTapGesture {
            if dragState.wiggle {
                // Exit edit mode on tap in empty-ish area; for now, tapping launches
            }
            // Ensure any open folder popover is closed when interacting with dock items (click-outside behavior for other icons).
            NotificationCenter.default.post(name: Notification.Name("FocusDock.CloseAllFolderPopovers"), object: nil)
            switch item {
            case .app(let a):
                library.launch(a)
            case .folder:
                if showFolderPopover {
                    // Tapping the same folder again → close it (toggle behavior)
                    showFolderPopover = false
                } else {
                    // Small delay helps ensure any previous popover has fully closed
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                        showFolderPopover = true
                    }
                }
            }
        }
        .contextMenu {
            if isTrash {
                Button("Empty Trash") {
                    library.emptyTrash()
                }
                .disabled(library.trashIsEmpty)

                Button("Open Trash") {
                    library.openTrash()
                }
            }
        }
        // Folder popover is handled via a transient NSPopover (see iconContent)
    }

    @ViewBuilder private func iconContent(size: CGFloat) -> some View {
        switch item {
        case .app(let a):
            Image(nsImage: a.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .activeGlow(isActive: isActive, style: prefs.indicatorStyle)
        case .folder(let f):
            FolderIconView(folder: f, size: size)
                .background(
                    FolderPopoverPresenter(
                        isPresented: $showFolderPopover,
                        arrowEdge: .top,
                        content: {
                            FolderPopover(folder: f)
                                .environmentObject(library)
                                .environmentObject(prefs)
                                .environment(\.dockFrontmostPath, frontmostPath)
                        }
                    )
                )
                .onChange(of: prefs.isEditingLayout) { _ in
                    if showFolderPopover { showFolderPopover = false }
                }
                .onChange(of: dragState.draggingID) { newValue in
                    if showFolderPopover, newValue != nil {
                        // Small delay so very short / accidental drags don't instantly close the popover
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            if showFolderPopover {
                                showFolderPopover = false
                            }
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .dockDidAutoHide)) { _ in
                    if showFolderPopover { showFolderPopover = false }
                }
        }
    }

    /// Numeric badge (red capsule) + attention dot (pulsing red circle),
    /// matched in size to the currently-displayed icon so they scale with
    /// the magnification system.
    @ViewBuilder private func badgeOverlay(displaySize: CGFloat) -> some View {
        if case .app(let a) = item, let state = library.badgeState(for: a.name) {
            let badgeFont = max(8, displaySize * 0.28)
            let badgePadH = max(4, displaySize * 0.10)
            let badgePadV = max(1, displaySize * 0.04)
            let dotSize = max(8, displaySize * 0.20)
            if let count = state.badgeCount {
                Text(count)
                    .font(.system(size: badgeFont, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, badgePadH)
                    .padding(.vertical, badgePadV)
                    .background(
                        Capsule().fill(Color.red)
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: max(0.5, displaySize * 0.015)))
                    )
                    .offset(x: displaySize * 0.08, y: -displaySize * 0.08)
                    .shadow(color: Color.black.opacity(0.25), radius: 1, x: 0, y: 1)
            } else if state.needsAttention {
                AttentionDot(size: dotSize)
                    .offset(x: displaySize * 0.08, y: -displaySize * 0.08)
            }
        }
    }

    private var isAppRunning: Bool {
        guard case .app(let a) = item else { return false }
        let url = URL(fileURLWithPath: a.path).resolvingSymlinksInPath()
        return NSWorkspace.shared.runningApplications.contains { app in
            guard let bundleURL = app.bundleURL?.resolvingSymlinksInPath() else { return false }
            return bundleURL == url
        }
    }

    private var isActiveApp: Bool {
        guard case .app(let a) = item else { return false }
        guard let front = frontmostPath else { return false }
        let url = URL(fileURLWithPath: a.path).resolvingSymlinksInPath().path
        return front == url
    }

    private var isTrash: Bool {
        guard case .app(let a) = item else { return false }
        let trashPath = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
        return a.path == trashPath
    }

    private var labelText: some View {
        Text(label)
            .font(.system(size: 10))
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .frame(maxWidth: iconSize + 16)
    }

    private var label: String {
        switch item {
        case .app(let a): return a.name
        case .folder(let f): return f.name
        }
    }

    // MARK: - Drag logic

    private func updateHoverTarget(dragLocation: CGPoint) {
        // dragLocation is in "dock" coordinate space.
        // Find which OTHER item we are over.
        guard let myFrame = currentItemFrame() else { return }

        // Native-Dock parity: if the cursor leaves the dock window's bounds
        // (with a small forgiveness pad), treat this drag as "outside" — the
        // dragged icon detaches and will poof on release. Re-entry restores
        // normal drop-target logic.
        let mouse = NSEvent.mouseLocation
        let outside: Bool = {
            guard let win = DockTooltipPanel.dockWindow else { return false }
            return !win.frame.insetBy(dx: -10, dy: -10).contains(mouse)
        }()
        if outside != dragState.draggedOutside {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                dragState.draggedOutside = outside
            }
            if outside, !DockView.isReservedID(item.id), let img = draggedIconImage() {
                DragPreviewPanel.shared.show(image: img, at: mouse)
            } else if !outside {
                DragPreviewPanel.shared.hide()
            }
        }
        if outside {
            DragPreviewPanel.shared.move(to: mouse)
            if dragState.hoverTargetID != nil {
                dragState.hoverTargetID = nil
                dragState.folderForming = nil
            }
            dragState.cancelHoverTimer()
            return
        }

        // The dragged finger location → adjusted by our own frame center + translation
        let pointer = CGPoint(
            x: myFrame.midX + dragState.dragOffset.width,
            y: myFrame.midY + dragState.dragOffset.height
        )

        // Read all sibling frames via a centralized registry
        let hovered = ItemFrameRegistry.shared.itemAt(point: pointer, excluding: item.id)
        if hovered != dragState.hoverTargetID {
            dragState.hoverTargetID = hovered
            dragState.folderForming = nil
            dragState.cancelHoverTimer()
            if hovered != nil {
                // Start the iOS "hold to enter edit mode + form folder" timer
                let target = hovered
                dragState.hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in
                    DispatchQueue.main.async {
                        if dragState.hoverTargetID == target {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                dragState.wiggle = true
                                dragState.folderForming = target
                            }
                        }
                    }
                }
            }
        }
    }

    private func currentItemFrame() -> CGRect? {
        ItemFrameRegistry.shared.frames[item.id]
    }

    private func draggedIconImage() -> NSImage? {
        switch item {
        case .app(let a): return a.icon
        case .folder(let f): return f.apps.first?.icon
        }
    }

    private func finishDrag(at location: CGPoint) {
        let target = dragState.hoverTargetID
        let dragged = item.id
        let droppedOutside = dragState.draggedOutside

        dragState.cancelHoverTimer()

        // Native-Dock drag-off-to-remove. If the cursor is outside the dock at
        // release, poof the icon at the cursor and remove it from the library.
        // Finder/Trash are pseudo-items not stored in library.items; removeItem
        // is a no-op for them, so we skip the poof and snap them back.
        let isRemovableItem = !DockView.isReservedID(dragged)
        if droppedOutside && isRemovableItem {
            let releasePoint = NSEvent.mouseLocation
            DragPreviewPanel.shared.hide()
            NSAnimationEffect.poof.show(
                centeredAt: releasePoint,
                size: NSSize(width: 64, height: 64),
                completionHandler: {}
            )
            library.removeItem(id: dragged)
            dragState.draggingID = nil
            dragState.dragOffset = .zero
            dragState.hoverTargetID = nil
            dragState.folderForming = nil
            dragState.draggedOutside = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { dragState.wiggle = false }
            }
            return
        }

        // More forgiving rule: if there's a valid hover target at release time,
        // create / merge into the folder regardless of whether the 0.8s "wiggle"
        // threshold fired. iOS' real-world behavior is identical — pause + release
        // works as readily as full edit-mode + release.
        if let t = target, t != dragged {
            // Run mutation OUTSIDE the spring animation block so SwiftUI doesn't
            // try to animate the disappearance of the dragged view while the
            // model index has already shifted; that's the chain of events that
            // was producing "folder appears then disappears".
            library.combine(dragged: dragged, into: t)
        }

        DragPreviewPanel.shared.hide()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
            dragState.draggingID = nil
            dragState.dragOffset = .zero
            dragState.hoverTargetID = nil
            dragState.folderForming = nil
            dragState.draggedOutside = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { dragState.wiggle = false }
        }
    }
}

// Track item frames in dock coordinate space so we can hit-test the drag pointer.
final class ItemFrameRegistry {
    static let shared = ItemFrameRegistry()
    var frames: [UUID: CGRect] = [:]

    func itemAt(point: CGPoint, excluding: UUID) -> UUID? {
        // Generous hit-test pad so the drop target is much less finicky.
        for (id, frame) in frames where id != excluding {
            if frame.insetBy(dx: -14, dy: -14).contains(point) { return id }
        }
        return nil
    }
}

// MARK: - Wiggle

struct WiggleModifier: ViewModifier {
    let active: Bool
    @State private var phase: Double = 0

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(active ? sin(phase) * 3.0 : 0))
            .onAppear {
                guard active else { return }
                withAnimation(.linear(duration: 0.16).repeatForever(autoreverses: false)) {
                    phase = .pi * 2
                }
            }
            .onChange(of: active) { newValue in
                if newValue {
                    withAnimation(.linear(duration: 0.16).repeatForever(autoreverses: false)) {
                        phase = .pi * 2
                    }
                } else {
                    withAnimation(.default) { phase = 0 }
                }
            }
    }
}

// MARK: - Folder Icon

struct FolderIconView: View {
    let folder: FolderEntry
    let size: CGFloat

    @EnvironmentObject var prefs: Preferences
    @Environment(\.dockFrontmostPath) private var frontmostPath

    private var containsActiveApp: Bool {
        guard let front = frontmostPath else { return false }
        return folder.apps.contains { $0.path == front }
    }

    private var isActiveStyle: Bool {
        prefs.openAppVisualStyle == .glowAndDarken
    }

    var body: some View {
        ZStack {
            let baseFill = Color.primary.opacity(0.18)
            let baseStroke = Color.primary.opacity(0.22)

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(baseFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(baseStroke, lineWidth: 0.5)
                )
                .if(isActiveStyle && containsActiveApp) { view in
                    view.shadow(color: Color.accentColor.opacity(0.65), radius: 10, x: 0, y: 0)
                }

            let grid = Array(folder.apps.prefix(9))
            let cell = (size - 18) / 3
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { col in
                            let idx = row * 3 + col
                            if idx < grid.count {
                                Image(nsImage: grid[idx].icon)
                                    .resizable()
                                    .frame(width: cell, height: cell)
                                    .cornerRadius(4)
                            } else {
                                Color.clear.frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
            .padding(7)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Folder popover

struct FolderPopover: View {
    let folder: FolderEntry
    @EnvironmentObject var library: AppLibrary
    @EnvironmentObject var prefs: Preferences
    @Environment(\.dockFrontmostPath) private var frontmostPath
    @State private var editingName: Bool = false
    @State private var draftName: String = ""

    private var resolvedColumns: Int {
        if let c = folder.columns, c > 0 { return c }
        // Auto: roughly square-ish, capped at 5.
        let n = max(1, folder.apps.count)
        return min(5, max(1, Int(ceil(Double(n).squareRoot()))))
    }

    private let cellSize: CGFloat = 56
    private let cellSpacing: CGFloat = 14

    var body: some View {
        let leftPad = prefs.effectivePaddingLeft
        let rightPad = prefs.effectivePaddingRight
        let topPad = prefs.effectivePaddingTop
        let bottomPad = prefs.effectivePaddingBottom

        let cols = Array(repeating: GridItem(.fixed(cellSize + 16), spacing: cellSpacing), count: resolvedColumns)

        VStack(alignment: .leading, spacing: 10) {
            header
            LazyVGrid(columns: cols, alignment: .leading, spacing: cellSpacing) {
                ForEach(folder.apps) { app in
                    folderAppCell(app)
                }
            }
        }
        .padding(.top, topPad)
        .padding(.bottom, bottomPad)
        .padding(.leading, leftPad)
        .padding(.trailing, rightPad)
        .frame(
            width: CGFloat(resolvedColumns) * (cellSize + 16) +
                   CGFloat(max(0, resolvedColumns - 1)) * cellSpacing +
                   leftPad + rightPad
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            if editingName {
                TextField("Folder name", text: $draftName, onCommit: {
                    library.renameFolder(folder.id, to: draftName.trimmingCharacters(in: .whitespaces).isEmpty ? folder.name : draftName)
                    editingName = false
                })
                .textFieldStyle(.roundedBorder)
                .font(.headline)
            } else {
                Text(folder.name)
                    .font(.headline)
                    .onTapGesture(count: 2) {
                        draftName = folder.name
                        editingName = true
                    }
                    .help("Double-click to rename")
            }
            Spacer()
            Button {
                NotificationCenter.default.post(name: SettingsRouter.openFolder, object: folder.id)
            } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Folder settings")
        }
    }

    @ViewBuilder
    private func folderAppCell(_ app: AppEntry) -> some View {
        let isActive = (app.path == frontmostPath) && prefs.openAppVisualStyle == .glowAndDarken

        VStack(spacing: 4) {
            if prefs.labelMode == .above {
                cellLabel(app)
            }
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: cellSize, height: cellSize)
                .if(isActive) { $0.shadow(color: Color.accentColor.opacity(0.7), radius: 8, x: 0, y: 0) }
                .nativeToolTip(prefs.labelMode == .tooltip ? app.name : "")
            if prefs.labelMode == .below {
                cellLabel(app)
            }
        }
        .frame(width: cellSize + 16)
        .contentShape(Rectangle())
        .onTapGesture { library.launch(app) }
    }

    private func cellLabel(_ app: AppEntry) -> some View {
        Text(app.name).font(.system(size: 10)).lineLimit(1)
            .frame(maxWidth: cellSize + 16)
    }
}

// MARK: - Transient Folder Popover Presenter

/// Presents a FolderPopover as an NSPopover with .transient behavior.
/// This ensures the popover automatically closes when the user clicks anywhere
/// outside of it (including the desktop or other dock items).
struct FolderPopoverPresenter<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    let content: () -> Content

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isPresented {
            context.coordinator.showPopover(from: nsView)
        } else {
            context.coordinator.hidePopover()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, arrowEdge: arrowEdge, content: content)
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        @Binding var isPresented: Bool
        let arrowEdge: Edge
        let content: () -> Content

        private var popover: NSPopover?

        init(isPresented: Binding<Bool>, arrowEdge: Edge, content: @escaping () -> Content) {
            self._isPresented = isPresented
            self.arrowEdge = arrowEdge
            self.content = content
        }

        func showPopover(from view: NSView) {
            guard popover == nil else { return }

            let hostingController = NSHostingController(rootView: content())
            hostingController.view.alphaValue = 0
            hostingController.view.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)

            let popover = NSPopover()
            popover.contentViewController = hostingController
            popover.behavior = .transient
            popover.delegate = self

            let preferredEdge: NSRectEdge = switch arrowEdge {
            case .top:    .maxY
            case .bottom: .minY
            case .leading: .minX
            case .trailing: .maxX
            }

            popover.show(relativeTo: view.bounds, of: view, preferredEdge: preferredEdge)
            self.popover = popover

            // Nice springy scale + fade in animation
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0) // nice ease
                hostingController.view.animator().alphaValue = 1.0
                hostingController.view.animator().layer?.setAffineTransform(CGAffineTransform(scaleX: 0.92, y: 0.92))
            } completionHandler: {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    hostingController.view.animator().layer?.setAffineTransform(.identity)
                }
            }
        }

        func hidePopover() {
            guard let popover = popover else { return }

            // Gentle scale + fade out before closing
            if let hosting = popover.contentViewController?.view {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    hosting.animator().alphaValue = 0.0
                    hosting.animator().layer?.setAffineTransform(CGAffineTransform(scaleX: 0.95, y: 0.95))
                } completionHandler: {
                    popover.close()
                    self.popover = nil
                }
            } else {
                popover.close()
                self.popover = nil
            }
        }

        func popoverDidClose(_ notification: Notification) {
            isPresented = false
            popover = nil
        }
    }
}

// MARK: - Native tooltip helper

/// Sets `toolTip` on an underlying NSView. SwiftUI's `.help()` doesn't reliably
/// register the tooltip when the view is also part of complex gesture/transform
/// hierarchies like our dock items.
struct ToolTipView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.toolTip = text.isEmpty ? nil : text
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text.isEmpty ? nil : text
    }
}

extension View {
    func nativeToolTip(_ text: String) -> some View {
        background(ToolTipView(text: text).allowsHitTesting(false))
    }
}

extension Notification.Name {
    static let dockDidAutoHide = Notification.Name("FocusDock.DidAutoHide")
}

// MARK: - Registry-updating GeometryReader extension

// MARK: - Attention Dot

/// Pulsing red dot used when an app has requested user attention. Matches
/// the visual weight of the numeric badge so the two states feel cohesive.
struct AttentionDot: View {
    let size: CGFloat
    @State private var pulse: Bool = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: max(0.5, size * 0.08)))
            .shadow(color: Color.black.opacity(0.25), radius: 1, x: 0, y: 1)
            .scaleEffect(pulse ? 1.15 : 0.85)
            .opacity(pulse ? 1.0 : 0.7)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

/// ViewModifier that renders a premium soft glow (layered shadows) around an
/// icon when it represents the frontmost active application (for indicatorStyle == .glow).
/// Applied to both main dock icons (including folders) and cells inside folder popovers.
struct ActiveGlowModifier: ViewModifier {
    let isActive: Bool
    let style: Preferences.IndicatorStyle

    func body(content: Content) -> some View {
        if style == .glow && isActive {
            content
                .shadow(color: Color.accentColor.opacity(0.42), radius: 3, x: 0, y: 0)
                .shadow(color: Color.white.opacity(0.68), radius: 7, x: 0, y: 0)
                .shadow(color: Color.accentColor.opacity(0.22), radius: 15, x: 0, y: 0)
        } else {
            content
        }
    }
}

extension View {
    func activeGlow(isActive: Bool, style: Preferences.IndicatorStyle) -> some View {
        self.modifier(ActiveGlowModifier(isActive: isActive, style: style))
    }
}

private struct FrameTracker: ViewModifier {
    let id: UUID
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { ItemFrameRegistry.shared.frames[id] = proxy.frame(in: .named("dock")) }
                    .onChange(of: proxy.frame(in: .named("dock"))) { new in
                        ItemFrameRegistry.shared.frames[id] = new
                    }
            }
        )
    }
}

// MARK: - Dock Tooltip Panel

/// Floating panel that renders a label bubble outside the dock window — the
/// dock's own NSPanel is sized to icon thickness, so a SwiftUI tooltip drawn
/// inside it would be clipped. A separate borderless panel positioned along
/// the outer edge of the dock matches the native macOS Dock's hover-label.
final class DockTooltipPanel {
    static let shared = DockTooltipPanel()
    static weak var dockWindow: NSWindow?

    private var panel: NSPanel?
    private var label: NSTextField?
    private var currentOwner: UUID?

    func show(text: String, near id: UUID, edge: Preferences.Edge) {
        guard !text.isEmpty,
              let dockWin = Self.dockWindow,
              let itemFrame = ItemFrameRegistry.shared.frames[id] else { return }
        ensurePanel()
        guard let panel = panel, let label = label else { return }

        label.stringValue = text
        label.sizeToFit()
        let padH: CGFloat = 10
        let padV: CGFloat = 5
        let w = ceil(label.frame.width) + padH * 2
        let h = ceil(label.frame.height) + padV * 2

        let dockFrame = dockWin.frame
        let contentHeight = dockWin.contentView?.bounds.height ?? dockFrame.height
        let itemCenterScreenX = dockFrame.minX + itemFrame.midX
        let itemCenterScreenY = dockFrame.minY + (contentHeight - itemFrame.midY)
        let gap: CGFloat = 8

        let x: CGFloat
        let y: CGFloat
        switch edge {
        case .bottom:
            x = itemCenterScreenX - w / 2
            y = dockFrame.maxY + gap
        case .top:
            x = itemCenterScreenX - w / 2
            y = dockFrame.minY - gap - h
        case .left:
            x = dockFrame.maxX + gap
            y = itemCenterScreenY - h / 2
        case .right:
            x = dockFrame.minX - gap - w
            y = itemCenterScreenY - h / 2
        }

        let frame = NSRect(x: x, y: y, width: w, height: h)
        panel.setFrame(frame, display: true)
        label.frame = NSRect(x: padH, y: padV, width: w - 2 * padH, height: h - 2 * padV)
        currentOwner = id
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func hideIfOwner(_ id: UUID) {
        guard currentOwner == id else { return }
        currentOwner = nil
        panel?.orderOut(nil)
    }

    func hideAll() {
        currentOwner = nil
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        if panel != nil { return }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 24),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.ignoresMouseEvents = true

        let blur = NSVisualEffectView(frame: p.contentView!.bounds)
        blur.material = .toolTip
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 6
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        let lbl = NSTextField(labelWithString: "")
        lbl.font = .systemFont(ofSize: 12, weight: .regular)
        lbl.textColor = .labelColor
        lbl.backgroundColor = .clear
        lbl.isBordered = false
        lbl.isEditable = false
        lbl.alignment = .center
        blur.addSubview(lbl)

        p.contentView = blur
        panel = p
        label = lbl
    }
}

// MARK: - Visual Effect Blur

// MARK: - Drag Preview Panel

/// Borderless floating panel that shows the dragged icon following the cursor
/// while the user is dragging an item *outside* the dock. The dock's own
/// NSPanel clips its content to its frame, so once the cursor leaves the dock
/// the in-dock icon disappears. A separate panel here provides the native
/// "icon attached to cursor" feel until release.
final class DragPreviewPanel {
    static let shared = DragPreviewPanel()
    private var panel: NSPanel?
    private var imageView: NSImageView?
    private let size: CGFloat = 64

    func show(image: NSImage, at screenPoint: CGPoint) {
        ensurePanel()
        guard let panel = panel, let imageView = imageView else { return }
        imageView.image = image
        let origin = NSPoint(x: screenPoint.x - size / 2, y: screenPoint.y - size / 2)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: size, height: size)), display: true)
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func move(to screenPoint: CGPoint) {
        guard let panel = panel, panel.isVisible else { return }
        let origin = NSPoint(x: screenPoint.x - size / 2, y: screenPoint.y - size / 2)
        panel.setFrameOrigin(origin)
    }

    func hide() {
        panel?.orderOut(nil)
        imageView?.image = nil
    }

    private func ensurePanel() {
        if panel != nil { return }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.ignoresMouseEvents = true
        let iv = NSImageView(frame: p.contentView!.bounds)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.autoresizingMask = [.width, .height]
        iv.alphaValue = 0.95
        p.contentView?.addSubview(iv)
        panel = p
        imageView = iv
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
