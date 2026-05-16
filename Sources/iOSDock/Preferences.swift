import Foundation
import AppKit

final class Preferences: ObservableObject {
    static let shared = Preferences()
    static let changed = Notification.Name("FocusDock.PreferencesChanged")

    /// When non-nil, this instance is pinned to one DockInstance (used by each
    /// `DockWindowController` to read/write its own dock's settings). When nil
    /// (the singleton case), reads/writes track `ProfileManager.editingDockID`
    /// so the Settings UI always edits the currently-selected dock.
    let dockID: UUID?

    private let defaults = UserDefaults.standard
    private let kDockIcon = "showDockIcon"
    private let kMenuBar = "showMenuBarIcon"
    private let kEdge = "dockEdge"
    private let kIsPlaced = "isPlaced"
    private let kEditing = "isEditingLayout"
    private let kEditingDocks = "isEditingDocks"
    private let kIconSize = "iconSize"
    private let kSpacing = "spacing"
    private let kMagnify = "magnifyOnHover"
    private let kMagnifySize = "magnifySize"
    private let kLabelMode = "labelMode"
    private let kMarginTop = "marginTop"
    private let kMarginBottom = "marginBottom"
    private let kMarginLeft = "marginLeft"
    private let kMarginRight = "marginRight"
    private let kFlushBottom = "flushBottom"
    private let kCornerRadius = "cornerRadius"
    private let kTintBackground = "tintBackground"
    private let kBackgroundColor = "backgroundColor"   // [r,g,b,a]
    private let kShowBorder = "showBorder"
    private let kBorderColor = "borderColor"           // [r,g,b,a]
    private let kBorderWidth = "borderWidth"
    private let kEdgeOffset = "edgeOffset"
    private let kShowFinder = "showFinder"
    private let kShowTrash = "showTrash"
    private let kAutoHide = "autoHideDock"
    private let kBounce = "bounceOnLaunch"
    private let kRunningDots = "showRunningIndicators"
    private let kShowRecents = "showRecentApps"
    private let kFillWidth = "fillWidth"
    private let kPaddingUniform = "paddingUniform"
    private let kDockScale = "dockScale"

    /// Resolve a UserDefaults key for the active profile (or leave global keys
    /// untouched). Per-profile keys are listed in `ProfileKeys.perProfile`.
    private func pk(_ key: String) -> String {
        guard ProfileKeys.isPerProfile(key) else { return key }
        let id = dockID ?? ProfileManager.shared.editingDockID
        return ProfileManager.shared.nsKey(key, for: id)
    }

    convenience init(dockID: UUID) { self.init(boundDockID: dockID) }

    private convenience init() { self.init(boundDockID: nil) }

    private init(boundDockID: UUID?) {
        // Make sure ProfileManager has bootstrapped before we seed defaults.
        _ = ProfileManager.shared
        self.dockID = boundDockID

        if defaults.object(forKey: kDockIcon) == nil { defaults.set(true, forKey: kDockIcon) }
        if defaults.object(forKey: kMenuBar) == nil { defaults.set(true, forKey: kMenuBar) }
        if defaults.object(forKey: pk(kEdge)) == nil { defaults.set("bottom", forKey: pk(kEdge)) }
        if defaults.object(forKey: pk(kIconSize)) == nil { defaults.set(64.0, forKey: pk(kIconSize)) }
        if defaults.object(forKey: pk(kSpacing)) == nil { defaults.set(14.0, forKey: pk(kSpacing)) }
        if defaults.object(forKey: pk(kMagnify)) == nil { defaults.set(true, forKey: pk(kMagnify)) }
        if defaults.object(forKey: pk(kMagnifySize)) == nil { defaults.set(110.0, forKey: pk(kMagnifySize)) }
        if defaults.object(forKey: pk(kLabelMode)) == nil { defaults.set("tooltip", forKey: pk(kLabelMode)) }
        if defaults.object(forKey: pk(kMarginTop)) == nil { defaults.set(0.0, forKey: pk(kMarginTop)) }
        if defaults.object(forKey: pk(kMarginBottom)) == nil { defaults.set(10.0, forKey: pk(kMarginBottom)) }
        if defaults.object(forKey: pk(kMarginLeft)) == nil { defaults.set(15.0, forKey: pk(kMarginLeft)) }
        if defaults.object(forKey: pk(kMarginRight)) == nil { defaults.set(15.0, forKey: pk(kMarginRight)) }
        if defaults.object(forKey: pk(kFlushBottom)) == nil { defaults.set(true, forKey: pk(kFlushBottom)) }
        if defaults.object(forKey: pk(kCornerRadius)) == nil { defaults.set(24.0, forKey: pk(kCornerRadius)) }
        if defaults.object(forKey: pk(kTintBackground)) == nil { defaults.set(false, forKey: pk(kTintBackground)) }
        if defaults.object(forKey: pk(kBackgroundColor)) == nil { defaults.set([0.0, 0.0, 0.0, 0.0], forKey: pk(kBackgroundColor)) }
        if defaults.object(forKey: pk(kShowBorder)) == nil { defaults.set(true, forKey: pk(kShowBorder)) }
        if defaults.object(forKey: pk(kBorderColor)) == nil { defaults.set([1.0, 1.0, 1.0, 0.12], forKey: pk(kBorderColor)) }
        if defaults.object(forKey: pk(kBorderWidth)) == nil { defaults.set(0.5, forKey: pk(kBorderWidth)) }
        if defaults.object(forKey: pk(kEdgeOffset)) == nil { defaults.set(8.0, forKey: pk(kEdgeOffset)) }
        if defaults.object(forKey: pk(kShowFinder)) == nil { defaults.set(true, forKey: pk(kShowFinder)) }
        if defaults.object(forKey: pk(kShowTrash)) == nil { defaults.set(true, forKey: pk(kShowTrash)) }
        if defaults.object(forKey: pk(kAutoHide)) == nil { defaults.set(true, forKey: pk(kAutoHide)) }
        if defaults.object(forKey: pk(kBounce)) == nil { defaults.set(true, forKey: pk(kBounce)) }
        if defaults.object(forKey: pk(kRunningDots)) == nil { defaults.set(true, forKey: pk(kRunningDots)) }
        if defaults.object(forKey: pk(kShowRecents)) == nil { defaults.set(false, forKey: pk(kShowRecents)) }
        if defaults.object(forKey: pk(kFillWidth)) == nil { defaults.set(true, forKey: pk(kFillWidth)) }
        if defaults.object(forKey: pk(kPaddingUniform)) == nil { defaults.set(false, forKey: pk(kPaddingUniform)) }
        if defaults.object(forKey: pk(kDockScale)) == nil { defaults.set(1.0, forKey: pk(kDockScale)) }
        // Reset transient edit-layout flag every launch (always global).
        defaults.set(false, forKey: kEditing)

        // Singleton case: when the editing target changes, push @Published so
        // SwiftUI observers bound to Preferences re-read all values.
        if boundDockID == nil {
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleEditingDockChanged),
                name: ProfileManager.editingDockChanged, object: nil)
        }
    }

    @objc private func handleEditingDockChanged() {
        _tick &+= 1
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    @Published var _tick: Int = 0

    var showDockIcon: Bool {
        get { defaults.bool(forKey: kDockIcon) }
        set {
            defaults.set(newValue, forKey: kDockIcon)
            _tick &+= 1
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }
    var showMenuBarIcon: Bool {
        get { defaults.bool(forKey: kMenuBar) }
        set {
            defaults.set(newValue, forKey: kMenuBar)
            _tick &+= 1
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    // MARK: - Defaults & reset

    enum Key: String, CaseIterable {
        case showDockIcon, showMenuBarIcon, edge, iconSize, spacing,
             magnifyOnHover, magnifySize, labelMode,
             marginTop, marginBottom, marginLeft, marginRight,
             flushBottom, cornerRadius,
             tintBackground, backgroundColor, showBorder, borderColor, borderWidth,
             edgeOffset, showFinder, showTrash,
             autoHideDock, bounceOnLaunch, showRunningIndicators, showRecentApps,
             fillWidth, paddingUniform, dockScale
    }

    /// Plain-Any defaults for primitives; the RGBA ones are handled specially in `reset(_:)`.
    static let defaultValues: [Key: Any] = [
        .showDockIcon: true, .showMenuBarIcon: true, .edge: "bottom",
        .iconSize: 64.0, .spacing: 14.0,
        .magnifyOnHover: true, .magnifySize: 110.0,
        .labelMode: "tooltip",
        .marginTop: 0.0, .marginBottom: 10.0, .marginLeft: 15.0, .marginRight: 15.0,
        .flushBottom: true, .cornerRadius: 24.0,
        .tintBackground: false, .showBorder: true, .borderWidth: 0.5,
        .edgeOffset: 8.0, .showFinder: true, .showTrash: true,
        .autoHideDock: true, .bounceOnLaunch: true, .showRunningIndicators: true, .showRecentApps: false,
        .fillWidth: true, .paddingUniform: false,
        .dockScale: 1.0
    ]

    func reset(_ key: Key) {
        switch key {
        case .backgroundColor: backgroundColor = RGBA(0, 0, 0, 0); return
        case .borderColor: borderColor = RGBA(1, 1, 1, 0.12); return
        default: break
        }
        guard let value = Self.defaultValues[key] else { return }
        defaults.set(value, forKey: pk(key.rawValue))
        _tick &+= 1
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func resetAll() {
        for key in Key.allCases {
            if let value = Self.defaultValues[key] {
                defaults.set(value, forKey: pk(key.rawValue))
            }
        }
        backgroundColor = RGBA(0, 0, 0, 0)
        borderColor = RGBA(1, 1, 1, 0.12)
        _tick &+= 1
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    var edgeOffset: Double {
        get { defaults.double(forKey: pk(kEdgeOffset)) }
        set { defaults.set(newValue, forKey: pk(kEdgeOffset)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var showFinder: Bool {
        get { defaults.bool(forKey: pk(kShowFinder)) }
        set { defaults.set(newValue, forKey: pk(kShowFinder)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var showTrash: Bool {
        get { defaults.bool(forKey: pk(kShowTrash)) }
        set { defaults.set(newValue, forKey: pk(kShowTrash)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var autoHideDock: Bool {
        get { defaults.bool(forKey: pk(kAutoHide)) }
        set { defaults.set(newValue, forKey: pk(kAutoHide)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var bounceOnLaunch: Bool {
        get { defaults.bool(forKey: pk(kBounce)) }
        set { defaults.set(newValue, forKey: pk(kBounce)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var showRunningIndicators: Bool {
        get { defaults.bool(forKey: pk(kRunningDots)) }
        set { defaults.set(newValue, forKey: pk(kRunningDots)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var showRecentApps: Bool {
        get { defaults.bool(forKey: pk(kShowRecents)) }
        set { defaults.set(newValue, forKey: pk(kShowRecents)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var fillWidth: Bool {
        get { defaults.bool(forKey: pk(kFillWidth)) }
        set { defaults.set(newValue, forKey: pk(kFillWidth)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var paddingUniform: Bool {
        get { defaults.bool(forKey: pk(kPaddingUniform)) }
        set { defaults.set(newValue, forKey: pk(kPaddingUniform)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    // Padding (semantic renames over marginTop/etc — internal dock padding around icons)
    var paddingTop: Double { get { marginTop } set { marginTop = newValue } }
    var paddingBottom: Double { get { marginBottom } set { marginBottom = newValue } }
    var paddingLeft: Double { get { marginLeft } set { marginLeft = newValue } }
    var paddingRight: Double { get { marginRight } set { marginRight = newValue } }

    enum Edge: String { case bottom, left, right, top }
    enum LabelMode: String, CaseIterable, Identifiable {
        case tooltip, above, below
        var id: String { rawValue }
        var label: String {
            switch self {
            case .tooltip: return "Tool tip"
            case .above: return "Above icon"
            case .below: return "Below icon"
            }
        }
    }

    // MARK: - Background / Border (with RGBA persistence)

    /// Stored as a 4-tuple [r,g,b,a] in UserDefaults. We use a tiny struct that
    /// SwiftUI views can convert to Color on demand.
    struct RGBA: Equatable {
        var r: Double, g: Double, b: Double, a: Double
        var alphaComponent: Double { a }
        init(_ r: Double, _ g: Double, _ b: Double, _ a: Double) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }
        init(_ color: NSColor) {
            let c = color.usingColorSpace(.sRGB) ?? color
            self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
        }
        var nsColor: NSColor {
            NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1.0)
        }
    }

    private func readRGBA(_ key: String, fallback: RGBA) -> RGBA {
        guard let arr = defaults.array(forKey: pk(key)) as? [Double], arr.count == 4 else { return fallback }
        return RGBA(arr[0], arr[1], arr[2], arr[3])
    }
    private func writeRGBA(_ key: String, _ v: RGBA) {
        defaults.set([v.r, v.g, v.b, v.a], forKey: pk(key))
        _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    var tintBackground: Bool {
        get { defaults.bool(forKey: pk(kTintBackground)) }
        set { defaults.set(newValue, forKey: pk(kTintBackground)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var backgroundColor: RGBA {
        get { readRGBA(kBackgroundColor, fallback: RGBA(0, 0, 0, 0)) }
        set { writeRGBA(kBackgroundColor, newValue) }
    }
    var showBorder: Bool {
        get { defaults.bool(forKey: pk(kShowBorder)) }
        set { defaults.set(newValue, forKey: pk(kShowBorder)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var borderColor: RGBA {
        get { readRGBA(kBorderColor, fallback: RGBA(1, 1, 1, 0.12)) }
        set { writeRGBA(kBorderColor, newValue) }
    }
    var borderWidth: Double {
        get { defaults.double(forKey: pk(kBorderWidth)) }
        set { defaults.set(newValue, forKey: pk(kBorderWidth)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    /// "Native macOS default" — clear tint, white-12% border at 0.5pt.
    func resetBackgroundToNative() {
        tintBackground = false
        backgroundColor = RGBA(0, 0, 0, 0)
    }
    func resetBorderToNative() {
        showBorder = true
        borderColor = RGBA(1, 1, 1, 0.12)
        borderWidth = 0.5
    }

    var marginTop: Double {
        get { defaults.double(forKey: pk(kMarginTop)) }
        set { defaults.set(newValue, forKey: pk(kMarginTop)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var marginBottom: Double {
        get { defaults.double(forKey: pk(kMarginBottom)) }
        set { defaults.set(newValue, forKey: pk(kMarginBottom)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var marginLeft: Double {
        get { defaults.double(forKey: pk(kMarginLeft)) }
        set { defaults.set(newValue, forKey: pk(kMarginLeft)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var marginRight: Double {
        get { defaults.double(forKey: pk(kMarginRight)) }
        set { defaults.set(newValue, forKey: pk(kMarginRight)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var flushBottom: Bool {
        get { defaults.bool(forKey: pk(kFlushBottom)) }
        set { defaults.set(newValue, forKey: pk(kFlushBottom)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var cornerRadius: Double {
        get { defaults.double(forKey: pk(kCornerRadius)) }
        set { defaults.set(newValue, forKey: pk(kCornerRadius)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    var labelMode: LabelMode {
        get { LabelMode(rawValue: defaults.string(forKey: pk(kLabelMode)) ?? "tooltip") ?? .tooltip }
        set { defaults.set(newValue.rawValue, forKey: pk(kLabelMode)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    var edge: Edge {
        get { Edge(rawValue: defaults.string(forKey: pk(kEdge)) ?? "bottom") ?? .bottom }
        set {
            defaults.set(newValue.rawValue, forKey: pk(kEdge))
            _tick &+= 1
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    /// Whether this dock has been dragged to a screen edge at least once.
    /// New docks start as `false` so they appear floating in the center with
    /// a prominent "drag to edge to activate" prompt.
    var isPlaced: Bool {
        get {
            if defaults.object(forKey: pk(kIsPlaced)) == nil { return true } // legacy docks
            return defaults.bool(forKey: pk(kIsPlaced))
        }
        set {
            defaults.set(newValue, forKey: pk(kIsPlaced))
            _tick &+= 1
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    var iconSize: Double {
        get { defaults.double(forKey: pk(kIconSize)) }
        set { defaults.set(newValue, forKey: pk(kIconSize)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var spacing: Double {
        get { defaults.double(forKey: pk(kSpacing)) }
        set { defaults.set(newValue, forKey: pk(kSpacing)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var magnifyOnHover: Bool {
        get { defaults.bool(forKey: pk(kMagnify)) }
        set { defaults.set(newValue, forKey: pk(kMagnify)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var magnifySize: Double {
        get { defaults.double(forKey: pk(kMagnifySize)) }
        set { defaults.set(newValue, forKey: pk(kMagnifySize)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    /// Overall dock scale multiplier applied on top of icon size, spacing,
    /// magnified size, and internal padding. 1.0 = no change.
    var dockScale: Double {
        get {
            let v = defaults.double(forKey: pk(kDockScale))
            return v > 0 ? v : 1.0
        }
        set { defaults.set(newValue, forKey: pk(kDockScale)); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    var effectiveIconSize: Double { iconSize * dockScale }
    var effectiveSpacing: Double { spacing * dockScale }
    var effectiveMagnifySize: Double { magnifySize * dockScale }
    var effectivePaddingTop: Double { paddingTop * dockScale }
    var effectivePaddingBottom: Double { paddingBottom * dockScale }
    var effectivePaddingLeft: Double { paddingLeft * dockScale }
    var effectivePaddingRight: Double { paddingRight * dockScale }

    var isEditingLayout: Bool {
        get { defaults.bool(forKey: kEditing) }
        set {
            defaults.set(newValue, forKey: kEditing)
            _tick &+= 1
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    /// Global "Edit Docks" mode — when enabled, each dock shows a prominent
    /// delete (X / trash) button in the top center so the user can remove docks
    /// directly from the visual representation.
    var isEditingDocks: Bool {
        get { defaults.bool(forKey: kEditingDocks) }
        set {
            defaults.set(newValue, forKey: kEditingDocks)
            _tick &+= 1
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }
}
