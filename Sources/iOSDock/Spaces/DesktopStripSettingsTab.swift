import SwiftUI
import ApplicationServices

// Compiled out of the App Store build; SettingsView gates both the compile
// (#if !APPSTORE) and the runtime visibility (DesktopStripFeature.isAvailable)
// so the tab never appears there.
#if !APPSTORE

/// "Desktops" settings tab — M3: master toggle, desktop-switching section
/// (Accessibility permission row + managed-hotkeys toggle) and the rename
/// list. The Mission-Control-interception toggle arrives with M5.
struct DesktopStripSettingsTab: View {
    @EnvironmentObject var prefs: Preferences
    /// Own observable snapshot — refreshes itself on space/screen changes.
    @StateObject private var model = SpacesModel()
    /// Silent AX check (BadgeMonitor pattern): re-evaluated on appear and on
    /// a slow timer so granting permission in System Settings updates the row.
    @State private var axTrusted = AXIsProcessTrusted()
    private let axRecheck = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Desktop Strip") {
                Toggle("Show custom desktop strip", isOn: Binding(
                    get: { prefs.desktopStripEnabled },
                    set: { prefs.desktopStripEnabled = $0 }
                ))
                Text("A Mission Control–style strip of your desktops with custom names. Open it from the menu-bar icon → Show Desktops, then click a desktop (or press Return) to switch to it. Real thumbnails and taking over the Mission Control keys (F3, Ctrl+Up) arrive in upcoming updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        }
        .onReceive(axRecheck) { _ in
            axTrusted = AXIsProcessTrusted()
        }
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
