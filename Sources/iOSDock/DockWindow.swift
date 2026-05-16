import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

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
        ) { [weak self] _ in self?.applyLayout() }
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
        let edge = self.prefs.edge
        let isEditing = self.prefs.isEditingLayout
        win.isMovableByWindowBackground = isEditing
        win.isMovable = isEditing

        let prefs = self.prefs
        // Flush works on any edge now — uses full screen.frame and ignores
        // edgeOffset on that edge. (Pref key kept as "flushBottom" for storage.)
        let useFlush = prefs.flushBottom
        let area: NSRect = useFlush ? screen.frame : screen.visibleFrame

        let pt = CGFloat(prefs.effectivePaddingTop), pb = CGFloat(prefs.effectivePaddingBottom)
        let pl = CGFloat(prefs.effectivePaddingLeft), pr = CGFloat(prefs.effectivePaddingRight)
        let offset = CGFloat(prefs.edgeOffset)

        let mins = MinimizedMonitor.shared.windows.count
        let runningCount = RunningAppsMonitor.shared.apps.count
        // +1 for each divider that's present (one before running apps, one before minimized).
        let dividerCount = (mins > 0 ? 1 : 0) + (runningCount > 0 ? 1 : 0)
        let customDividerCount = self.library.dividers.count
        let actualSlotCount = max(1, self.library.items.count + (prefs.showFinder ? 1 : 0) + (prefs.showTrash ? 1 : 0) + mins + runningCount + dividerCount + customDividerCount)
        let iconSize = CGFloat(prefs.effectiveIconSize)
        let spacing = CGFloat(prefs.effectiveSpacing)
        let isVerticalEdge = (edge == .left || edge == .right)
        let perpInside = CGFloat(isVerticalEdge ? prefs.effectivePaddingLeft + prefs.effectivePaddingRight : prefs.effectivePaddingLeft + prefs.effectivePaddingRight)
        let perpAlongAxis = CGFloat(isVerticalEdge ? prefs.effectivePaddingTop + prefs.effectivePaddingBottom : prefs.effectivePaddingLeft + prefs.effectivePaddingRight)
        let narrowCount = dividerCount + customDividerCount
        let fullCount = actualSlotCount - narrowCount
        let gapCount = max(0, actualSlotCount - 1)
        let gaps = CGFloat(gapCount) * spacing
        let dividers = CGFloat(narrowCount) * 8
        let totalIcons: CGFloat = CGFloat(fullCount) * iconSize + dividers + gaps

        // The icons may be compressed to fit; the *effective* icon size is what
        // actually appears on screen. Dock thickness is derived from the effective
        // size so the slider value doesn't grow the dock past what's visible.
        let maxAlong: CGFloat
        switch edge {
        case .bottom, .top: maxAlong = area.width - 16 - perpAlongAxis
        case .left, .right: maxAlong = area.height - 16 - perpAlongAxis
        }
        let desiredAlong = totalIcons
        let alongScale: CGFloat = desiredAlong <= maxAlong ? 1 : max(0.4, maxAlong / desiredAlong)
        let effectiveIcon = iconSize * alongScale
        let magnified = prefs.magnifyOnHover ? CGFloat(prefs.effectiveMagnifySize) : effectiveIcon

        // Dock thickness = (magnified icon head-room) + (perpendicular padding) + small inset.
        let thicknessHorizontal = max(magnified, effectiveIcon) + pt + pb + 8
        let thicknessVertical = max(magnified, effectiveIcon) + pl + pr + 8
        _ = perpInside // silence unused warning if not referenced below

        let screenBuffer: CGFloat = 16
        // Flush "bleed": when flush-with-edge is on we extend the window a few
        // points past the screen edge in the perpendicular axis so the dock
        // chrome (which is anchored to that edge via the SwiftUI ZStack) covers
        // the edge unconditionally. This is the bulletproof half of the
        // belt-and-suspender — even if SwiftUI silently insets a pixel for
        // safe-area or rounding reasons, the bleed swallows it. The bleed is
        // off-screen, so it has no visible cost.
        let bleed: CGFloat = useFlush ? 3 : 0
        // Magnification headroom along the dock axis: reserve a *full* max single-icon
        // growth buffer on *each* side of the resting bar. When hovering an end icon
        // the chrome can expand almost a full (magnifySize - icon) in one direction.
        // Using 2x ensures the window is wide enough on the hovered side so the chrome
        // never gets cut off.
        let alongHeadroom: CGFloat = prefs.magnifyOnHover ? 2 * max(0, CGFloat(prefs.magnifySize) - effectiveIcon) : 0
        let frame: NSRect
        switch edge {
        case .bottom:
            let desired = totalIcons + pl + pr + alongHeadroom
            let maxLen = area.width - screenBuffer
            let length = prefs.fillWidth ? maxLen : min(max(desired, 240), maxLen)
            let y = useFlush ? area.minY - bleed : area.minY + offset
            frame = NSRect(x: area.midX - length / 2, y: y, width: length, height: thicknessHorizontal + bleed)
        case .top:
            let desired = totalIcons + pl + pr + alongHeadroom
            let maxLen = area.width - screenBuffer
            let length = prefs.fillWidth ? maxLen : min(max(desired, 240), maxLen)
            let y = useFlush ? area.maxY - thicknessHorizontal : area.maxY - thicknessHorizontal - offset
            frame = NSRect(x: area.midX - length / 2, y: y, width: length, height: thicknessHorizontal + bleed)
        case .left:
            let desired = totalIcons + pt + pb + alongHeadroom
            let maxLen = area.height - screenBuffer
            let length = prefs.fillWidth ? maxLen : min(max(desired, 240), maxLen)
            let x = useFlush ? area.minX - bleed : area.minX + offset
            frame = NSRect(x: x, y: area.midY - length / 2, width: thicknessVertical + bleed, height: length)
        case .right:
            let desired = totalIcons + pt + pb + alongHeadroom
            let maxLen = area.height - screenBuffer
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
                self.prefs.edge = newEdge // triggers applyLayout via observer
            } else {
                self.applyLayout()
            }
        }
        snapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
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
    case customDivider(DockDividerBar)

    var id: AnyHashable {
        switch self {
        case .item(let i): return AnyHashable(i.id)
        case .runningApp(let r): return AnyHashable(r.id)
        case .minimized(let w): return AnyHashable(w.id)
        case .divider: return AnyHashable("divider")
        case .runningDivider: return AnyHashable("running-divider")
        case .customDivider(let d): return AnyHashable(d.id)
        }
    }

    /// True if this slot participates in drag-to-reorder / folder-merge.
    /// Minimized tiles, system dividers, and custom user dividers are protected.
    var isReorderable: Bool {
        if case .item = self { return true }
        return false
    }
}

// MARK: - Frame tracking for hover hit-testing (tooltips + drag targets)

extension View {
    /// Attaches an invisible GeometryReader that records this view's frame
    /// (in the "dock" named coordinate space) into the shared registry under
    /// the given id. Used by DockItemView, RunningAppTileView and
    /// MinimizedTileView so that `onContinuousHover` can reliably identify
    /// which icon (pinned app, folder, Finder, Trash, running app, or minimized
    /// window tile) is under the pointer — powering the liquid-glass tooltip
    /// when `prefs.labelMode == .tooltip`.
    func trackItemFrame(id: UUID) -> some View {
        self.background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        ItemFrameRegistry.shared.frames[id] = proxy.frame(in: .named("dock"))
                    }
                    .onChange(of: proxy.frame(in: .named("dock"))) { new in
                        ItemFrameRegistry.shared.frames[id] = new
                    }
            }
        )
    }
}

struct DockView: View {
    @EnvironmentObject var library: AppLibrary
    @EnvironmentObject var prefs: Preferences
    @StateObject private var dragState = DragState()
    @StateObject private var minimized = MinimizedMonitor.shared
    @StateObject private var runningApps = RunningAppsMonitor.shared
    @State private var hoverPoint: CGPoint? = nil

    // Divider Edit mode drag-from-palette state
    @State private var isDraggingNewDivider: Bool = false
    @State private var dividerDragPoint: CGPoint? = nil
    @State private var dividerInsertAfter: UUID? = nil   // the item (or nil for start) to insert after

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

        // Interleave user-pinned items with any custom divider bars placed
        // after specific items (or at the start via afterItemID == nil).
        let divs = library.dividers
        let startDivs = divs.filter { $0.afterItemID == nil }
        for d in startDivs {
            result.append(.customDivider(d))
        }
        for item in library.items {
            result.append(.item(item))
            let afterThis = divs.filter { $0.afterItemID == item.id }
            for d in afterThis {
                result.append(.customDivider(d))
            }
        }

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
        let slots = renderedSlots
        let iconCount = slots.filter { slotOccupiesIconSpace($0) }.count
        let divCount = slots.count - iconCount
        let interior = max(0, available - CGFloat(isVertical ? prefs.effectivePaddingTop + prefs.effectivePaddingBottom : prefs.effectivePaddingLeft + prefs.effectivePaddingRight))
        // Icons scale; dividers use fixed narrow cells. Reserve space for dividers + approx gaps.
        let iconDesired = CGFloat(iconCount) * iconSize + CGFloat(max(0, iconCount - 1)) * spacing
        let divDesired = CGFloat(divCount) * customDividerCellWidth + CGFloat(max(0, divCount)) * (spacing * 0.5)
        let desired = iconDesired + divDesired + CGFloat(max(0, slots.count - iconCount - 1)) * spacing * 0.5
        if desired <= interior { return 1 }
        // Only scale the icon portion down if needed.
        let remaining = max(20, interior - divDesired)
        if iconDesired <= remaining { return 1 }
        return max(0.4, remaining / iconDesired)
    }

    private var dockAlignment: Alignment {
        switch prefs.edge {
        case .bottom: return .bottom
        case .top: return .top
        case .left: return .leading
        case .right: return .trailing
        }
    }

    /// Alignment used to place the (possibly narrow) chrome bar inside the
    /// full-size window rect. Centers on the long axis, flushes to the dock
    /// edge on the short axis. This makes narrow (!fillWidth) docks appear
    /// centered while still attaching to the screen edge.
    private var barPlacementAlignment: Alignment {
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
            // Reverted bar to high-quality vibrancy for best "background magnifies with items" stretch behavior.
            // Real native Liquid Glass (NSGlassEffectView) kept for tooltip bubble only (static size works great).
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

    /// Base (non-magnified) thickness of the dock panel. We add dynamic extra
    /// during hover (extraPerp) so the chrome grows with icons like native Dock.
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

    /// Context menu shown on dock background (chrome + icon-row gaps) for
    /// entering/exiting the divider editing mode ("Edit Dock").
    @ViewBuilder private var editDockContextMenu: some View {
        Button {
            withAnimation(.spring(response: 0.3)) {
                prefs.isEditingDividers.toggle()
            }
        } label: {
            Label(
                prefs.isEditingDividers ? "Exit Edit Dock" : "Edit Dock",
                systemImage: "rectangle.split.2x1"
            )
        }
        if prefs.isEditingDividers {
            Divider()
            Button {
                let last = library.items.last?.id
                library.insertDivider(after: last)
            } label: {
                Label("Add Divider (at end)", systemImage: "plus.rectangle.on.rectangle")
            }
        }
    }

    /// Extra left/top offset to the icon row caused by alongHeadroom (the window
    /// now reserves a full max-growth buffer on each side). Added to leadingPad
    /// so the restingCenters used for hover magnification are correct and the
    /// peak does not get biased when the chrome expands on one end.
    private var headroomExtra: CGFloat {
        guard prefs.magnifyOnHover else { return 0 }
        let base = CGFloat(prefs.effectiveIconSize)
        let mag = CGFloat(prefs.effectiveMagnifySize)
        return max(0, mag - base)
    }

    /// Pure helper (not in a @ViewBuilder context) that classifies gaps around
    /// protected zones (Finder left, right zone = min-divider + mins + Trash)
    /// vs. main content so fillWidth spreads only the main icons while protected
    /// separations stay at the user's Spacing value. Also pre-computes exact
    /// resting centers for magnification.
    private func computeLayoutGaps(avail: CGFloat, scaledIcon: CGFloat, scale: CGFloat, leadPadForCalc: CGFloat) -> (userGap: CGFloat, fillGap: CGFloat, restingCenters: [UUID: CGFloat]) {
        let slots = renderedSlots
        let n = max(1, slots.count)
        let userG: CGFloat = spacing * scale
        var fillG: CGFloat = userG
        var centers: [UUID: CGFloat] = [:]
        if n > 0 {
            let interior = max(0, avail - CGFloat(isVertical ? prefs.effectivePaddingTop + prefs.effectivePaddingBottom : prefs.effectivePaddingLeft + prefs.effectivePaddingRight))
            let iconCount = slots.filter { slotOccupiesIconSpace($0) }.count
            if prefs.fillWidth && n > 1 && iconCount > 1 {
                var fixedSum: CGFloat = 0
                var numF: Int = 0
                for ii in 0..<(n - 1) {
                    let p = slots[ii]
                    let nx = slots[ii + 1]
                    if shouldUseUserGap(between: p, and: nx) {
                        fixedSum += userG
                    } else {
                        numF += 1
                    }
                }
                // Only icon slots contribute to scalable width for fill calc.
                let iconsT = CGFloat(iconCount) * scaledIcon
                let rem = max(0, interior - iconsT - fixedSum)
                fillG = numF > 0 ? rem / CGFloat(numF) : 0
            }
            var pos = leadPadForCalc
            for ii in 0..<n {
                let sl = slots[ii]
                let cellW = slotOccupiesIconSpace(sl) ? scaledIcon : customDividerCellWidth
                let cen = pos + cellW / 2
                if case .item(let it) = sl {
                    centers[it.id] = cen
                } else if case .runningApp(let r) = sl {
                    centers[r.id] = cen
                }
                if ii < n - 1 {
                    let g = shouldUseUserGap(between: sl, and: slots[ii + 1]) ? userG : fillG
                    pos += cellW + g
                }
            }
        }
        return (userG, fillG, centers)
    }

    var body: some View {
        dockContent
    }

    private var dockContent: some View {
        GeometryReader { proxy in
            let avail = isVertical ? proxy.size.height : proxy.size.width
            let scale = effectiveScale(in: avail)
            let scaledIcon = iconSize * scale
            let leadPadForCalc = CGFloat(isVertical ? prefs.effectivePaddingTop : prefs.effectivePaddingLeft) + headroomExtra

            let (userGap, fillGap, restingIDToCenter) = computeLayoutGaps(
                avail: avail,
                scaledIcon: scaledIcon,
                scale: scale,
                leadPadForCalc: leadPadForCalc
            )

            // Compute the actual visual bar width so the dock chrome background resizes dynamically
            // to the current number of items + custom dividers (no huge empty gaps on right).
            let barWidth: CGFloat = {
                var packed: CGFloat = 0
                for (i, slot) in renderedSlots.enumerated() {
                    let w = slotOccupiesIconSpace(slot) ? scaledIcon : customDividerCellWidth
                    packed += w
                    if i < renderedSlots.count - 1 {
                        let g = shouldUseUserGap(between: slot, and: renderedSlots[i + 1]) ? userGap : fillGap
                        packed += g
                    }
                }
                return CGFloat(prefs.effectivePaddingLeft) + packed + CGFloat(prefs.effectivePaddingRight)
            }()

            // Current max mag scale from hover (Gaussian on resting centers). Drive dynamic
            // chrome size so background bar itself grows in thickness/width with icons (native match).
            let currentMaxScale: CGFloat = {
                guard prefs.magnifyOnHover, let hp = hoverPoint else { return 1 }
                let mouse = isVertical ? hp.y : hp.x
                var m: CGFloat = 1
                for (_, c) in restingIDToCenter {
                    let d = abs(mouse - c)
                    let sig = scaledIcon * 1.6
                    let g = exp(-(d * d) / (2 * sig * sig))
                    let ms = max(1.0, magnifyMax / scaledIcon)
                    let s = 1 + (ms - 1) * g
                    if s > m { m = s }
                }
                return m
            }()
            let extraPerp: CGFloat = prefs.magnifyOnHover ? max(0, (currentMaxScale - 1) * (scaledIcon / 2)) : 0
            let dynamicThickness = restingThickness + extraPerp

            // Live along-axis packed width using each slot's *current* magnified cell size
            // (instead of base scaledIcon). This ensures the left and right padding
            // (effectivePaddingLeft/Right baked into the chrome) stay *exactly* the same
            // as in the non-hover resting state, even as end icons grow and push neighbors.
            let livePacked: CGFloat = {
                var sum: CGFloat = 0
                let slots = renderedSlots
                for (i, slot) in slots.enumerated() {
                    let baseCell: CGFloat = slotOccupiesIconSpace(slot) ? scaledIcon : customDividerCellWidth
                    var scale: CGFloat = 1.0
                    if case .item(let it) = slot, let c = restingIDToCenter[it.id] {
                        let mouse = isVertical ? (hoverPoint?.y ?? 0) : (hoverPoint?.x ?? 0)
                        let dist = abs(mouse - c)
                        let sig = scaledIcon * 1.6
                        let g = exp(-(dist * dist) / (2 * sig * sig))
                        let maxS = max(1.0, magnifyMax / scaledIcon)
                        scale = 1 + (maxS - 1) * g
                    } else if case .runningApp(let r) = slot, let c = restingIDToCenter[r.id] {
                        let mouse = isVertical ? (hoverPoint?.y ?? 0) : (hoverPoint?.x ?? 0)
                        let dist = abs(mouse - c)
                        let sig = scaledIcon * 1.6
                        let g = exp(-(dist * dist) / (2 * sig * sig))
                        let maxS = max(1.0, magnifyMax / scaledIcon)
                        scale = 1 + (maxS - 1) * g
                    }
                    let liveCell = slotOccupiesIconSpace(slot) ? max(baseCell, baseCell * scale) : baseCell
                    sum += liveCell
                    if i < slots.count - 1 {
                        let g = shouldUseUserGap(between: slot, and: slots[i + 1]) ? userGap : fillGap
                        sum += g
                    }
                }
                return sum
            }()
            let dynamicBarAlong = CGFloat(prefs.effectivePaddingLeft) + livePacked + CGFloat(prefs.effectivePaddingRight)

            ZStack(alignment: dockAlignment) {
                // The chrome bar (with icons overlaid directly on it for perfect
                // v/h centering inside the visual container). We wrap it in a
                // full-size .frame using barPlacementAlignment so narrow docks
                // are centered on the long axis while still flush to the edge.
                // This fixes both the "icons not centered in container" bug and
                // ensures the dock is always visible.
                let chrome = dockChrome
                    .frame(
                        width: isVertical ? dynamicThickness : (prefs.fillWidth ? nil : dynamicBarAlong),
                        height: isVertical ? (prefs.fillWidth ? nil : dynamicBarAlong) : dynamicThickness
                    )
                    .overlay(alignment: .center) {
                        Group {
                            if isVertical {
                                let hPad = CGFloat(prefs.effectivePaddingLeft)
                                VStack(spacing: 0) { iconRow(iconSize: scaledIcon, userGap: userGap, fillGap: fillGap) }
                                    .padding(.top, CGFloat(prefs.effectivePaddingTop))
                                    .padding(.bottom, CGFloat(prefs.effectivePaddingBottom))
                                    .padding(.leading, hPad)
                                    .padding(.trailing, hPad)
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        editDockContextMenu
                                    }
                            } else {
                                let vPad = CGFloat(prefs.effectivePaddingTop)
                                HStack(spacing: 0) { iconRow(iconSize: scaledIcon, userGap: userGap, fillGap: fillGap) }
                                    .padding(.top, vPad)
                                    .padding(.bottom, vPad)
                                    .padding(.leading, CGFloat(prefs.effectivePaddingLeft))
                                    .padding(.trailing, CGFloat(prefs.effectivePaddingRight))
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        editDockContextMenu
                                    }
                            }
                        }
                    }
                    .contextMenu {
                        editDockContextMenu
                    }

                chrome
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: barPlacementAlignment)

                if prefs.isEditingLayout {
                    EditModePill()
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: oppositeAlignment)
                }
                if prefs.isEditingDividers {
                    DividerEditPill(exitAction: { prefs.isEditingDividers = false })
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: oppositeAlignment)

                    // Palette for creating new dividers (tap to add at end; visual source of the bubble style)
                    DividerPalette(
                        isVertical: isVertical,
                        onAddAtEnd: {
                            let last = library.items.last?.id
                            library.insertDivider(after: last)
                        }
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isVertical ? .topLeading : .bottomLeading)
                    .offset(x: isVertical ? 0 : 0, y: isVertical ? 40 : -40) // park beside the exit pill a bit
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: dockAlignment)
            .environment(\.dockRestingCenters, restingIDToCenter)
        }
        .ignoresSafeArea()
        .coordinateSpace(name: "dock")
        .onContinuousHover(coordinateSpace: .named("dock")) { phase in
            switch phase {
            case .active(let p):
                // Animate only the enter transition (nil → point) so icons
                // spring up to magnified size on first hover. Subsequent
                // continuous moves bypass the animation so the magnification
                // tracks the cursor 1:1 without spring lag.
                if hoverPoint == nil {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                        hoverPoint = p
                    }
                } else {
                    hoverPoint = p
                }
                updateTooltipFor(point: p)
            case .ended:
                // Animate the exit so icons spring back down smoothly.
                withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                    hoverPoint = nil
                }
                DockTooltipPanel.shared.hideAll()
            }
        }
        .environmentObject(dragState)
        .environment(\.dockHoverPoint, hoverPoint)
        .environment(\.dockIsVertical, isVertical)
        .environment(\.dockMagnifyEnabled, prefs.magnifyOnHover)
        .environment(\.dockMagnifyMax, magnifyMax)
        .environment(\.dockLeadingPad, CGFloat(isVertical ? prefs.effectivePaddingTop : prefs.effectivePaddingLeft) + headroomExtra)
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

        // 1. Pinned regular apps, folders, Finder, and Trash (via DockItemView)
        let items = renderedItems
        for item in items {
            if let f = frames[item.id], f.insetBy(dx: -pad, dy: -pad).contains(point) {
                picked = (item.id, itemLabel(item))
                break
            }
        }

        // 2. Running / recent (unpinned) apps — now participate in hover/magnify too
        if picked == nil {
            for entry in runningApps.apps {
                if let f = frames[entry.id], f.insetBy(dx: -pad, dy: -pad).contains(point) {
                    picked = (entry.id, entry.name)
                    break
                }
            }
        }

        // 3. Minimized window tiles (show window title, falling back to app name)
        if picked == nil {
            for win in minimized.windows {
                if let f = frames[win.id], f.insetBy(dx: -pad, dy: -pad).contains(point) {
                    let label = win.title.isEmpty ? win.appName : win.title
                    picked = (win.id, label)
                    break
                }
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

    // MARK: - Variable-gap layout helpers (fix for massive protected-zone gaps)

    /// Returns true for gaps that must stay at the user's Spacing (small/natural
    /// separation): after Finder (left protected), before/around/inside the right
    /// protected zone (min-divider, minimized tiles, Trash). All other gaps (main
    /// pinned + running) use the fill/auto value when fillWidth is enabled.
    private func shouldUseUserGap(between prev: DockSlot, and next: DockSlot) -> Bool {
        if isLeftProtectedSlot(prev) || isRightProtectedSlot(next) {
            return true
        }
        if isRightProtectedSlot(prev) && isRightProtectedSlot(next) {
            return true
        }
        return false
    }

    private func isLeftProtectedSlot(_ s: DockSlot) -> Bool {
        if case .item(let it) = s { return it.id == Self.finderID }
        return false
    }

    private func isRightProtectedSlot(_ s: DockSlot) -> Bool {
        if case .item(let it) = s { return it.id == Self.trashID }
        if case .divider = s { return true }
        if case .minimized = s { return true }
        if case .customDivider = s { return true } // visual dividers use user spacing, protected from fillWidth spreading
        return false
    }

    /// Returns true for slots that represent full-size icons (apps, folders,
    /// running, minimized). Custom and system dividers use a narrow fixed
    /// cell so they act as thin visual splits without "costing" an icon slot.
    private func slotOccupiesIconSpace(_ s: DockSlot) -> Bool {
        switch s {
        case .item, .runningApp, .minimized:
            return true
        case .divider, .runningDivider, .customDivider:
            return false
        }
    }

    /// The fixed visual cell width (points) allocated to a custom divider slot.
    /// The bubble itself is even narrower and centered inside it.
    private var customDividerCellWidth: CGFloat { 8 }

    @ViewBuilder private func iconRow(iconSize: CGFloat, userGap: CGFloat, fillGap: CGFloat) -> some View {
        let slots = renderedSlots
        let nn = slots.count
        ForEach(Array(slots.enumerated()), id: \.element.id) { idx, slot in
            Group {
                slotContent(for: slot, index: idx, iconSize: iconSize, spacingForFallback: fillGap, userGap: userGap, fillGap: fillGap)
                if idx < nn - 1 {
                    let g = shouldUseUserGap(between: slot, and: slots[idx + 1]) ? userGap : fillGap
                    Color.clear
                        .frame(width: isVertical ? 0 : g, height: isVertical ? g : 0)
                }
            }
        }
    }

    @ViewBuilder private func slotContent(for slot: DockSlot, index: Int, iconSize: CGFloat, spacingForFallback: CGFloat, userGap: CGFloat, fillGap: CGFloat) -> some View {
        switch slot {
        case .item(let item):
            DockItemView(
                item: item,
                index: index,
                iconSize: iconSize,
                spacing: spacingForFallback,
                dragState: dragState
            )
        case .runningApp(let entry):
            RunningAppTileView(entry: entry, iconSize: iconSize, index: index, spacing: spacingForFallback)
        case .minimized(let window):
            MinimizedTileView(window: window, iconSize: iconSize, isVertical: isVertical)
        case .divider, .runningDivider:
            let dSpacing = isRightProtectedSlot(slot) ? userGap : fillGap
            DockDivider(isVertical: isVertical, iconSize: iconSize, spacing: dSpacing)
        case .customDivider(let d):
            let dSpacing = userGap // always user spacing around custom visual dividers
            BubbleDividerView(isVertical: isVertical, iconSize: iconSize, spacing: dSpacing, divider: d)
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
    let isVertical: Bool
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        let cellW = isVertical ? iconSize : iconSize
        let cellH = isVertical ? iconSize : iconSize
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

            // Small app-icon badge in the corner so the user knows which app
            // the thumbnail belongs to — mirrors macOS Mission Control style.
            Image(nsImage: window.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize * 0.42, height: iconSize * 0.42)
                .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                .offset(x: 2, y: 2)
        }
        .frame(width: cellW, height: cellH)
        .contentShape(Rectangle())
        .onTapGesture { MinimizedMonitor.shared.unminimize(window) }
        .trackItemFrame(id: window.id)
        .help(prefs.labelMode == .tooltip ? "" : (window.title.isEmpty ? window.appName : window.title))
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
    @StateObject private var runningMonitor = RunningAppsMonitor.shared

    @Environment(\.dockHoverPoint) private var hoverPoint
    @Environment(\.dockIsVertical) private var isVertical
    @Environment(\.dockMagnifyEnabled) private var magnifyEnabled
    @Environment(\.dockMagnifyMax) private var magnifyMax
    @Environment(\.dockLeadingPad) private var leadingPad
    @Environment(\.dockRestingCenters) private var restingCenters

    /// Resting center of this item along the dock axis. Matches the formula
    /// used by DockItemView so that recent-app tiles participate in the exact
    /// same per-icon Gaussian magnification (and neighbor-push) system.
    private var restingCenterAlongAxis: CGFloat {
        if let c = restingCenters[entry.id] {
            return c
        }
        return leadingPad + CGFloat(index) * (iconSize + spacing) + iconSize / 2
    }

    private var magnificationScale: CGFloat {
        guard magnifyEnabled, let hp = hoverPoint else { return 1 }
        let mouse = isVertical ? hp.y : hp.x
        let dist = abs(mouse - restingCenterAlongAxis)
        // Falloff over ~2.5x the icon size (identical to DockItemView)
        let sigma = iconSize * 1.6
        let g = exp(-(dist * dist) / (2 * sigma * sigma))
        let maxScale = max(1.0, magnifyMax / iconSize)
        return 1 + (maxScale - 1) * g
    }

    private var state: AppRunningState {
        // Ephemeral tiles are definitionally running; frontmost is what matters for strong vs subtle.
        let st = runningMonitor.runningState(for: entry.path)
        return AppRunningState(isRunning: true, isFrontmost: st.isFrontmost)
    }

    var body: some View {
        let magScale = magnificationScale

        // Normalized to the same iconSize-centered cell as DockItemView so all icons
        // (pinned + running + minimized) sit on the exact same vertical and horizontal center line.
        ZStack {
            ZStack {
                let scale = magScale
                let displaySize = iconSize * scale
                let cellW = isVertical ? iconSize : max(iconSize, displaySize)
                let cellH = isVertical ? max(iconSize, displaySize) : iconSize
                Color.clear
                    .frame(width: cellW, height: cellH)
                    .overlay(alignment: .center) {
                        // Native Liquid Glass magnification for strongly hovered running apps.
                        // Deleted old custom shadow + lift code.
                        let isStronglyMagnified = magScale > 1.15
                        let baseIcon = Image(nsImage: entry.icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: displaySize, height: displaySize)
                            .activeGlow(isRunning: state.isRunning, isFrontmost: state.isFrontmost, style: prefs.indicatorStyle)

                        let iconView: AnyView = if isStronglyMagnified {
                            AnyView(
                                LiquidGlassEffect(cornerRadius: 6)
                                    .frame(width: displaySize, height: displaySize)
                                    .overlay(baseIcon)
                            )
                        } else {
                            AnyView(baseIcon)
                        }
                        iconView
                            .animation(.spring(response: 0.18, dampingFraction: 0.75), value: scale)
                    }
            }
            .trackItemFrame(id: entry.id)

            if prefs.indicatorStyle == .dot {
                if state.isFrontmost {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color(nsColor: NSColor.controlAccentColor).opacity(0.85))
                        .frame(width: 12, height: 2)
                        .offset(y: iconSize / 2 + 4)
                } else {
                    Circle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 4, height: 4)
                        .offset(y: iconSize / 2 + 4)
                }
            }
        }
        .frame(width: isVertical ? iconSize : nil, height: isVertical ? nil : iconSize, alignment: .center)
        .contentShape(Rectangle())
        .onTapGesture { RunningAppsMonitor.shared.activate(entry) }
        .help(prefs.labelMode == .tooltip ? "" : entry.name)
    }
}

/// Thin 1pt divider line that visually separates dock sections:
/// (pinned apps) — runningDivider — (running apps) — divider — (minimized windows).
/// To create clear visual breaks, we apply `2 × spacing` (where `spacing` is
/// the normal effective spacing or fill gap for that divider) as padding on
/// *both* sides along the dock's primary axis. Combined with the adjacent
/// layout gap (1×) inserted before/after the divider slot in the iconRow,
/// this yields an effective gap of 3× the relevant spacing value before the
/// line and 3× after the line. The line itself stays 1pt thin and is centered
/// on the cross axis within an icon-sized footprint. Works for both horizontal
/// and vertical docks. Respects prefs.effectiveSpacing, scale, and fillWidth.
struct DockDivider: View {
    let isVertical: Bool
    let iconSize: CGFloat
    let spacing: CGFloat

    var body: some View {
        let extra = 2 * spacing
        Group {
            if isVertical {
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: iconSize * 0.6, height: 1)
                    .padding(.vertical, extra)
                    .frame(width: iconSize, alignment: .center)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 1, height: iconSize * 0.6)
                    .padding(.horizontal, extra)
                    .frame(height: iconSize, alignment: .center)
            }
        }
        .frame(height: iconSize, alignment: .center) // ensure the divider line is centered in the icon cell area
        .allowsHitTesting(false)
    }
}

/// Premium "bubble" visual divider that splits the dock surface with a frosted
/// glass pill / capsule aesthetic (inspired by macOS Stage Manager separators,
/// liquid glass, and inset depth). Narrow fixed-width cell, centered bubble.
/// In Edit Dock mode the bubble is interactive (tap to delete).
struct BubbleDividerView: View {
    let isVertical: Bool
    let iconSize: CGFloat
    let spacing: CGFloat
    let divider: DockDividerBar

    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var library: AppLibrary

    var body: some View {
        let bubbleThickness: CGFloat = max(3, min(7, iconSize * 0.12))
        let bubbleLength: CGFloat = iconSize * 0.72

        let bubbleShape = Capsule(style: .continuous)

        let glassBubble = ZStack {
            // Frosted glass base (behind-window blur for depth)
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(bubbleShape)
                .opacity(0.85)

            // Subtle inner tint / liquid highlight
            bubbleShape
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.18),
                            Color.white.opacity(0.04),
                            Color.black.opacity(0.06)
                        ],
                        startPoint: isVertical ? .leading : .top,
                        endPoint: isVertical ? .trailing : .bottom
                    )
                )
                .blendMode(.plusLighter)

            // Crisp inset rim for "splitting" the dock surface
            bubbleShape
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.55), Color.white.opacity(0.15)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )

            // Very subtle center "seam" line for extra split character (horizontal dock)
            if !isVertical {
                Rectangle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 0.6)
                    .padding(.vertical, bubbleLength * 0.22)
            }
        }
        .frame(
            width: isVertical ? bubbleLength : bubbleThickness,
            height: isVertical ? bubbleThickness : bubbleLength
        )
        .shadow(color: .black.opacity(0.28), radius: 2.5, x: 0, y: 1)
        .shadow(color: Color.accentColor.opacity(0.12), radius: 5, x: 0, y: 0) // soft accent glow
        .overlay(
            // In edit mode, a small remove affordance on hover/tap
            Group {
                if prefs.isEditingDividers {
                    Button {
                        library.removeDivider(id: divider.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 1)
                            .padding(1)
                    }
                    .buttonStyle(.plain)
                    .offset(x: isVertical ? 0 : 6, y: isVertical ? 6 : 0)
                }
            }
        )

        Group {
            if isVertical {
                glassBubble
                    .padding(.vertical, max(0, spacing - 1))
                    .frame(width: iconSize, alignment: .center)
            } else {
                glassBubble
                    .padding(.horizontal, max(0, spacing - 1))
                    .frame(height: iconSize, alignment: .center)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if prefs.isEditingDividers {
                library.removeDivider(id: divider.id)
            }
        }
        .trackItemFrame(id: divider.id) // so drag-to-insert gap detection can see it
        .allowsHitTesting(prefs.isEditingDividers) // normal mode: purely visual, no hit
    }
}

private struct EditModePill: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 11, weight: .semibold))
            Text("Edit Layout")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.accentColor)
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)
        )
        .opacity(pulse ? 1.0 : 0.7)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
        .allowsHitTesting(false)
    }
}

/// Clickable pill shown only in "Edit Dock" (divider) mode. Tapping exits the mode.
private struct DividerEditPill: View {
    let exitAction: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: exitAction) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 11, weight: .semibold))
                Text("Exit Edit Dock")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)
            )
            .opacity(pulse ? 1.0 : 0.85)
        }
        .buttonStyle(.plain)
        .onAppear { withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

/// Floating mini-palette that appears in Edit Dock mode. Provides the source
/// "bubble" visual and quick "add at end" action. (Full drag-to-gap supported
/// via gap zones below; this is the origination point.)
private struct DividerPalette: View {
    let isVertical: Bool
    let onAddAtEnd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Mini sample of the exact bubble style
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.22))
                .frame(width: isVertical ? 18 : 4, height: isVertical ? 4 : 18)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.5), lineWidth: 0.6)
                )
                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 0.5)

            Text("Add Divider")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))

            Button(action: onAddAtEnd) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Add a new visual divider at the end of your pinned items")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.45))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 2)
    }
}

/// Compact liquid-glass "Empty" pill for quick trash emptying on right/ctrl-click.
/// Positioned in the inward headroom above (or beside for vertical docks) the Trash icon.
private struct EmptyTrashPill: View {
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("Empty")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .background(
            Capsule(style: .continuous)
                .fill(Color(.sRGB, red: 0.82, green: 0.18, blue: 0.22, opacity: 0.92))
                .background(
                    VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                        .clipShape(Capsule(style: .continuous))
                        .opacity(0.55)
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.7)
        )
        .shadow(color: Color.black.opacity(0.32), radius: 3.5, x: 0, y: 1.5)
        .scaleEffect(pressed ? 0.90 : 1.0)
        .onLongPressGesture(minimumDuration: 0.01, maximumDistance: 30, pressing: { p in pressed = p }, perform: {})
        .animation(.spring(response: 0.14, dampingFraction: 0.55), value: pressed)
    }
}

// MARK: - Magnification environment

private struct DockHoverPointKey: EnvironmentKey { static let defaultValue: CGPoint? = nil }
private struct DockIsVerticalKey: EnvironmentKey { static let defaultValue: Bool = false }
private struct DockMagnifyEnabledKey: EnvironmentKey { static let defaultValue: Bool = true }
private struct DockMagnifyMaxKey: EnvironmentKey { static let defaultValue: CGFloat = 110 }
private struct DockLeadingPadKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct DockRestingCentersKey: EnvironmentKey { static let defaultValue: [UUID: CGFloat] = [:] }

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
    var dockRestingCenters: [UUID: CGFloat] {
        get { self[DockRestingCentersKey.self] }
        set { self[DockRestingCentersKey.self] = newValue }
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

    @State private var showFolderPopover: Bool = false
    @State private var folderFormProgress: CGFloat = 0
    @State private var showEmptyPill: Bool = false
    @EnvironmentObject var prefs: Preferences
    @StateObject private var runningMonitor = RunningAppsMonitor.shared
    @Environment(\.dockHoverPoint) private var hoverPoint
    @Environment(\.dockIsVertical) private var isVertical
    @Environment(\.dockMagnifyEnabled) private var magnifyEnabled
    @Environment(\.dockMagnifyMax) private var magnifyMax
    @Environment(\.dockLeadingPad) private var leadingPad
    @Environment(\.dockRestingCenters) private var restingCenters

    /// Resting center of this item along the dock axis. Derived purely from
    /// layout inputs (padding + index*(icon+spacing) + icon/2) so that
    /// neighbor magnification — which reflows the HStack/VStack — does NOT
    /// change this item's own scale. (Previously a live `frameInDock` from
    /// GeometryReader was tried but created a feedback loop with magnification.)
    private var restingCenterAlongAxis: CGFloat {
        if let c = restingCenters[item.id] {
            return c
        }
        return leadingPad + CGFloat(index) * (iconSize + spacing) + iconSize / 2
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

    /// Alignment for positioning the transient "Empty" pill relative to this
    /// item's icon cell, pointing into the inward magnification headroom.
    private var pillAlignment: Alignment {
        switch prefs.edge {
        case .bottom: return .top
        case .top: return .bottom
        case .left: return .trailing
        case .right: return .leading
        }
    }

    /// Offset to push the pill out of the icon cell and into the inward
    /// headroom for the current dock edge. Keeps pill from overlapping the icon.
    private var pillOffset: CGSize {
        let gap: CGFloat = 6
        let pillExtent: CGFloat = 16
        switch prefs.edge {
        case .bottom: return CGSize(width: 0, height: -(pillExtent + gap))
        case .top: return CGSize(width: 0, height: (pillExtent + gap))
        case .left: return CGSize(width: (pillExtent + gap), height: 0)
        case .right: return CGSize(width: -(pillExtent + gap), height: 0)
        }
    }

    var body: some View {
        let isDragging = dragState.draggingID == item.id
        let isHoverTarget = dragState.hoverTargetID == item.id
        let isFormingFolder = dragState.folderForming == item.id
        let magScale = magnificationScale
        // While the dragged item is outside the dock, collapse its layout cell
        // so neighbors close the gap — matches native Dock drag-off behavior.
        let isDetached = isDragging && dragState.draggedOutside && !DockView.isReservedID(item.id)

        // Icon cell is the primary laid-out item (normalized height/width across all slot types).
        // Labels and indicators are attached as overlays so they do not shift the icon's center
        // within the dock bar. This guarantees all icons (pinned, running, minimized) are
        // perfectly vertically and horizontally centered inside the visual dock chrome.
        ZStack {
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
                    .overlay(alignment: .center) {
                        // Native Liquid Glass magnification for strongly hovered icons.
                        // Deleted all old custom shadow + manual lift code.
                        let isStronglyMagnified = magScale > 1.15
                        let baseIcon = iconContent(size: displaySize)
                            .frame(width: displaySize, height: displaySize)
                            .opacity(isDetached ? 0 : (isDragging ? 0.85 : 1.0))

                        let magnifiedIcon = isStronglyMagnified
                            ? AnyView(
                                LiquidGlassEffect(cornerRadius: 6)
                                    .frame(width: displaySize, height: displaySize)
                                    .overlay(baseIcon)
                            )
                            : AnyView(baseIcon)

                        magnifiedIcon
                            // Badge rides the actual displayed icon's top-right
                            // corner so it stays pinned to the corner whether
                            // the icon is at rest or magnified.
                            .overlay(alignment: .topTrailing) {
                                badgeOverlay(displaySize: displaySize)
                            }
                            .animation(.spring(response: 0.18, dampingFraction: 0.75), value: scale)
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
            .overlay(alignment: pillAlignment) {
                if DockView.isTrash(item) {
                    EmptyTrashPill(action: {
                        AppLibrary.shared.emptyTrashDirectly()
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                            showEmptyPill = false
                        }
                    })
                    .scaleEffect(showEmptyPill ? 1.0 : 0.55)
                    .opacity(showEmptyPill ? 1.0 : 0.0)
                    .offset(pillOffset)
                    .allowsHitTesting(showEmptyPill)
                    .animation(.spring(response: 0.28, dampingFraction: 0.76), value: showEmptyPill)
                }
            }
            .trackItemFrame(id: item.id)
            // iOS-style wiggle when in edit mode
            .modifier(WiggleModifier(active: dragState.wiggle && !isDragging))
            .offset(isDragging ? dragState.dragOffset : .zero)

            // Labels and indicators are overlays relative to the icon cell so they
            // never affect the vertical/horizontal centering of the icon square itself.
            if prefs.labelMode == .above {
                labelText
                    .offset(y: -(iconSize / 2 + 14))
            }
            if prefs.labelMode == .below {
                labelText
                    .offset(y: iconSize / 2 + 10)
            }
            if prefs.indicatorStyle == .dot {
                if isActive {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color(nsColor: NSColor.controlAccentColor).opacity(0.85))
                        .frame(width: 14, height: 2)
                        .offset(y: iconSize / 2 + 4)
                } else if isRunning {
                    Circle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 4, height: 4)
                        .offset(y: iconSize / 2 + 4)
                }
            }
        }
        .frame(width: isVertical ? iconSize : nil, height: isVertical ? nil : iconSize, alignment: .center)
        .coordinateSpace(name: "item-\(item.id)")
        .gesture(
            DragGesture(coordinateSpace: .named("dock"))
                .onChanged { value in
                    if dragState.draggingID != item.id {
                        dragState.draggingID = item.id
                        // Starting a drag on any item should dismiss any open folder popover
                        // (matches the "automatic dismissal on drag" behavior).
                        NotificationCenter.default.post(name: Notification.Name("FocusDock.CloseAllFolderPopovers"), object: nil)
                        NotificationCenter.default.post(name: Notification.Name("FocusDock.DismissTransientPills"), object: nil)
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
        // Ctrl-click (or right-click simulation) on Trash shows the compact liquid-glass
        // "Empty" pill above the icon in the inward headroom (primary quick action).
        // The regular context menu remains available as a secondary method.
        .simultaneousGesture(
            TapGesture()
                .modifiers(.control)
                .onEnded { _ in
                    if DockView.isTrash(item) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.78)) {
                            showEmptyPill = true
                        }
                    }
                }
        )
        .onTapGesture {
            // Any tap on any dock item dismisses transient pills (e.g. trash Empty pill)
            NotificationCenter.default.post(name: Notification.Name("FocusDock.DismissTransientPills"), object: nil)
            if dragState.wiggle {
                // Exit edit mode on tap in empty-ish area; for now, tapping launches
            }
            switch item {
            case .app(let a):
                // Tapping a regular app: close any open folder popovers (click-outside for other icons)
                NotificationCenter.default.post(name: Notification.Name("FocusDock.CloseAllFolderPopovers"), object: nil)
                library.launch(a)
            case .folder(let f):
                // Tapping a folder: post *with this folder's ID as object* so that THIS view's onReceive
                // will ignore the force-close (letting our toggle() decide open vs close), while any
                // OTHER folder's onReceive will still see a non-matching ID and close itself.
                // This fixes the regression where the global close was firing synchronously on the
                // same tap, forcing false then toggle true (causing flash or no-op).
                NotificationCenter.default.post(name: Notification.Name("FocusDock.CloseAllFolderPopovers"), object: f.id)
                showFolderPopover.toggle()
            }
        }
        .popover(isPresented: $showFolderPopover, arrowEdge: .top) {
            if case .folder(let f) = item {
                FolderPopover(folder: f)
                    .environmentObject(library)
                    .environmentObject(prefs)
            }
        }
        // Listen for global close requests (posted on any dock item tap or background) so that
        // tapping elsewhere in the dock automatically dismisses an open folder popover ("click outside").
        // When the notification's object matches *this* folder item's ID, it means the tap originated
        // on this folder itself; we skip the force-close so the .toggle() in onTapGesture can open
        // or close it cleanly. All other listeners (other folders or when object==nil) will close.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FocusDock.CloseAllFolderPopovers"))) { note in
            if let senderFolderID = note.object as? UUID,
               case .folder(let myFolder) = item,
               senderFolderID == myFolder.id {
                // Ignore: this folder's own tap will handle toggle()
                return
            }
            showFolderPopover = false
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FocusDock.DismissTransientPills"))) { _ in
            if showEmptyPill {
                showEmptyPill = false
            }
        }
        .contextMenu {
            if DockView.isTrash(item) {
                Button {
                    AppLibrary.shared.emptyTrashDirectly()
                } label: {
                    Label("Empty Trash", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder private func iconContent(size: CGFloat) -> some View {
        switch item {
        case .app(let a):
            Image(nsImage: a.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .activeGlow(isRunning: runningState.isRunning, isFrontmost: runningState.isFrontmost, style: prefs.indicatorStyle)
        case .folder(let f):
            FolderIconView(folder: f, size: size)
                .activeGlow(isRunning: runningState.isRunning, isFrontmost: runningState.isFrontmost, style: prefs.indicatorStyle)
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

    /// Centralized running/frontmost state for this DockItem (app or folder).
    /// Delegates to RunningAppsMonitor so that pinned-app launch/quit events
    /// (which now publish runningAppPaths) correctly trigger re-renders and
    /// differentiated subtle/strong indicators.
    private var runningState: AppRunningState {
        switch item {
        case .app(let a):
            return runningMonitor.runningState(for: a.path)
        case .folder(let f):
            return runningMonitor.runningState(for: f)
        }
    }

    /// True when the item (or any app inside a folder) has at least one running process.
    /// Used for the classic dot (or underline for frontmost) in .dot indicatorStyle,
    /// and to decide whether to render subtle glow in .glow style.
    private var isRunning: Bool {
        runningState.isRunning
    }

    /// True when this item (app or folder containing the frontmost app) is the
    /// currently frontmost application. Drives the stronger/brighter glow or
    /// underline bar.
    private var isActive: Bool {
        runningState.isFrontmost
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

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.5)
                )

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
    @StateObject private var runningMonitor = RunningAppsMonitor.shared
    @State private var editingName: Bool = false
    @State private var draftName: String = ""

    private var resolvedColumns: Int {
        if let c = folder.columns, c > 0 { return c }
        // Auto: roughly square-ish, capped at 5.
        let n = max(1, folder.apps.count)
        return min(5, max(1, Int(ceil(Double(n).squareRoot()))))
    }

    private let cellSize: CGFloat = 56

    var body: some View {
        // Use user's Spacing setting for gaps between icons (both columns and rows) so
        // folder popovers feel consistent with the main dock instead of oversized gaps.
        let spacing = CGFloat(prefs.effectiveSpacing)
        let cols = Array(repeating: GridItem(.fixed(cellSize), spacing: spacing), count: resolvedColumns)

        VStack(alignment: .leading, spacing: 10) {
            header
            LazyVGrid(columns: cols, alignment: .leading, spacing: spacing) {
                ForEach(folder.apps) { app in
                    folderAppCell(app)
                }
            }
        }
        // Use the same effective (scaled) padding values as the main dock for internal spacing consistency.
        // Popover now dynamically sizes to content (grid + header) + these paddings; no more
        // hardcoded +16 extras that caused large/uneven L/R padding or prevented nice shrinking for small folders.
        .padding(.top, prefs.effectivePaddingTop)
        .padding(.bottom, prefs.effectivePaddingBottom)
        .padding(.leading, prefs.effectivePaddingLeft)
        .padding(.trailing, prefs.effectivePaddingRight)
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
        VStack(spacing: 4) {
            if prefs.labelMode == .above {
                cellLabel(app)
            }
            let st = runningMonitor.runningState(for: app.path)
            Image(nsImage: app.icon).resizable().interpolation(.high)
                .frame(width: cellSize, height: cellSize)
                .activeGlow(isRunning: st.isRunning, isFrontmost: st.isFrontmost, style: prefs.indicatorStyle)
                .nativeToolTip(prefs.labelMode == .tooltip ? app.name : "")
            if prefs.labelMode == .below {
                cellLabel(app)
            }
        }
        .frame(width: cellSize)
        .contentShape(Rectangle())
        .onTapGesture { library.launch(app) }
    }

    private func cellLabel(_ app: AppEntry) -> some View {
        Text(app.name).font(.system(size: 10)).lineLimit(1)
            .frame(maxWidth: cellSize, alignment: .center)
            .multilineTextAlignment(.center)
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

/// ViewModifier that renders differentiated glows for the indicatorStyle == .glow case:
/// - Subtle glow for any running app (or folder containing running apps) that is NOT frontmost.
/// - Stronger, brighter, more prominent glow (larger radius, higher opacity, accent emphasis)
///   for the single frontmost / focused app (or folder containing the frontmost app).
/// Also used inside FolderPopover cells so each app icon inside an open folder
/// receives the appropriate subtle or strong treatment.
/// When style != .glow the modifier is a no-op (classic dots/underline handled separately).
struct ActiveGlowModifier: ViewModifier {
    let isRunning: Bool
    let isFrontmost: Bool
    let style: Preferences.IndicatorStyle

    func body(content: Content) -> some View {
        if style == .glow && (isRunning || isFrontmost) {
            // Use the live macOS system accent color (user's chosen highlight in
            // System Settings > Appearance) so the glow respects the theme exactly.
            // We use NSColor.controlAccentColor (dynamic) wrapped in Color(nsColor:)
            // and rely on Preferences' systemColorsDidChangeNotification observer
            // to bump _tick and force re-render of all dock items when the user
            // changes the accent color at runtime.
            let accent = Color(nsColor: NSColor.controlAccentColor)
            if isFrontmost {
                // Strong, prominent glow for the focused/frontmost item.
                // Layered shadows for a rich premium halo using accent + white highlights.
                content
                    .shadow(color: accent.opacity(0.58), radius: 5, x: 0, y: 0)
                    .shadow(color: Color.white.opacity(0.78), radius: 9, x: 0, y: 0)
                    .shadow(color: accent.opacity(0.32), radius: 18, x: 0, y: 0)
            } else {
                // Subtle, tasteful glow for any other running (but not focused) app/folder.
                content
                    .shadow(color: accent.opacity(0.26), radius: 5, x: 0, y: 0)
                    .shadow(color: Color.white.opacity(0.32), radius: 7, x: 0, y: 0)
            }
        } else {
            content
        }
    }
}

extension View {
    func activeGlow(isRunning: Bool, isFrontmost: Bool, style: Preferences.IndicatorStyle) -> some View {
        self.modifier(ActiveGlowModifier(isRunning: isRunning, isFrontmost: isFrontmost, style: style))
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

// MARK: - Dock Tooltip Panel (Liquid Glass Callout)

// Premium liquid-glass hover tooltip with integrated callout arrow.
// Uses NSHostingView + SwiftUI for modern rendering, .hudWindow blur clipped
// to a callout shape (rounded rect + arrow), subtle glass border, depth shadow,
// and spring scale+fade transitions. Positioned precisely above (or beside) the
// icon with the arrow pointing at its center. Respects all four dock edges.

enum TooltipPointDirection {
    case up, down, left, right

    var isHorizontal: Bool { self == .left || self == .right }
}

final class TooltipModel: ObservableObject {
    @Published var text: String = ""
    @Published var direction: TooltipPointDirection = .down
    @Published var isShowing: Bool = false
}

struct ArrowTriangle: Shape {
    var direction: TooltipPointDirection

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        switch direction {
        case .down:
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: w, y: 0))
            path.addLine(to: CGPoint(x: w / 2, y: h))
            path.closeSubpath()
        case .up:
            path.move(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: w / 2, y: 0))
            path.closeSubpath()
        case .left:
            path.move(to: CGPoint(x: w, y: 0))
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: 0, y: h / 2))
            path.closeSubpath()
        case .right:
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: w, y: h / 2))
            path.closeSubpath()
        }
        return path
    }
}

struct LiquidGlassTooltip: View {
    @ObservedObject var model: TooltipModel

    private let cornerRadius: CGFloat = 13
    private let arrowBase: CGFloat = 12
    private let arrowHeight: CGFloat = 7
    private let overlap: CGFloat = 1.0  // minimal intrusion so bubble does not overlap/cover the arrow
    private let hPadding: CGFloat = 11
    private let vPadding: CGFloat = 6

    private var arrowAlignment: Alignment {
        switch model.direction {
        case .down: return .bottom
        case .up: return .top
        case .left: return .leading
        case .right: return .trailing
        }
    }

    private var arrowPadding: EdgeInsets {
        let extra = arrowHeight - overlap
        switch model.direction {
        case .down: return EdgeInsets(top: 0, leading: 0, bottom: extra, trailing: 0)
        case .up: return EdgeInsets(top: extra, leading: 0, bottom: 0, trailing: 0)
        case .left: return EdgeInsets(top: 0, leading: extra, bottom: 0, trailing: 0)
        case .right: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: extra)
        }
    }

    private var arrowOffset: CGSize {
        let o: CGFloat = 0.5
        switch model.direction {
        case .down: return CGSize(width: 0, height: -o)
        case .up: return CGSize(width: 0, height: o)
        case .left: return CGSize(width: -o, height: 0)
        case .right: return CGSize(width: o, height: 0)
        }
    }

    var body: some View {
        let textView = Text(model.text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.primary)
            .shadow(color: .black.opacity(0.38), radius: 0.6, x: 0, y: 0.4)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, hPadding)
            .padding(.vertical, vPadding)

        textView
            .background(bubbleBackground)
            .overlay(arrowOverlay, alignment: arrowAlignment)
            .padding(arrowPadding)
            .scaleEffect(model.isShowing ? 1.0 : 0.92)
            .opacity(model.isShowing ? 1.0 : 0.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: model.isShowing)
    }

    private var bubbleBackground: some View {
        LiquidGlassEffect(cornerRadius: cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 4)
    }

    private var arrowOverlay: some View {
        let tri = ArrowTriangle(direction: model.direction)
        let sz = model.direction.isHorizontal
            ? CGSize(width: arrowHeight, height: arrowBase)
            : CGSize(width: arrowBase, height: arrowHeight)
        return tri
            .fill(Color.clear)
            .background(
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                    .clipShape(tri)
            )
            .overlay(tri.stroke(Color.white.opacity(0.20), lineWidth: 0.7))
            .frame(width: sz.width, height: sz.height)
            .offset(arrowOffset)
    }
}

final class DockTooltipPanel {
    static let shared = DockTooltipPanel()
    static weak var dockWindow: NSWindow?

    private var panel: NSPanel?
    private var hostingView: NSHostingView<LiquidGlassTooltip>?
    private let tooltipModel = TooltipModel()
    private var currentOwner: UUID?

    private func idealSize(for text: String) -> CGSize {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let ns = text as NSString
        let bounds = ns.boundingRect(
            with: NSSize(width: 900, height: 200),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs,
            context: nil
        )
        let w = ceil(bounds.width) + hPadding * 2
        let h = ceil(bounds.height) + vPadding * 2
        return CGSize(width: max(40, w), height: max(22, h))
    }

    private let hPadding: CGFloat = 11
    private let vPadding: CGFloat = 6

    func show(text: String, near id: UUID, edge: Preferences.Edge) {
        guard !text.isEmpty,
              let dockWin = Self.dockWindow,
              let itemFrame = ItemFrameRegistry.shared.frames[id] else { return }

        let direction: TooltipPointDirection = {
            switch edge {
            case .bottom: return .down
            case .top: return .up
            case .left: return .left
            case .right: return .right
            }
        }()

        ensurePanel()
        guard let panel = panel else { return }

        let body = idealSize(for: text)
        let arrowH: CGFloat = 7
        let ov: CGFloat = 1.0
        let total: CGSize
        switch direction {
        case .down, .up:
            total = CGSize(width: body.width, height: body.height + arrowH - ov)
        case .left, .right:
            total = CGSize(width: body.width + arrowH - ov, height: body.height)
        }

        let dockF = dockWin.frame
        let ch = dockWin.contentView?.bounds.height ?? dockF.height
        let contentTopScreenY = dockF.minY + ch
        let contentLeftScreenX = dockF.minX
        let icX = contentLeftScreenX + itemFrame.midX
        let icY = contentTopScreenY - itemFrame.midY
        let gap: CGFloat = 4.0  // slightly more clearance for new glass bubble + legacy arrow hybrid

        let pw = total.width
        let ph = total.height
        let px: CGFloat
        let py: CGFloat
        switch direction {
        case .down:
            // Anchor to the icon's actual top edge (inward for bottom dock) using its tracked frame.
            // This ensures the liquid-glass pointer/tooltip always has proper clearance above the
            // icon graphic itself (including for folders when their popover is open and for all
            // label modes / paddings), rather than assuming the icon is flush against the dock
            // window's outer edge.
            let iconTopScreenY = contentTopScreenY - itemFrame.minY
            let tipY = iconTopScreenY + gap
            px = icX - pw / 2
            py = tipY
        case .up:
            let iconBottomScreenY = contentTopScreenY - itemFrame.maxY
            let tipY = iconBottomScreenY - gap
            px = icX - pw / 2
            py = tipY - ph
        case .left:
            let iconRightScreenX = contentLeftScreenX + itemFrame.maxX
            let tipX = iconRightScreenX + gap
            px = tipX
            py = icY - ph / 2
        case .right:
            let iconLeftScreenX = contentLeftScreenX + itemFrame.minX
            let tipX = iconLeftScreenX - gap
            px = tipX - pw
            py = icY - ph / 2
        }

        panel.setFrame(NSRect(x: px, y: py, width: pw, height: ph), display: true)

        tooltipModel.text = text
        tooltipModel.direction = direction
        currentOwner = id

        if !panel.isVisible {
            tooltipModel.isShowing = false
            panel.orderFront(nil)
            DispatchQueue.main.async {
                self.tooltipModel.isShowing = true
            }
        }
    }

    func hideIfOwner(_ id: UUID) {
        guard currentOwner == id else { return }
        hideAll()
    }

    func hideAll() {
        currentOwner = nil
        guard let p = panel else { return }
        tooltipModel.isShowing = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            guard let self = self, !self.tooltipModel.isShowing else { return }
            p.orderOut(nil)
        }
    }

    private func ensurePanel() {
        if panel != nil { return }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 32),
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

        let host = NSHostingView(rootView: LiquidGlassTooltip(model: tooltipModel))
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor

        p.contentView = host
        panel = p
        hostingView = host
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

/// Official native Liquid Glass (macOS 26+).
/// Falls back to the legacy .popover VisualEffectView on older macOS.
/// This is what gives the real system Dock / floating UI "Liquid Glass" look
/// with proper depth, refraction and dynamic lighting.
struct LiquidGlassEffect: NSViewRepresentable {
    var cornerRadius: CGFloat = 24

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            return glass
        } else {
            let v = NSVisualEffectView()
            v.material = .popover
            v.blendingMode = .behindWindow
            v.state = .active
            return v
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 26.0, *) {
            if let glass = nsView as? NSGlassEffectView {
                glass.cornerRadius = cornerRadius
            }
        } else {
            if let v = nsView as? NSVisualEffectView {
                v.material = .popover
                v.blendingMode = .behindWindow
            }
        }
    }
}
