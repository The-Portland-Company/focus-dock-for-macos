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
    private let kEdgeOffset = "edgeOffset"
    private let kShowFinder = "showFinder"
    private let kAutoHide = "autoHideDock"
    private let kBounce = "bounceOnLaunch"
    private let kRunningDots = "showRunningIndicators"
    private let kShowRecents = "showRecentApps"
    private let kFillWidth = "fillWidth"
    private let kPaddingUniform = "paddingUniform"

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
        if defaults.object(forKey: kEdgeOffset) == nil { defaults.set(8.0, forKey: kEdgeOffset) }
        if defaults.object(forKey: kShowFinder) == nil { defaults.set(true, forKey: kShowFinder) }
        if defaults.object(forKey: kAutoHide) == nil { defaults.set(false, forKey: kAutoHide) }
        if defaults.object(forKey: kBounce) == nil { defaults.set(true, forKey: kBounce) }
        if defaults.object(forKey: kRunningDots) == nil { defaults.set(true, forKey: kRunningDots) }
        if defaults.object(forKey: kShowRecents) == nil { defaults.set(false, forKey: kShowRecents) }
        if defaults.object(forKey: kFillWidth) == nil { defaults.set(false, forKey: kFillWidth) }
        if defaults.object(forKey: kPaddingUniform) == nil { defaults.set(false, forKey: kPaddingUniform) }
        // Migrate older "margin" defaults to padding-appropriate values on first
        // launch with this build only.
        if !defaults.bool(forKey: "didMigratePadding") {
            defaults.set(14.0, forKey: kMarginTop)
            defaults.set(14.0, forKey: kMarginBottom)
            defaults.set(18.0, forKey: kMarginLeft)
            defaults.set(18.0, forKey: kMarginRight)
            defaults.set(true, forKey: "didMigratePadding")
        }
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
             flushBottom,
             edgeOffset, showFinder,
             autoHideDock, bounceOnLaunch, showRunningIndicators, showRecentApps,
             fillWidth, paddingUniform
    }

    static let defaultValues: [Key: Any] = [
        .showDockIcon: true, .showMenuBarIcon: true, .edge: "bottom",
        .iconSize: 64.0, .spacing: 14.0,
        .magnifyOnHover: true, .magnifySize: 110.0,
        .labelMode: "tooltip",
        .marginTop: 14.0, .marginBottom: 14.0, .marginLeft: 18.0, .marginRight: 18.0,
        .flushBottom: false,
        .edgeOffset: 8.0, .showFinder: true,
        .autoHideDock: false, .bounceOnLaunch: true, .showRunningIndicators: true, .showRecentApps: false,
        .fillWidth: false, .paddingUniform: false
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

    var edgeOffset: Double {
        get { defaults.double(forKey: kEdgeOffset) }
        set { defaults.set(newValue, forKey: kEdgeOffset); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var showFinder: Bool {
        get { defaults.bool(forKey: kShowFinder) }
        set { defaults.set(newValue, forKey: kShowFinder); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var autoHideDock: Bool {
        get { defaults.bool(forKey: kAutoHide) }
        set { defaults.set(newValue, forKey: kAutoHide); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var bounceOnLaunch: Bool {
        get { defaults.bool(forKey: kBounce) }
        set { defaults.set(newValue, forKey: kBounce); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var showRunningIndicators: Bool {
        get { defaults.bool(forKey: kRunningDots) }
        set { defaults.set(newValue, forKey: kRunningDots); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var showRecentApps: Bool {
        get { defaults.bool(forKey: kShowRecents) }
        set { defaults.set(newValue, forKey: kShowRecents); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var fillWidth: Bool {
        get { defaults.bool(forKey: kFillWidth) }
        set { defaults.set(newValue, forKey: kFillWidth); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var paddingUniform: Bool {
        get { defaults.bool(forKey: kPaddingUniform) }
        set { defaults.set(newValue, forKey: kPaddingUniform); _tick &+= 1; NotificationCenter.default.post(name: Self.changed, object: nil) }
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
