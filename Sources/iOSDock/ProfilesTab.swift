import SwiftUI
import AppKit

struct ProfilesTab: View {
    @ObservedObject private var mgr = ProfileManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            profilesList
            profileButtonRow
            Divider()
            presetsSection
            Spacer()
        }
        .padding()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Profiles & Docks").font(.title3).bold()
            Text("A profile is a named group of docks. Each dock has its own pinned apps, screen, and visual settings. Switch profiles from the menu bar — every dock in the active profile appears at once.")
                .foregroundStyle(.secondary).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @State private var isEditingDocks = Preferences.shared.isEditingDocks

    @ViewBuilder
    private var profilesList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(mgr.profiles) { p in
                    ProfileRow(profile: p, isEditingDocks: isEditingDocks)
                }
            }
        }
        .frame(minHeight: 280)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
        .onReceive(NotificationCenter.default.publisher(for: Preferences.changed)) { _ in
            isEditingDocks = Preferences.shared.isEditingDocks
        }
    }

    private var profileButtonRow: some View {
        HStack {
            Button {
                if let n = Prompt.string(title: "New Profile", defaultValue: "New Profile") {
                    _ = mgr.addProfile(name: n)
                }
            } label: { Label("New profile", systemImage: "plus") }

            Button {
                let src = mgr.activeProfile
                if let n = Prompt.string(title: "Duplicate Profile", defaultValue: src.name + " Copy") {
                    _ = mgr.addProfile(name: n, duplicateFrom: src.id)
                }
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }

            Spacer()

            // Edit Docks mode toggle — when on, every visible dock shows a red X in the top center for easy deletion.
            Button {
                Preferences.shared.isEditingDocks.toggle()
            } label: {
                Label(isEditingDocks ? "Done" : "Edit", systemImage: isEditingDocks ? "checkmark" : "pencil")
            }
            .foregroundStyle(isEditingDocks ? Color.green : Color.accentColor)
        }
    }

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Suggested profiles").font(.headline)
            Text("Quick-create one of these — it duplicates your active profile as a starting point.")
                .foregroundStyle(.secondary).font(.callout)
            HStack {
                ForEach(["Productivity", "Coding", "Design", "Video", "Gaming"], id: \.self) { preset in
                    Button(preset) {
                        _ = mgr.addProfile(name: preset, duplicateFrom: mgr.activeProfileID)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(mgr.profiles.contains(where: { $0.name == preset }))
                }
            }
        }
    }
}

// MARK: - Profile row

private struct ProfileRow: View {
    let profile: Profile
    let isEditingDocks: Bool
    @ObservedObject private var mgr = ProfileManager.shared
    @State private var renaming: Bool = false
    @State private var rename: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: profile.id == mgr.activeProfileID ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(profile.id == mgr.activeProfileID ? Color.accentColor : Color.secondary)
                if renaming {
                    TextField("Name", text: $rename, onCommit: {
                        mgr.renameProfile(profile.id, to: rename); renaming = false
                    })
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                } else {
                    Text(profile.name)
                        .fontWeight(profile.id == mgr.activeProfileID ? .semibold : .regular)
                        .onTapGesture(count: 2) { rename = profile.name; renaming = true }
                }
                Spacer()
                if profile.id != mgr.activeProfileID {
                    Button("Use") { mgr.setActiveProfile(profile.id) }
                        .buttonStyle(.borderless).controlSize(.small)
                } else {
                    Text("Active").foregroundStyle(.secondary).font(.caption)
                }
                Menu {
                    Button("Rename…") { rename = profile.name; renaming = true }
                    Button("Add Dock…") {
                        if let n = Prompt.string(title: "Add Dock", defaultValue: "New Dock") {
                            _ = mgr.addDock(name: n, in: profile.id)
                            if !Preferences.shared.isEditingLayout {
                                Preferences.shared.isEditingLayout = true
                            }
                        }
                    }
                    Divider()
                    Button("Delete Profile…", role: .destructive) {
                        guard mgr.profiles.count > 1 else { return }
                        let alert = NSAlert()
                        alert.messageText = "Delete profile \"\(profile.name)\"?"
                        alert.informativeText = "This removes every dock in the profile."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "Delete")
                        alert.addButton(withTitle: "Cancel")
                        if alert.runModal() == .alertFirstButtonReturn {
                            mgr.deleteProfile(profile.id)
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            ForEach(profile.dockIDs, id: \.self) { dockID in
                if let dock = mgr.dock(id: dockID) {
                    DockRow(dock: dock, parentProfile: profile, isEditingDocks: isEditingDocks)
                        .padding(.leading, 22)
                }
            }
            HStack {
                Button {
                    if let n = Prompt.string(title: "Add Dock", defaultValue: "New Dock") {
                        _ = mgr.addDock(name: n, in: profile.id)
                        // Auto-enable Edit Layout so the new centered floating dock can be dragged immediately.
                        if !Preferences.shared.isEditingLayout {
                            Preferences.shared.isEditingLayout = true
                        }
                    }
                } label: { Label("Add Dock", systemImage: "plus.rectangle.on.rectangle") }
                .buttonStyle(.borderless)
                .controlSize(.small)
                Spacer()
            }
            .padding(.leading, 22)
            .padding(.top, 2)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
    }
}

// MARK: - Dock row

private struct DockRow: View {
    let dock: DockInstance
    let parentProfile: Profile
    let isEditingDocks: Bool
    @ObservedObject private var mgr = ProfileManager.shared
    @State private var renaming: Bool = false
    @State private var rename: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: dock.id == mgr.editingDockID ? "pencil.circle.fill" : "rectangle.dock")
                .foregroundStyle(dock.id == mgr.editingDockID ? Color.accentColor : Color.secondary)
                .font(.caption)
            if renaming {
                TextField("Name", text: $rename, onCommit: {
                    mgr.renameDock(dock.id, to: rename); renaming = false
                })
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
            } else {
                Text(dock.name).font(.callout)
                    .onTapGesture(count: 2) { rename = dock.name; renaming = true }
            }
            Image(systemName: "display").foregroundStyle(.secondary).font(.caption)
            ScreenPicker(dockID: dock.id, current: dock.screen)
            Spacer()
            if dock.id != mgr.editingDockID {
                Button("Edit") { mgr.setEditingDock(dock.id) }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help("Make this dock the target of the General/Apps tabs")
            } else {
                Text("Editing").foregroundStyle(.secondary).font(.caption)
            }
            Menu {
                Button("Rename…") { rename = dock.name; renaming = true }
                Button("Remove from Profile", role: .destructive) {
                    mgr.removeDock(dock.id)
                }
                .disabled(parentProfile.dockIDs.count <= 1 && parentProfile.id == mgr.activeProfileID)
            } label: { Image(systemName: "ellipsis.circle").font(.caption) }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

// MARK: - Screen picker

private struct ScreenPicker: View {
    let dockID: UUID
    let current: ScreenAssignment
    @State private var screens: [NSScreen] = NSScreen.screens

    var body: some View {
        Menu {
            Button { ProfileManager.shared.setDockScreen(dockID, .allScreens) } label: {
                Label("All screens", systemImage: current == .allScreens ? "checkmark" : "")
            }
            Button { ProfileManager.shared.setDockScreen(dockID, .main) } label: {
                Label("Main screen only", systemImage: current == .main ? "checkmark" : "")
            }
            if screens.count > 1 {
                Divider()
                ForEach(screens, id: \.self) { s in
                    if let uuid = ScreenIdentity.uuid(for: s) {
                        Button {
                            ProfileManager.shared.setDockScreen(dockID, .specific(uuid: uuid, name: ScreenIdentity.displayName(for: s)))
                        } label: {
                            let isSel: Bool = {
                                if case .specific(let u, _) = current { return u == uuid }
                                return false
                            }()
                            Label(ScreenIdentity.displayName(for: s), systemImage: isSel ? "checkmark" : "")
                        }
                    }
                }
            }
        } label: {
            Text(current.label).font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }
}

// MARK: - Helpers

enum Prompt {
    static func string(title: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        tf.stringValue = defaultValue
        alert.accessoryView = tf
        DispatchQueue.main.async { alert.window.makeFirstResponder(tf) }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let v = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}
