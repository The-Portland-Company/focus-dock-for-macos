import SwiftUI
import AppKit

struct ProfilesTab: View {
    @ObservedObject private var mgr = ProfileManager.shared
    @State private var selection: UUID? = nil
    @State private var editingID: UUID? = nil
    @State private var editingName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Profiles")
                .font(.title3).bold()
            Text("Each profile has its own pinned apps and dock-visual settings (edge, size, padding, colors). Switch between them from the menu bar.")
                .foregroundStyle(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $selection) {
                ForEach(mgr.profiles) { p in
                    HStack {
                        Image(systemName: p.id == mgr.activeID ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(p.id == mgr.activeID ? Color.accentColor : Color.secondary)
                        if editingID == p.id {
                            TextField("Name", text: $editingName, onCommit: {
                                mgr.renameProfile(p.id, to: editingName)
                                editingID = nil
                            })
                            .textFieldStyle(.roundedBorder)
                        } else {
                            Text(p.name)
                                .fontWeight(p.id == mgr.activeID ? .semibold : .regular)
                                .onTapGesture(count: 2) {
                                    editingName = p.name
                                    editingID = p.id
                                }
                        }
                        Spacer()
                        if p.id != mgr.activeID {
                            Button("Use") { mgr.setActive(p.id) }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                        } else {
                            Text("Active").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                    .tag(p.id)
                }
            }
            .frame(minHeight: 200)

            HStack {
                Button {
                    let name = promptName(title: "New Profile", defaultValue: "New Profile")
                    if let n = name {
                        let id = mgr.addProfile(name: n)
                        selection = id
                    }
                } label: { Label("New", systemImage: "plus") }

                Button {
                    let src = selection ?? mgr.activeID
                    let srcName = mgr.profiles.first(where: { $0.id == src })?.name ?? "Profile"
                    if let n = promptName(title: "Duplicate Profile", defaultValue: srcName + " Copy") {
                        let id = mgr.addProfile(name: n, duplicateFrom: src)
                        selection = id
                    }
                } label: { Label("Duplicate", systemImage: "plus.square.on.square") }

                Button(role: .destructive) {
                    let id = selection ?? mgr.activeID
                    guard mgr.profiles.count > 1 else { return }
                    guard let p = mgr.profiles.first(where: { $0.id == id }) else { return }
                    let alert = NSAlert()
                    alert.messageText = "Delete profile \"\(p.name)\"?"
                    alert.informativeText = "This removes its pinned apps and dock settings. This cannot be undone."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Delete")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        mgr.deleteProfile(id)
                    }
                } label: { Label("Delete", systemImage: "trash") }
                .disabled(mgr.profiles.count <= 1)

                Spacer()
            }

            Divider().padding(.vertical, 4)

            Text("Suggested starting profiles")
                .font(.headline)
            Text("Quick-create one of these — it duplicates your current active profile as a starting point.")
                .foregroundStyle(.secondary).font(.callout)
            HStack {
                ForEach(["Productivity", "Coding", "Design", "Video", "Gaming"], id: \.self) { preset in
                    Button(preset) {
                        let id = mgr.addProfile(name: preset, duplicateFrom: mgr.activeID)
                        selection = id
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(mgr.profiles.contains(where: { $0.name == preset }))
                }
            }

            Spacer()
        }
        .padding()
    }

    private func promptName(title: String, defaultValue: String) -> String? {
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
