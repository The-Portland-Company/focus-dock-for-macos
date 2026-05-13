import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SettingsTab: String { case about, general, apps }

struct SettingsView: View {
    @EnvironmentObject var library: AppLibrary
    @EnvironmentObject var prefs: Preferences
    @State private var dockHidden: Bool = SystemDockManager.isHidden
    @State private var resetKey: Preferences.Key? = nil
    @State private var showResetAll: Bool = false

    @State private var selection: SettingsTab = {
        // First time the user sees Settings → land on About.
        // After that → General.
        UserDefaults.standard.bool(forKey: "hasSeenSettings") ? .general : .about
    }()

    var body: some View {
        VStack(spacing: 0) {
            systemSettingsLink
                .padding(.horizontal, 12)
                .padding(.top, 8)
            TabView(selection: $selection) {
                aboutTab
                    .tabItem { Label("About", systemImage: "info.circle") }
                    .tag(SettingsTab.about)
                generalTab
                    .tabItem { Label("General", systemImage: "gearshape") }
                    .tag(SettingsTab.general)
                appsTab
                    .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                    .tag(SettingsTab.apps)
            }
            .padding()
        }
        .frame(minWidth: 480, idealWidth: 520, maxWidth: .infinity,
               minHeight: 420, idealHeight: 900, maxHeight: .infinity)
        .onAppear {
            UserDefaults.standard.set(true, forKey: "hasSeenSettings")
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsRouter.openFolder)) { notif in
            selection = .apps
            if let id = notif.object as? UUID {
                pendingFolder = id
            }
        }
    }

    @State private var pendingFolder: UUID? = nil

    private var systemSettingsLink: some View {
        Button {
            // Opens System Settings → Desktop & Dock (macOS 13+).
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.dock") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "macwindow")
                Text("Open macOS System Settings → Desktop & Dock").font(.callout)
                Spacer()
                Image(systemName: "arrow.up.right.square")
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Open the native Desktop & Dock pane in System Settings")
    }

    // MARK: - About

    private var aboutTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    if let img = NSApp.applicationIconImage {
                        Image(nsImage: img).resizable().frame(width: 96, height: 96)
                    }
                    VStack(alignment: .leading) {
                        Text("Focus: Dock").font(.title2).bold()
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("What it does")
                    .font(.headline)
                Text("Replicates iOS-style folder creation for your macOS Dock. Drag any app onto another and hold for about a second — icons begin to wiggle (edit mode), a folder appears, and releasing drops the app inside.")

                Text("Why a replacement dock instead of modifying the real one?")
                    .font(.headline)
                    .padding(.top, 18)
                Text("Apple's Dock (the process Dock.app) is owned by the system and protected by System Integrity Protection and the App Store sandbox. Third-party apps cannot inject drag behavior, animations, or folder logic into it. The only way to deliver this feature is to ship a separate dock that runs alongside — or in place of — the system Dock. When you launch this app it offers to hide the system Dock automatically; quitting or uninstalling restores it.")
                    .foregroundStyle(.secondary)

                restoreBadge
                    .padding(.top, 6)

                githubBadge
                    .padding(.top, 4)

                DisclosureGroup("Installed files & permissions") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Installed files").font(.subheadline).bold()
                        ForEach(installedFiles, id: \.path) { entry in
                            filePathRow(entry)
                        }

                        Divider()

                        Text("Permissions this app uses").font(.subheadline).bold()
                        ForEach(permissionEntries, id: \.title) { entry in
                            permissionRow(entry)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(.top, 8)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var restoreBadge: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.white)
                .padding(8)
                .background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Your system Dock is safe.").font(.callout).bold()
                Text("Hiding the system Dock is reversible. Quitting Focus: Dock or deleting it from /Applications will automatically restore the native Dock — no Terminal commands or manual cleanup required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.green.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.green.opacity(0.35), lineWidth: 0.5)
                )
        )
    }

    private var githubBadge: some View {
        let repoURL = URL(string: "https://github.com/The-Portland-Company/focus-dock-for-macos")!
        let issuesURL = URL(string: "https://github.com/The-Portland-Company/focus-dock-for-macos/issues/new")!
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(.white)
                .padding(8)
                .background(Color.purple.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Open source — help shape Focus: Dock.").font(.callout).bold()
                Text("Found a bug? Want a feature? Submit an issue or open a pull request on GitHub — contributions are welcome.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Link(destination: repoURL) {
                        Label("View on GitHub", systemImage: "arrow.up.right.square")
                            .font(.caption.weight(.semibold))
                    }
                    Link(destination: issuesURL) {
                        Label("Submit an issue", systemImage: "exclamationmark.bubble")
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.purple.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.purple.opacity(0.35), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Installed files

    private struct InstalledFileEntry {
        let icon: String
        let label: String
        let path: String
    }

    private var installedFiles: [InstalledFileEntry] {
        let bundle = Bundle.main.bundlePath
        let appSupport = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FocusDock", isDirectory: true).path) ?? "~/Library/Application Support/FocusDock"
        let prefs = NSHomeDirectory() + "/Library/Preferences/" + (Bundle.main.bundleIdentifier ?? "com.spencerhill.MacOSDockFolders") + ".plist"
        return [
            .init(icon: "app.dashed", label: "App bundle", path: bundle),
            .init(icon: "folder.fill", label: "Dock library (your apps + folders, JSON)", path: appSupport + "/library.json"),
            .init(icon: "doc.text.fill", label: "User preferences (settings)", path: prefs)
        ]
    }

    private func filePathRow(_ entry: InstalledFileEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.label).font(.callout)
                Text(entry.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
        }
    }

    // MARK: - Permissions

    private struct PermissionEntry {
        let icon: String
        let title: String
        let detail: String
    }

    private var permissionEntries: [PermissionEntry] {
        [
            .init(icon: "dock.rectangle",
                  title: "Modify the system Dock's preferences",
                  detail: "Writes autohide, autohide-delay, and autohide-time-modifier in com.apple.dock to hide Apple's Dock, then runs `killall Dock` so the change takes effect. Original values are saved and restored on quit / uninstall."),
            .init(icon: "app.badge",
                  title: "Read installed application icons",
                  detail: "Uses NSWorkspace.shared.icon(forFile:) to load app icons from /Applications and elsewhere for display in the dock."),
            .init(icon: "arrow.up.right.square",
                  title: "Launch other applications",
                  detail: "Uses NSWorkspace.shared.open(_:) when you click an icon in the dock."),
            .init(icon: "folder",
                  title: "Read/write the dock library file",
                  detail: "Persists your dock items in ~/Library/Application Support/FocusDock/library.json."),
            .init(icon: "gearshape",
                  title: "Read/write its own preferences",
                  detail: "Stores your settings in this app's UserDefaults plist."),
            .init(icon: "rectangle.on.rectangle",
                  title: "Display a floating panel above all apps",
                  detail: "A standard non-activating panel pinned to the screen — no Accessibility or Screen Recording permission is requested.")
        ]
    }

    private func permissionRow(_ entry: PermissionEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.callout)
                Text(entry.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Presentation") {
                settingRow(.showMenuBarIcon) {
                    Toggle("Show menu-bar (Toolbar) icon", isOn: Binding(
                        get: { prefs.showMenuBarIcon },
                        set: { prefs.showMenuBarIcon = $0 }
                    ))
                }
            }
            Section("Appearance") {
                settingRow(.iconSize) {
                    HStack {
                        Text("Icon size")
                        Slider(value: Binding(
                            get: { prefs.iconSize },
                            set: { prefs.iconSize = $0 }
                        ), in: 32...128, step: 1)
                        EditableNumber(value: Binding(get: { prefs.iconSize }, set: { prefs.iconSize = $0 }), suffix: "pt")
                    }
                }
                settingRow(.fillWidth) {
                    Toggle("Fill width (auto-space icons across dock)", isOn: Binding(
                        get: { prefs.fillWidth },
                        set: { prefs.fillWidth = $0 }
                    ))
                }
                if !prefs.fillWidth {
                    settingRow(.spacing) {
                        HStack {
                            Text("Spacing")
                            Slider(value: Binding(
                                get: { prefs.spacing },
                                set: { prefs.spacing = $0 }
                            ), in: 0...40, step: 1)
                            EditableNumber(value: Binding(get: { prefs.spacing }, set: { prefs.spacing = $0 }), suffix: "pt")
                        }
                    }
                }
                settingRow(.labelMode) {
                    Picker("Labels", selection: Binding(
                        get: { prefs.labelMode },
                        set: { prefs.labelMode = $0 }
                    )) {
                        ForEach(Preferences.LabelMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                }
                settingRow(.magnifyOnHover) {
                    Toggle("Magnify on hover", isOn: Binding(
                        get: { prefs.magnifyOnHover },
                        set: { prefs.magnifyOnHover = $0 }
                    ))
                }
                if prefs.magnifyOnHover {
                    settingRow(.magnifySize) {
                        HStack {
                            Text("Magnified size")
                            Slider(value: Binding(
                                get: { prefs.magnifySize },
                                set: { prefs.magnifySize = $0 }
                            ), in: max(prefs.iconSize, 48)...192, step: 1)
                            EditableNumber(value: Binding(get: { prefs.magnifySize }, set: { prefs.magnifySize = $0 }), suffix: "pt")
                        }
                    }
                }
            }
            Section("Padding (inside dock)") {
                settingRow(.paddingUniform) {
                    Toggle("All (apply one value to top, bottom, left, right)", isOn: Binding(
                        get: { prefs.paddingUniform },
                        set: { newVal in
                            prefs.paddingUniform = newVal
                            if newVal {
                                let v = prefs.paddingTop
                                prefs.paddingBottom = v; prefs.paddingLeft = v; prefs.paddingRight = v
                            }
                        }
                    ))
                }
                if prefs.paddingUniform {
                    settingRow(.marginTop) {
                        marginSlider("All", value: Binding(
                            get: { prefs.paddingTop },
                            set: { v in
                                prefs.paddingTop = v; prefs.paddingBottom = v; prefs.paddingLeft = v; prefs.paddingRight = v
                            }
                        ))
                    }
                } else {
                    settingRow(.marginTop) { marginSlider("Top", value: Binding(get: { prefs.paddingTop }, set: { prefs.paddingTop = $0 })) }
                    settingRow(.marginBottom) { marginSlider("Bottom", value: Binding(get: { prefs.paddingBottom }, set: { prefs.paddingBottom = $0 })) }
                    settingRow(.marginLeft) { marginSlider("Left", value: Binding(get: { prefs.paddingLeft }, set: { prefs.paddingLeft = $0 })) }
                    settingRow(.marginRight) { marginSlider("Right", value: Binding(get: { prefs.paddingRight }, set: { prefs.paddingRight = $0 })) }
                }
            }
            Section("Dock Background") {
                settingRow(.tintBackground) {
                    Toggle("Tint the dock background (over the blur)", isOn: Binding(
                        get: { prefs.tintBackground },
                        set: { prefs.tintBackground = $0 }
                    ))
                }
                if prefs.tintBackground {
                    settingRow(.backgroundColor) {
                        HStack {
                            ColorPicker("Background color & opacity",
                                        selection: rgbaBinding(\.backgroundColor),
                                        supportsOpacity: true)
                            colorPreviewSwatch(prefs.backgroundColor)
                        }
                    }
                }
            }
            Section("Dock Border") {
                settingRow(.showBorder) {
                    Toggle("Show border", isOn: Binding(
                        get: { prefs.showBorder },
                        set: { prefs.showBorder = $0 }
                    ))
                }
                if prefs.showBorder {
                    settingRow(.borderColor) {
                        HStack {
                            ColorPicker("Border color & opacity",
                                        selection: rgbaBinding(\.borderColor),
                                        supportsOpacity: true)
                            colorPreviewSwatch(prefs.borderColor)
                        }
                    }
                    settingRow(.borderWidth) {
                        HStack {
                            Text("Border width")
                            Slider(value: Binding(
                                get: { prefs.borderWidth },
                                set: { prefs.borderWidth = $0 }
                            ), in: 0...6, step: 0.5)
                            EditableNumber(value: Binding(
                                get: { prefs.borderWidth },
                                set: { prefs.borderWidth = $0 }
                            ), suffix: "pt", precision: 1)
                        }
                    }
                }
            }
            Section("Shape") {
                settingRow(.flushBottom) {
                    Toggle("Flush with Edge", isOn: Binding(
                        get: { prefs.flushBottom },
                        set: { prefs.flushBottom = $0 }
                    ))
                }
                Text("When on, the dock sits against whichever screen edge it's anchored to, and the corners on that edge are squared off.")
                    .font(.caption).foregroundStyle(.secondary)
                settingRow(.cornerRadius) {
                    HStack {
                        Text("Corner radius")
                        Slider(value: Binding(
                            get: { prefs.cornerRadius },
                            set: { prefs.cornerRadius = $0 }
                        ), in: 0...40, step: 1)
                        EditableNumber(value: Binding(get: { prefs.cornerRadius }, set: { prefs.cornerRadius = $0 }), suffix: "pt")
                    }
                }
            }
            Section("Layout") {
                settingRow(.edge) {
                    Picker("Snap to edge", selection: Binding(
                        get: { prefs.edge },
                        set: { prefs.edge = $0 }
                    )) {
                        Text("Bottom").tag(Preferences.Edge.bottom)
                        Text("Left").tag(Preferences.Edge.left)
                        Text("Right").tag(Preferences.Edge.right)
                        Text("Top").tag(Preferences.Edge.top)
                    }
                }
                settingRow(.edgeOffset) {
                    HStack {
                        Text("Edge offset")
                        Slider(value: Binding(
                            get: { prefs.edgeOffset },
                            set: { prefs.edgeOffset = $0 }
                        ), in: 0...80, step: 1)
                        EditableNumber(value: Binding(get: { prefs.edgeOffset }, set: { prefs.edgeOffset = $0 }), suffix: "pt")
                    }
                }
                settingRow(.showFinder) {
                    Toggle("Show Finder as the first icon", isOn: Binding(
                        get: { prefs.showFinder },
                        set: { prefs.showFinder = $0 }
                    ))
                }
                settingRow(.showTrash) {
                    Toggle("Show Trash as the last icon", isOn: Binding(
                        get: { prefs.showTrash },
                        set: { prefs.showTrash = $0 }
                    ))
                }
                Toggle("Edit Layout (drag the dock to any edge to snap)", isOn: Binding(
                    get: { prefs.isEditingLayout },
                    set: { prefs.isEditingLayout = $0 }
                ))
                Text("Left, right, and top placement are available while Edit Layout is on. Bottom is the default to match the system Dock.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behavior (macOS Dock parity)") {
                settingRow(.autoHideDock) {
                    Toggle("Automatically hide and show the dock", isOn: Binding(
                        get: { prefs.autoHideDock },
                        set: { prefs.autoHideDock = $0 }
                    ))
                }
                settingRow(.bounceOnLaunch) {
                    Toggle("Animate opening applications (bounce)", isOn: Binding(
                        get: { prefs.bounceOnLaunch },
                        set: { prefs.bounceOnLaunch = $0 }
                    ))
                }
                settingRow(.showRunningIndicators) {
                    Toggle("Show indicators for open applications", isOn: Binding(
                        get: { prefs.showRunningIndicators },
                        set: { prefs.showRunningIndicators = $0 }
                    ))
                }
                settingRow(.showRecentApps) {
                    Toggle("Show recent apps in dock", isOn: Binding(
                        get: { prefs.showRecentApps },
                        set: { prefs.showRecentApps = $0 }
                    ))
                }
            }
            Section("System Dock") {
                Toggle("Hide system Dock while this app is running", isOn: Binding(
                    get: { dockHidden },
                    set: { newValue in
                        dockHidden = newValue
                        if newValue { SystemDockManager.hideSystemDock() }
                        else { SystemDockManager.restoreSystemDock() }
                    }
                ))
                Text("Automatically restored when you quit or uninstall the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        showResetAll = true
                    } label: {
                        Label("Reset All to Defaults", systemImage: "arrow.counterclockwise")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Reset this setting to its default?",
            isPresented: Binding(get: { resetKey != nil }, set: { if !$0 { resetKey = nil } }),
            presenting: resetKey
        ) { key in
            Button("Reset", role: .destructive) { prefs.reset(key) }
            Button("Cancel", role: .cancel) {}
        } message: { key in
            Text("This will restore '\(key.rawValue)' to its built-in default value.")
        }
        .confirmationDialog(
            "Reset every preference on this tab to defaults?",
            isPresented: $showResetAll
        ) {
            Button("Reset All", role: .destructive) { prefs.resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every value in General will return to the value it had on a fresh install. Your apps and folders are not affected.")
        }
    }

    /// Wraps a control with a tiny reset button.
    private func settingRow<Content: View>(_ key: Preferences.Key, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            content()
            Button {
                resetKey = key
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Reset to default")
        }
    }

    // MARK: - Apps (tree view + drag-and-drop)

    private var appsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Folder tree").font(.headline)
                Spacer()
                Button {
                    cloneFromSystemDock()
                } label: { Label("Clone System Dock", systemImage: "square.and.arrow.down") }
                Button {
                    addApp()
                } label: { Label("Add App…", systemImage: "plus") }
            }
            Text("Drag any app to drop it into a folder, or onto the bottom row to move it back to the top level.")
                .font(.caption).foregroundStyle(.secondary)
            FolderTreeView(pendingFolderID: $pendingFolder)
                .environmentObject(library)
        }
        .padding(.bottom, 8)
    }

    /// Two-way bridge between SwiftUI `Color` (with opacity) and our RGBA struct.
    private func rgbaBinding(_ keyPath: ReferenceWritableKeyPath<Preferences, Preferences.RGBA>) -> Binding<Color> {
        Binding(
            get: {
                let v = prefs[keyPath: keyPath]
                return Color(.sRGB, red: v.r, green: v.g, blue: v.b, opacity: v.a)
            },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? .black
                prefs[keyPath: keyPath] = Preferences.RGBA(
                    Double(ns.redComponent),
                    Double(ns.greenComponent),
                    Double(ns.blueComponent),
                    Double(ns.alphaComponent)
                )
            }
        )
    }

    private func marginSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading)
            Slider(value: value, in: 0...80, step: 1)
            EditableNumber(value: value, suffix: "pt")
        }
    }

    private func colorPreviewSwatch(_ rgba: Preferences.RGBA) -> some View {
        // Visualizes the chosen hue regardless of alpha, then overlays the
        // actual color (with alpha) so users see both.
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: 1))
            .frame(width: 22, height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5)
            )
            .help("Selected hue (ignoring opacity)")
    }
}

/// Click-to-edit numeric display. Reads from a Double binding, shows as text,
/// switches to a small `TextField` on click, commits on Return / focus loss.
struct EditableNumber: View {
    @Binding var value: Double
    var suffix: String = ""
    var precision: Int = 0
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft, onCommit: commit)
                    .focused($focused)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onAppear {
                        draft = format(value)
                        DispatchQueue.main.async { focused = true }
                    }
                    .onChange(of: focused) { newValue in if !newValue { commit() } }
            } else {
                Text(format(value) + (suffix.isEmpty ? "" : " \(suffix)"))
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        draft = format(value)
                        editing = true
                    }
                    .help("Click to edit")
            }
        }
    }

    private func format(_ v: Double) -> String {
        precision == 0 ? "\(Int(v))" : String(format: "%.\(precision)f", v)
    }

    private func commit() {
        if let v = Double(draft.replacingOccurrences(of: " \(suffix)", with: "").trimmingCharacters(in: .whitespaces)) {
            value = v
        }
        editing = false
    }
}

// MARK: - SettingsView helpers continued (moved below to keep struct compile)

extension SettingsView {
    fileprivate func cloneFromSystemDock() {
        let paths = SystemDockManager.readSystemDockApps()
        guard !paths.isEmpty else {
            let a = NSAlert()
            a.messageText = "Couldn't read the system Dock."
            a.informativeText = "No pinned apps were found in com.apple.dock preferences."
            a.runModal()
            return
        }
        library.items = paths.compactMap { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            return .app(AppEntry(path: path, name: name))
        }
    }

    fileprivate func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls {
                library.addApp(at: url.path)
            }
        }
    }
}

// MARK: - Folder tree view

private let appDragType = "com.spencerhill.MacOSDockFolders.app-id"

struct FolderTreeView: View {
    @EnvironmentObject var library: AppLibrary
    @Binding var pendingFolderID: UUID?
    @State private var expandedFolders: Set<UUID> = []
    @State private var dropTargetFolder: UUID? = nil
    @State private var topLevelDropHover: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(library.items) { item in
                    switch item {
                    case .app(let a):
                        appRow(a)
                    case .folder(let f):
                        folderRow(f)
                    }
                }
                // Drop target: move-to-top-level
                topLevelDropRow
            }
            .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .onChange(of: pendingFolderID) { id in
            if let id = id {
                expandedFolders.insert(id)
                // Clear after focusing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    pendingFolderID = nil
                }
            }
        }
    }

    // MARK: rows

    private func appRow(_ app: AppEntry) -> some View {
        HStack {
            Image(nsImage: app.icon).resizable().frame(width: 24, height: 24)
            Text(app.name)
            Spacer()
            Button(role: .destructive) {
                library.removeItem(id: app.id)
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: app.id.uuidString as NSString)
        }
    }

    private func folderRow(_ folder: FolderEntry) -> some View {
        let expanded = expandedFolders.contains(folder.id)
        let isDropTarget = dropTargetFolder == folder.id
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Button {
                    if expanded { expandedFolders.remove(folder.id) }
                    else { expandedFolders.insert(folder.id) }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .frame(width: 14)
                }
                .buttonStyle(.borderless)

                FolderIconView(folder: folder, size: 24)
                    .frame(width: 24, height: 24)

                renamableName(folder)
                Text("(\(folder.apps.count))").foregroundStyle(.secondary).font(.caption)
                Spacer()
                Button(role: .destructive) {
                    library.removeItem(id: folder.id)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isDropTarget ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
            )
            .onDrop(of: [.text], isTargeted: Binding(
                get: { dropTargetFolder == folder.id },
                set: { dropTargetFolder = $0 ? folder.id : nil }
            )) { providers in
                handleDrop(providers: providers, intoFolder: folder.id)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    // Per-folder settings: column count.
                    HStack(spacing: 8) {
                        Text("Columns").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { folder.columns ?? 0 },
                            set: { library.setFolderColumns(folder.id, columns: $0 == 0 ? nil : $0) }
                        )) {
                            Text("Auto").tag(0)
                            ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .frame(width: 110)
                        .labelsHidden()
                        Spacer()
                    }
                    .padding(.leading, 36).padding(.trailing, 6).padding(.vertical, 3)

                    if folder.apps.isEmpty {
                        Text("Empty folder").font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 36)
                    }
                    ForEach(folder.apps) { app in
                        HStack {
                            Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
                            Text(app.name).font(.callout)
                            Spacer()
                            Button(role: .destructive) {
                                library.removeItem(id: app.id) // top-level removeItem; if nested we need a tree removal
                                detachIfNeeded(app.id)
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 3)
                        .padding(.leading, 36)
                        .padding(.trailing, 6)
                        .contentShape(Rectangle())
                        .onDrag { NSItemProvider(object: app.id.uuidString as NSString) }
                    }
                }
            }
        }
    }

    private func renamableName(_ folder: FolderEntry) -> some View {
        TextField("Folder name", text: Binding(
            get: { folder.name },
            set: { library.renameFolder(folder.id, to: $0) }
        ))
        .textFieldStyle(.plain)
        .font(.body.weight(.medium))
    }

    private var topLevelDropRow: some View {
        HStack {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
            Text("Drop here to move to top level")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(topLevelDropHover ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                        .foregroundStyle(Color.primary.opacity(0.25))
                )
        )
        .padding(.top, 6)
        .onDrop(of: [.text], isTargeted: $topLevelDropHover) { providers in
            handleDrop(providers: providers, intoFolder: nil)
        }
    }

    // MARK: drag/drop handlers

    private func handleDrop(providers: [NSItemProvider], intoFolder folderID: UUID?) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let s = reading as? String, let id = UUID(uuidString: s) else { return }
            DispatchQueue.main.async {
                if let folderID {
                    library.moveApp(id, intoFolder: folderID)
                } else {
                    library.moveAppToTopLevel(id)
                }
            }
        }
        return true
    }

    /// Removing an app nested inside a folder: AppLibrary.removeItem only
    /// removes top-level entries, so additionally clean up inside folders.
    private func detachIfNeeded(_ appID: UUID) {
        for i in 0..<library.items.count {
            if case .folder(var f) = library.items[i],
               let ai = f.apps.firstIndex(where: { $0.id == appID }) {
                f.apps.remove(at: ai)
                if f.apps.isEmpty {
                    library.items.remove(at: i)
                } else {
                    library.items[i] = .folder(f)
                }
                return
            }
        }
    }
}
