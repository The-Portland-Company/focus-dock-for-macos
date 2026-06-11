import SwiftUI
import AppKit

// Compiled out of the App Store build alongside the controller.
#if !APPSTORE

/// The Mission-Control-style bar hosted in each DesktopStripPanel: one tile
/// per Space of THAT panel's display, in flat SkyLight order. M3: clicking a
/// tile switches to that Space (SpaceSwitcher via the facade); tiles are only
/// dimmed/non-switchable when Accessibility is missing. Still gradient
/// placeholders — real screenshots land in M4.
struct DesktopStripView: View {
    @ObservedObject var model: SpacesModel
    @ObservedObject var uiState: DesktopStripUIState
    let displayIdentifier: String
    let tileWidth: CGFloat

    /// Bumped when SpaceNameStore changes so tiles re-resolve their names
    /// (e.g. a rename made in the Settings tab while the strip is open).
    @State private var nameVersion = 0

    private var display: DisplaySpaces? {
        model.displays.first { $0.displayIdentifier == displayIdentifier }
    }

    var body: some View {
        let spaces = display?.spaces ?? []
        let currentUUID = display?.currentSpaceUUID
        HStack(spacing: DesktopStripMetrics.tileSpacing) {
            ForEach(spaces, id: \.uuid) { space in
                SpaceTileView(
                    space: space,
                    number: model.desktopNumber(for: space.uuid),
                    isCurrent: space.uuid == currentUUID,
                    nameVersion: nameVersion,
                    tileWidth: tileWidth,
                    uiState: uiState
                )
            }
        }
        .padding(.horizontal, DesktopStripMetrics.horizontalPadding)
        .padding(.vertical, DesktopStripMetrics.verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: DesktopStripMetrics.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesktopStripMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        )
        .onReceive(NotificationCenter.default.publisher(for: SpaceNameStore.changed)) { _ in
            nameVersion &+= 1
        }
    }
}

// MARK: - Tile

private struct SpaceTileView: View {
    let space: SpaceInfo
    let number: Int?
    let isCurrent: Bool
    let nameVersion: Int
    let tileWidth: CGFloat
    @ObservedObject var uiState: DesktopStripUIState

    @State private var draft = ""
    @FocusState private var renameFocused: Bool

    private var isRenamingThis: Bool { uiState.renamingUUID == space.uuid }
    private var isSelected: Bool { uiState.selectedUUID == space.uuid }
    private var thumbHeight: CGFloat { tileWidth * 10 / 16 }

    private var displayName: String {
        _ = nameVersion // re-resolve when the name store changes
        guard space.isUserDesktop else { return "Full Screen" }
        return SpaceNameStore.shared.name(for: space.uuid, defaultNumber: number ?? 0)
    }

    var body: some View {
        VStack(spacing: DesktopStripMetrics.labelGap) {
            thumbnail
            nameArea
        }
    }

    // MARK: Thumbnail (placeholder until M4 real screenshots)

    private var ringColor: Color {
        if isCurrent { return .accentColor }
        if isSelected { return .white.opacity(0.85) }
        return .white.opacity(0.18)
    }

    private var ringWidth: CGFloat { (isCurrent || isSelected) ? 3 : 1 }

    @ViewBuilder private var thumbnail: some View {
        ZStack {
            if space.isUserDesktop {
                LinearGradient(colors: desktopGradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                // Fullscreen-app space: dark tile + app-window glyph.
                LinearGradient(
                    colors: [Color(white: 0.16), Color(white: 0.30)],
                    startPoint: .top, endPoint: .bottom
                )
                Image(systemName: "macwindow")
                    .font(.system(size: thumbHeight * 0.36, weight: .light))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(width: tileWidth, height: thumbHeight)
        // Dimmed + non-interactive only when Accessibility is missing
        // (SpaceSwitcher can't post key events without it). Rename below
        // works either way.
        .opacity(SpaceSwitcher.canSwitch ? 1.0 : 0.55)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(ringColor, lineWidth: ringWidth)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture {
            guard SpaceSwitcher.canSwitch else { return }
            DesktopStripFeature.requestSwitch(to: space.uuid)
        }
        .allowsHitTesting(SpaceSwitcher.canSwitch)
        .help(SpaceSwitcher.canSwitch
              ? "Click to switch to this desktop"
              : "Grant Accessibility permission to switch desktops")
    }

    /// Wallpaper-ish blue/purple gradient, hue-shifted per desktop number so
    /// adjacent tiles are distinguishable.
    private var desktopGradient: [Color] {
        let n = Double(number ?? 1)
        let hue = (0.55 + (n - 1) * 0.055).truncatingRemainder(dividingBy: 1.0)
        return [
            Color(hue: hue, saturation: 0.55, brightness: 0.85),
            Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1.0), saturation: 0.65, brightness: 0.55)
        ]
    }

    // MARK: Name / inline rename

    @ViewBuilder private var nameArea: some View {
        Group {
            if isRenamingThis {
                TextField("Desktop \(number ?? 0)", text: $draft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .focused($renameFocused)
                    .onSubmit { commitRename() }          // Return commits
                    .onExitCommand { cancelRename() }     // Esc cancels
                    .onChange(of: renameFocused) { focused in
                        // Focus drifted away (click elsewhere in the bar) →
                        // commit, matching the EditableNumber pattern.
                        if !focused, isRenamingThis { commitRename() }
                    }
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.black.opacity(0.30))
                    )
            } else {
                Text(displayName)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        // Fullscreen-app spaces have no editable name.
                        guard space.isUserDesktop else { return }
                        beginRename()
                    }
                    .help(space.isUserDesktop ? "Double-click to rename" : "")
            }
        }
        .frame(width: tileWidth, height: DesktopStripMetrics.labelHeight)
    }

    private func beginRename() {
        draft = SpaceNameStore.shared.customName(for: space.uuid) ?? ""
        uiState.renamingUUID = space.uuid
        // The panel is key-but-non-activating; defer focus a tick so the
        // field exists before FocusState takes effect.
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        guard isRenamingThis else { return }
        SpaceNameStore.shared.setName(draft, for: space.uuid)
        uiState.renamingUUID = nil
    }

    private func cancelRename() {
        guard isRenamingThis else { return }
        uiState.renamingUUID = nil
    }
}

#endif
