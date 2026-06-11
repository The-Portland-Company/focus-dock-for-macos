import SwiftUI

// Compiled out of the App Store build; SettingsView gates both the compile
// (#if !APPSTORE) and the runtime visibility (DesktopStripFeature.isAvailable)
// so the tab never appears there.
#if !APPSTORE

/// "Desktops" settings tab — M2 skeleton: master toggle + rename list.
/// Permission rows, the Mission-Control-interception toggle and the
/// hotkey-management toggle arrive with M3/M5.
struct DesktopStripSettingsTab: View {
    @EnvironmentObject var prefs: Preferences
    /// Own observable snapshot — refreshes itself on space/screen changes.
    @StateObject private var model = SpacesModel()

    var body: some View {
        Form {
            Section("Desktop Strip") {
                Toggle("Show custom desktop strip", isOn: Binding(
                    get: { prefs.desktopStripEnabled },
                    set: { prefs.desktopStripEnabled = $0 }
                ))
                Text("A Mission Control–style strip of your desktops with custom names. Open it from the menu-bar icon → Show Desktops. Clicking to switch desktops, real thumbnails, and taking over the Mission Control keys (F3, Ctrl+Up) arrive in upcoming updates.")
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
        .onAppear { model.refresh() }
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
