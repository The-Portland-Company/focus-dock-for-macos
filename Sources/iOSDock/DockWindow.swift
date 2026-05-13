import SwiftUI
import AppKit

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
    private var snapWorkItem: DispatchWorkItem?

    convenience init() {
        let content = DockView()
            .environmentObject(AppLibrary.shared)
            .environmentObject(Preferences.shared)
        let host = DockHostingController(rootView: content)

        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 130),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.contentViewController = host

        self.init(window: win)
        win.delegate = self
        applyLayout()
        prefsObserver = NotificationCenter.default.addObserver(
            forName: Preferences.changed, object: nil, queue: .main
        ) { [weak self] _ in self?.applyLayout() }
    }

    /// Compute the proper window size and origin for the configured edge.
    func applyLayout() {
        guard let win = window, let screen = (NSScreen.main ?? win.screen) else { return }
        let edge = Preferences.shared.edge
        let isEditing = Preferences.shared.isEditingLayout
        win.isMovableByWindowBackground = isEditing
        win.isMovable = isEditing

        let prefs = Preferences.shared
        // Flush works on any edge now — uses full screen.frame and ignores
        // edgeOffset on that edge. (Pref key kept as "flushBottom" for storage.)
        let useFlush = prefs.flushBottom
        let area: NSRect = useFlush ? screen.frame : screen.visibleFrame

        let pt = CGFloat(prefs.paddingTop), pb = CGFloat(prefs.paddingBottom)
        let pl = CGFloat(prefs.paddingLeft), pr = CGFloat(prefs.paddingRight)
        let offset = CGFloat(prefs.edgeOffset)

        let count = max(1, AppLibrary.shared.items.count + (prefs.showFinder ? 1 : 0))
        let iconSize = CGFloat(prefs.iconSize)
        let spacing = CGFloat(prefs.spacing)
        let isVerticalEdge = (edge == .left || edge == .right)
        let perpInside = CGFloat(isVerticalEdge ? prefs.paddingLeft + prefs.paddingRight : prefs.paddingLeft + prefs.paddingRight)
        let perpAlongAxis = CGFloat(isVerticalEdge ? prefs.paddingTop + prefs.paddingBottom : prefs.paddingLeft + prefs.paddingRight)
        let totalIcons = CGFloat(count) * iconSize + CGFloat(max(0, count - 1)) * spacing

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
        let magnified = prefs.magnifyOnHover ? CGFloat(prefs.magnifySize) : effectiveIcon

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
        let frame: NSRect
        switch edge {
        case .bottom:
            let desired = totalIcons + pl + pr
            let maxLen = area.width - screenBuffer
            let length = prefs.fillWidth ? maxLen : min(max(desired, 240), maxLen)
            let y = useFlush ? area.minY - bleed : area.minY + offset
            frame = NSRect(x: area.midX - length / 2, y: y, width: length, height: thicknessHorizontal + bleed)
        case .top:
            let desired = totalIcons + pl + pr
            let maxLen = area.width - screenBuffer
            let length = prefs.fillWidth ? maxLen : min(max(desired, 240), maxLen)
            let y = useFlush ? area.maxY - thicknessHorizontal : area.maxY - thicknessHorizontal - offset
            frame = NSRect(x: area.midX - length / 2, y: y, width: length, height: thicknessHorizontal + bleed)
        case .left:
            let desired = totalIcons + pt + pb
            let maxLen = area.height - screenBuffer
            let length = prefs.fillWidth ? maxLen : min(max(desired, 240), maxLen)
            let x = useFlush ? area.minX - bleed : area.minX + offset
            frame = NSRect(x: x, y: area.midY - length / 2, width: thicknessVertical + bleed, height: length)
        case .right:
            let desired = totalIcons + pt + pb
            let maxLen = area.height - screenBuffer
            let length = prefs.fillWidth ? maxLen : min(max(desired, 240), maxLen)
            let x = useFlush ? area.maxX - thicknessVertical : area.maxX - thicknessVertical - offset
            frame = NSRect(x: x, y: area.midY - length / 2, width: thicknessVertical + bleed, height: length)
        }
        win.setFrame(frame, display: true, animate: false)
    }

    // Live snap-to-nearest-edge while dragging in edit mode.
    func windowDidMove(_ notification: Notification) {
        guard Preferences.shared.isEditingLayout, let win = window, let screen = win.screen ?? NSScreen.main else { return }
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
            if newEdge != Preferences.shared.edge {
                Preferences.shared.edge = newEdge // triggers applyLayout via observer
            } else {
                self.applyLayout()
            }
        }
        snapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
}

// MARK: - DockView

struct DockView: View {
    @EnvironmentObject var library: AppLibrary
    @EnvironmentObject var prefs: Preferences
    @StateObject private var dragState = DragState()
    @State private var hoverPoint: CGPoint? = nil

    private var iconSize: CGFloat { CGFloat(prefs.iconSize) }
    private var spacing: CGFloat { CGFloat(prefs.spacing) }
    private var magnifyMax: CGFloat { CGFloat(prefs.magnifySize) }

    private var isVertical: Bool {
        prefs.edge == .left || prefs.edge == .right
    }

    // Stable UUID for the virtual Finder entry so SwiftUI doesn't churn the
    // view identity on every render (which was causing the hover-jump).
    private static let finderID = UUID(uuidString: "F1DE0000-0000-0000-0000-000000000001")!
    private static let finderEntry = AppEntry(id: finderID,
                                              path: "/System/Library/CoreServices/Finder.app",
                                              name: "Finder")

    /// All items rendered in the dock, optionally prepended by a virtual Finder item.
    private var renderedItems: [DockItem] {
        guard prefs.showFinder else { return library.items }
        return [.app(Self.finderEntry)] + library.items
    }

    /// Effective per-icon scale to fit content within the dock window length.
    private func effectiveScale(in available: CGFloat) -> CGFloat {
        let n = max(1, renderedItems.count)
        let interior = max(0, available - CGFloat(isVertical ? prefs.paddingTop + prefs.paddingBottom : prefs.paddingLeft + prefs.paddingRight))
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
            let interior = max(0, avail - CGFloat(isVertical ? prefs.paddingTop + prefs.paddingBottom : prefs.paddingLeft + prefs.paddingRight))
            let n = max(1, renderedItems.count)
            let autoSpacing: CGFloat = n > 1 ? max(0, (interior - CGFloat(n) * scaledIcon) / CGFloat(n - 1)) : 0
            let scaledSpacing = prefs.fillWidth ? autoSpacing : spacing * scale

            ZStack(alignment: dockAlignment) {
                Group {
                    if isVertical {
                        VStack(spacing: scaledSpacing) { itemViews(iconSize: scaledIcon, spacing: scaledSpacing) }
                            .padding(.top, CGFloat(prefs.paddingTop))
                            .padding(.bottom, CGFloat(prefs.paddingBottom))
                            .padding(.leading, CGFloat(prefs.paddingLeft))
                            .padding(.trailing, CGFloat(prefs.paddingRight))
                    } else {
                        HStack(spacing: scaledSpacing) { itemViews(iconSize: scaledIcon, spacing: scaledSpacing) }
                            .padding(.top, CGFloat(prefs.paddingTop))
                            .padding(.bottom, CGFloat(prefs.paddingBottom))
                            .padding(.leading, CGFloat(prefs.paddingLeft))
                            .padding(.trailing, CGFloat(prefs.paddingRight))
                    }
                }
                if prefs.isEditingLayout {
                    EditModePill()
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: oppositeAlignment)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: dockAlignment)
        }
        .ignoresSafeArea()
        .coordinateSpace(name: "dock")
        .onContinuousHover(coordinateSpace: .named("dock")) { phase in
            switch phase {
            case .active(let p): hoverPoint = p
            case .ended: hoverPoint = nil
            }
        }
        .environmentObject(dragState)
        .environment(\.dockHoverPoint, hoverPoint)
        .environment(\.dockIsVertical, isVertical)
        .environment(\.dockMagnifyEnabled, prefs.magnifyOnHover)
        .environment(\.dockMagnifyMax, magnifyMax)
    }

    @ViewBuilder private func itemViews(iconSize: CGFloat, spacing: CGFloat) -> some View {
        ForEach(Array(renderedItems.enumerated()), id: \.element.id) { idx, item in
            DockItemView(
                item: item,
                index: idx,
                iconSize: iconSize,
                spacing: spacing,
                dragState: dragState
            )
        }
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

// MARK: - Magnification environment

private struct DockHoverPointKey: EnvironmentKey { static let defaultValue: CGPoint? = nil }
private struct DockIsVerticalKey: EnvironmentKey { static let defaultValue: Bool = false }
private struct DockMagnifyEnabledKey: EnvironmentKey { static let defaultValue: Bool = true }
private struct DockMagnifyMaxKey: EnvironmentKey { static let defaultValue: CGFloat = 110 }

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
}

// MARK: - Drag State

final class DragState: ObservableObject {
    @Published var draggingID: UUID? = nil
    @Published var dragOffset: CGSize = .zero
    @Published var hoverTargetID: UUID? = nil
    @Published var hoverStarted: Date? = nil
    @Published var wiggle: Bool = false
    @Published var folderForming: UUID? = nil // target id when threshold reached
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
    @State private var folderFormProgress: CGFloat = 0
    @EnvironmentObject var prefs: Preferences
    @Environment(\.dockHoverPoint) private var hoverPoint
    @Environment(\.dockIsVertical) private var isVertical
    @Environment(\.dockMagnifyEnabled) private var magnifyEnabled
    @Environment(\.dockMagnifyMax) private var magnifyMax

    private var magnificationScale: CGFloat {
        guard magnifyEnabled, let hp = hoverPoint, frameInDock != .zero else { return 1 }
        let center = isVertical ? frameInDock.midY : frameInDock.midX
        let mouse = isVertical ? hp.y : hp.x
        let dist = abs(mouse - center)
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

                // Fixed-size layout cell, sized to the resting icon size, so the
                // dock width never changes as icons magnify.
                Color.clear
                    .frame(width: iconSize, height: iconSize)
                    .overlay(alignment: isVertical ? .leading : .bottom) {
                        // The actual image is sized at the current displayed size
                        // (iconSize * scale) and re-rasterized cleanly each frame,
                        // avoiding the blur you get from .scaleEffect upscaling.
                        let scale = isDragging ? max(1.1, magScale) : (isHoverTarget ? 0.92 : magScale)
                        let displaySize = iconSize * scale
                        iconContent
                            .frame(width: displaySize, height: displaySize)
                            .opacity(isDragging ? 0.85 : 1.0)
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
            // Running-app indicator dot (when enabled).
            if prefs.showRunningIndicators, isAppRunning {
                Circle()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: 4, height: 4)
            }
        }
        .nativeToolTip(prefs.labelMode == .tooltip ? label : "")
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
            switch item {
            case .app(let a): library.launch(a)
            case .folder: showFolderPopover.toggle()
            }
        }
        .popover(isPresented: $showFolderPopover, arrowEdge: .top) {
            if case .folder(let f) = item {
                FolderPopover(folder: f)
                    .environmentObject(library)
                    .environmentObject(prefs)
            }
        }
    }

    @ViewBuilder private var iconContent: some View {
        switch item {
        case .app(let a):
            Image(nsImage: a.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
        case .folder(let f):
            FolderIconView(folder: f, size: iconSize)
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

    private func finishDrag(at location: CGPoint) {
        let target = dragState.hoverTargetID
        let dragged = item.id

        dragState.cancelHoverTimer()

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

        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
            dragState.draggingID = nil
            dragState.dragOffset = .zero
            dragState.hoverTargetID = nil
            dragState.folderForming = nil
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
        let cols = Array(repeating: GridItem(.fixed(cellSize + 16), spacing: cellSpacing), count: resolvedColumns)

        VStack(alignment: .leading, spacing: 10) {
            header
            LazyVGrid(columns: cols, alignment: .leading, spacing: cellSpacing) {
                ForEach(folder.apps) { app in
                    folderAppCell(app)
                }
            }
        }
        .padding(16)
        .frame(width: CGFloat(resolvedColumns) * (cellSize + 16) + CGFloat(max(0, resolvedColumns - 1)) * cellSpacing + 32)
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
            Image(nsImage: app.icon).resizable().interpolation(.high)
                .frame(width: cellSize, height: cellSize)
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
