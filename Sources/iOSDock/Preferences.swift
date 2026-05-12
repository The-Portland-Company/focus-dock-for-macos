import Foundation
import AppKit

final class Preferences: ObservableObject {
    static let shared = Preferences()
    static let changed = Notification.Name("FocusDock.PreferencesChanged")

    private let defaults = UserDefaults.standard
    private let kDockIcon = "showDockIcon"
    private let kMenuBar = "showMenuBarIcon"
    private let kEdge = "dockEdge"
    private let kEditing = "isEditingLayout"
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

    init() {
        if defaults.object(forKey: kDockIcon) == nil { defaults.set(true, forKey: kDockIcon) }
        if defaults.object(forKey: kMenuBar) == nil { defaults.set(true, forKey: kMenuBar) }
        if defaults.object(forKey: kEdge) == nil { defaults.set("bottom", forKey: kEdge) }
        if defaults.object(forKey: kIconSize) == nil { defaults.set(64.0, forKey: kIconSize) }
        if defaults.object(forKey: kSpacing) == nil { defaults.set(14.0, forKey: kSpacing) }
        if defaults.object(forKey: kMagnify) == nil { defaults.set(true, forKey: kMagnify) }
        if defaults.object(forKey: kMagnifySize) == nil { defaults.set(110.0, forKey: kMagnifySize) }
        if defaults.object(forKey: kLabelMode) == nil { defaults.set("tooltip", forKey: kLabelMode) }
        if defaults.object(forKey: kMarginTop) == nil { defaults.set(8.0, forKey: kMarginTop) }
        if defaults.object(forKey: kMarginBottom) == nil { defaults.set(8.0, forKey: kMarginBottom) }
        if defaults.object(forKey: kMarginLeft) == nil { defaults.set(20.0, forKey: kMarginLeft) }
        if defaults.object(forKey: kMarginRight) == nil { defaults.set(20.0, forKey: kMarginRight) }
        if defaults.object(forKey: kFlushBottom) == nil { defaults.set(false, forKey: kFlushBottom) }
        if defaults.object(forKey: kCornerRadius) == nil { defaults.set(24.0, forKey: kCornerRadius) }
        if defaults.object(forKey: kTintBackground) == nil { defaults.set(false, forKey: kTintBackground) }
        if defaults.object(forKey: kBackgroundColor) == nil { defaults.set([0.0, 0.0, 0.0, 0.0], forKey: kBackgroundColor) }
        if defaults.object(forKey: kShowBorder) == nil { defaults.set(true, forKey: kShowBorder) }
        if defaults.object(forKey: kBorderColor) == nil { defaults.set([1.0, 1.0, 1.0, 0.12], forKey: kBorderColor) }
        if defaults.object(forKey: kBorderWidth) == nil { defaults.set(0.5, forKey: kBorderWidth) }
        defaults.set(false, forKey: kEditing)
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
             flushBottom, cornerRadius
    }

    static let defaultValues: [Key: Any] = [
        .showDockIcon: true, .showMenuBarIcon: true, .edge: "bottom",
        .iconSize: 64.0, .spacing: 14.0,
        .magnifyOnHover: true, .magnifySize: 110.0,
        .labelMode: "tooltip",
        .marginTop: 8.0, .marginBottom: 8.0, .marginLeft: 20.0, .marginRight: 20.0,
        .flushBottom: false, .cornerRadius: 24.0
    ]

    func reset(_ key: Key) {
        guard let value = Self.defaultValues[key] else { return }
        defaults.set(value, forKey: key.rawValue)
        _tick &+= 1
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func resetAll() {
        for key in Key.allCases {
            if let value = Self.defaultValues[key] {
                defaults.set(value, forKey: key.rawValue)
            }
        }
        _tick &+= 1
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

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
        guard let arr = defaults.array(forKey: key) as? [Double], arr.count == 4 else { return fallback }
        return RGBA(arr[0], arr[1], arr[2], arr[3])
    }
    private func writeRGBA(_ key: String, _ v: RGBA) {
        defaults.set([v.r, v.g, v.b, v.a], forKey: key)
        _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    var tintBackground: Bool {
        get { defaults.bool(forKey: kTintBackground) }
        set { defaults.set(newValue, forKey: kTintBackground); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var backgroundColor: RGBA {
        get { readRGBA(kBackgroundColor, fallback: RGBA(0, 0, 0, 0)) }
        set { writeRGBA(kBackgroundColor, newValue) }
    }
    var showBorder: Bool {
        get { defaults.bool(forKey: kShowBorder) }
        set { defaults.set(newValue, forKey: kShowBorder); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var borderColor: RGBA {
        get { readRGBA(kBorderColor, fallback: RGBA(1, 1, 1, 0.12)) }
        set { writeRGBA(kBorderColor, newValue) }
    }
    var borderWidth: Double {
        get { defaults.double(forKey: kBorderWidth) }
        set { defaults.set(newValue, forKey: kBorderWidth); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
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
        get { defaults.double(forKey: kMarginTop) }
        set { defaults.set(newValue, forKey: kMarginTop); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var marginBottom: Double {
        get { defaults.double(forKey: kMarginBottom) }
        set { defaults.set(newValue, forKey: kMarginBottom); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var marginLeft: Double {
        get { defaults.double(forKey: kMarginLeft) }
        set { defaults.set(newValue, forKey: kMarginLeft); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var marginRight: Double {
        get { defaults.double(forKey: kMarginRight) }
        set { defaults.set(newValue, forKey: kMarginRight); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var flushBottom: Bool {
        get { defaults.bool(forKey: kFlushBottom) }
        set { defaults.set(newValue, forKey: kFlushBottom); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var cornerRadius: Double {
        get { defaults.double(forKey: kCornerRadius) }
        set { defaults.set(newValue, forKey: kCornerRadius); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    var labelMode: LabelMode {
        get { LabelMode(rawValue: defaults.string(forKey: kLabelMode) ?? "tooltip") ?? .tooltip }
        set { defaults.set(newValue.rawValue, forKey: kLabelMode); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    var edge: Edge {
        get { Edge(rawValue: defaults.string(forKey: kEdge) ?? "bottom") ?? .bottom }
        set {
            defaults.set(newValue.rawValue, forKey: kEdge)
            _tick &+= 1
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    var iconSize: Double {
        get { defaults.double(forKey: kIconSize) }
        set { defaults.set(newValue, forKey: kIconSize); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var spacing: Double {
        get { defaults.double(forKey: kSpacing) }
        set { defaults.set(newValue, forKey: kSpacing); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var magnifyOnHover: Bool {
        get { defaults.bool(forKey: kMagnify) }
        set { defaults.set(newValue, forKey: kMagnify); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var magnifySize: Double {
        get { defaults.double(forKey: kMagnifySize) }
        set { defaults.set(newValue, forKey: kMagnifySize); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    var isEditingLayout: Bool {
        get { defaults.bool(forKey: kEditing) }
        set {
            defaults.set(newValue, forKey: kEditing)
            _tick &+= 1
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }
}
