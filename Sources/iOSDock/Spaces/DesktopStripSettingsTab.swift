import SwiftUI
import ApplicationServices

// Compiled out of the App Store build; SettingsView gates both the compile
// (#if !APPSTORE) and the runtime visibility (DesktopStripFeature.isAvailable)
// so the tab never appears there.
#if !APPSTORE

/// "Desktops" settings tab — M4: master toggle, desktop-switching section
/// (Accessibility permission row + managed-hotkeys toggle), a Screen
/// Recording row for real thumbnails, and the rename list. The
/// Mission-Control-interception toggle arrives with M5.
struct DesktopStripSettingsTab: View {
    @EnvironmentObject var prefs: Preferences
    /// Own observable snapshot — refreshes itself on space/screen changes.
    @StateObject private var model = SpacesModel()
    /// Silent AX check (BadgeMonitor pattern): re-evaluated on appear and on
    /// a slow timer so granting permission in System Settings updates the row.
    @State private var axTrusted = AXIsProcessTrusted()
    /// Screen Recording state for the thumbnails row (same recheck rhythm).
    @State private var screenRecordingGranted = SpaceThumbnailCache.permissionGranted
    /// Once a grant was attempted we offer a relaunch — macOS often only
    /// honors a fresh Screen Recording grant after the app restarts.
    @State private var screenRecordingRequested = false
    /// Drives the first-enable onboarding sheet.
    @State private var showOnboarding = false
    private let axRecheck = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Desktop Strip") {
                Toggle("Show custom desktop strip", isOn: Binding(
                    get: { prefs.desktopStripEnabled },
                    set: { newValue in
                        prefs.desktopStripEnabled = newValue
                        // First time the user ENABLES the feature → onboarding.
                        if newValue && !prefs.desktopStripOnboarded {
                            showOnboarding = true
                        }
                    }
                ))
                Text("A Mission Control–style strip of your desktops with custom names and live thumbnails. Open it from the menu-bar icon → Show Desktops, with ⌃↑ / F3, or a four-finger swipe up, then click a desktop (or press Return) to switch to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Open the desktop strip instead of Mission Control", isOn: Binding(
                    get: { prefs.desktopStripInterceptMissionControl },
                    set: { prefs.desktopStripInterceptMissionControl = $0 }
                ))
                .disabled(!prefs.desktopStripEnabled)
                Text("Opens Focus Dock's desktop strip instead of Mission Control on ⌃↑, F3, and four-finger swipe up. The system's “swipe up for Mission Control” gesture is temporarily turned off while this is on, and restored when you quit. Requires Accessibility access; without it, the system Mission Control keeps working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !screenRecordingGranted {
                Section("Desktop thumbnails") {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Screen Recording permission required")
                                .font(.callout).bold()
                            Text("Real desktop thumbnails are screenshots of your desktops, which needs Screen Recording access. Without it the strip shows colored placeholder tiles instead — everything else keeps working.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Request Screen Recording Access…") {
                                SpaceThumbnailCache.requestPermission()
                                screenRecordingRequested = true
                                screenRecordingGranted = SpaceThumbnailCache.permissionGranted
                            }
                            .buttonStyle(.link)
                            if screenRecordingRequested {
                                Text("After granting access in System Settings, macOS may require Focus Dock to relaunch before thumbnails appear.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Relaunch Focus Dock") {
                                    relaunchFocusDock()
                                }
                            }
                        }
                    }
                }
            }
            Section("Desktop switching") {
                if !axTrusted {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Accessibility permission required")
                                .font(.callout).bold()
                            Text("Switching desktops sends keyboard shortcuts on your behalf, which needs Accessibility access (the same permission used for badges and minimized windows).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Request Accessibility Access…") {
                                BadgeMonitor.requestAccessibilityPermission()
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                Toggle("Switch directly with managed ⌃1–9 shortcuts", isOn: Binding(
                    get: { prefs.desktopStripManageHotkeys },
                    set: { prefs.desktopStripManageHotkeys = $0 }
                ))
                Text("Temporarily enables the system's ⌃1–⌃9 “Switch to Desktop” shortcuts while Focus Dock runs, giving the native slide animation; your previous shortcut settings are restored on quit. When off, Focus Dock switches desktops instantly without changing any system settings (no animation).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Desktop names") {
                if model.desktopSpaces.isEmpty {
                    Text("No desktops detected.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.desktopSpaces, id: \.uuid) { space in
                        DesktopNameRow(
                            uuid: space.uuid,
                            number: model.desktopNumber(for: space.uuid) ?? 0
                        )
                    }
                }
                Text("You can also rename a desktop by double-clicking its name in the strip. Clear a name to fall back to “Desktop N”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refresh()
            axTrusted = AXIsProcessTrusted()
            screenRecordingGranted = SpaceThumbnailCache.permissionGranted
        }
        .onReceive(axRecheck) { _ in
            axTrusted = AXIsProcessTrusted()
            screenRecordingGranted = SpaceThumbnailCache.permissionGranted
        }
        .sheet(isPresented: $showOnboarding) {
            DesktopStripOnboardingSheet {
                prefs.desktopStripOnboarded = true
                showOnboarding = false
                axTrusted = AXIsProcessTrusted()
                screenRecordingGranted = SpaceThumbnailCache.permissionGranted
            }
        }
    }
}

// MARK: - Onboarding sheet

/// Lightweight 3-step first-enable sheet: Accessibility (switch desktops +
/// intercept Mission Control), optional Screen Recording (live thumbnails),
/// and a consent notice that Focus Dock temporarily adjusts the ⌃1–9 shortcuts
/// and the Mission Control gesture — all restored on quit. Shown once, the
/// first time the feature is enabled (`desktopStripOnboarded`).
private struct DesktopStripOnboardingSheet: View {
    let onDone: () -> Void
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var screenRecordingGranted = SpaceThumbnailCache.permissionGranted
    private let recheck = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.3.group.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up the desktop strip").font(.title2).bold()
                    Text("Three quick things and you're done.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            step(
                number: 1,
                done: axTrusted,
                title: "Allow Accessibility",
                why: "Lets Focus Dock switch desktops on your behalf and open its strip instead of Mission Control on ⌃↑ and F3."
            ) {
                if !axTrusted {
                    Button("Grant Accessibility Access…") {
                        BadgeMonitor.requestAccessibilityPermission()
                    }
                    .buttonStyle(.link)
                }
            }

            step(
                number: 2,
                done: screenRecordingGranted,
                title: "Allow Screen Recording (optional)",
                why: "Shows real, live thumbnails of each desktop. Skip it and the strip uses colored placeholder tiles instead — everything else still works."
            ) {
                if !screenRecordingGranted {
                    Button("Grant Screen Recording Access…") {
                        SpaceThumbnailCache.requestPermission()
                    }
                    .buttonStyle(.link)
                }
            }

            step(
                number: 3,
                done: true,
                title: "A heads-up on system settings",
                why: "While Focus Dock runs it temporarily turns on the ⌃1–⌃9 “Switch to Desktop” shortcuts and turns off the system four-finger “swipe up for Mission Control” gesture. Both are snapshotted and restored exactly when you quit."
            ) { EmptyView() }

            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onReceive(recheck) { _ in
            axTrusted = AXIsProcessTrusted()
            screenRecordingGranted = SpaceThumbnailCache.permissionGranted
        }
    }

    @ViewBuilder
    private func step<Action: View>(
        number: Int, done: Bool, title: String, why: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.accentColor.opacity(0.85))
                    .frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption.bold()).foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout).bold()
                Text(why).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action()
            }
            Spacer(minLength: 0)
        }
    }
}

/// Relaunches through the NORMAL terminate flow (NSApp.terminate →
/// applicationShouldTerminate → system-dock + symbolic-hotkey restore), NOT
/// exit(): a detached shell waits out the teardown, then opens a fresh
/// instance of this same bundle.
private func relaunchFocusDock() {
    let bundlePath = Bundle.main.bundlePath
    let relauncher = Process()
    relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
    relauncher.arguments = ["-c", "sleep 1.0; /usr/bin/open -n \"\(bundlePath)\""]
    try? relauncher.run()
    DispatchQueue.main.async {
        NSApp.terminate(nil)
    }
}

/// One row per current desktop: Mission-Control number + editable name backed
/// by SpaceNameStore. Commits on Return and on focus loss; empty = default.
private struct DesktopNameRow: View {
    let uuid: String
    let number: Int

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            TextField("Desktop \(number)", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { isFocused in
                    if !isFocused { commit() }
                }
        }
        .onAppear { draft = SpaceNameStore.shared.customName(for: uuid) ?? "" }
    }

    private func commit() {
        SpaceNameStore.shared.setName(draft, for: uuid)
        draft = SpaceNameStore.shared.customName(for: uuid) ?? ""
    }
}

#endif
