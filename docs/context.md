# Focus: Dock — Build Context

Cumulative summary of decisions, features, bugs fixed, and architectural choices made across the initial build session. Use this as the canonical reference for "why does X work this way" before opening the source.

---

## Problem statement

iOS has a Dock-folder gesture: drag an app onto another, hold ~1 s, icons wiggle (edit mode), a folder forms, and releasing drops the dragged app inside. macOS's Dock has no equivalent.

## Core constraint (do not forget)

Apple's Dock (`Dock.app`) is owned by the system and protected by SIP + the App Store sandbox. Third-party apps **cannot** inject drag behavior, animations, or folder logic into it. The product has to ship as a **replacement dock** that can run alongside or in place of the system Dock. This drove every architectural decision below.

---

## Foundational architecture

- **Language / UI:** SwiftUI + AppKit (`NSPanel`, `NSHostingController`, `NSWorkspace`).
- **Build:** [XcodeGen](https://github.com/yonaskolb/XcodeGen) → `project.yml` is the source of truth. The `.xcodeproj` is generated on every build (and gitignored).
- **Deployment target:** macOS 13.0.
- **Signing:** ad-hoc (`CODE_SIGN_IDENTITY: "-"`) for MVP. Not yet App Store / TestFlight ready.
- **Bundle:**
  - Display name: `Focus: Dock` (CFBundleDisplayName, includes the colon)
  - File-system name: `Focus Dock.app` (no colon for clean paths)
  - Bundle id: `com.theportlandcompany.FocusDock`

### File layout
```
focus-dock-for-macos/
├── project.yml                  # XcodeGen spec
├── Sources/iOSDock/             # Swift sources (folder name retained for git continuity)
│   ├── iOSDockApp.swift         # @main, AppDelegate, menu-bar item, custom dock icon
│   ├── DockWindow.swift         # Floating dock panel, drag/hover/wiggle, magnification, FolderPopover
│   ├── AppLibrary.swift         # DockItem/AppEntry/FolderEntry, persistence, tree mutation
│   ├── Preferences.swift        # UserDefaults-backed settings + RGBA persistence
│   ├── SettingsView.swift       # About / General / Apps tabs + folder tree
│   ├── SystemDockManager.swift  # Read & hide/restore com.apple.dock
│   └── SettingsWindowFallback.swift
├── docs/context.md              # ← this file
└── README.md
```

---

## Feature catalogue

### iOS-style folder creation
- Drag-and-drop on dock items uses a custom `DragGesture` (not SwiftUI's `.onDrag`) so we can observe live position and trigger the wiggle/folder-formation timer at ~0.8 s.
- Each `DockItemView` registers its frame in `ItemFrameRegistry` (a tiny singleton) via a `GeometryReader` in the "dock" coordinate space. Hit-testing is `frame.insetBy(dx: -14, dy: -14).contains(pointer)`, generous so the drop target is forgiving.
- On release: any valid hover target combines (creates / merges into folder) regardless of whether the wiggle threshold fired — matches iOS's "quick drop also works".
- Mutation (`library.combine(...)`) is done *outside* the `withAnimation` spring block; doing it inside caused a "folder appears then disappears" glitch because SwiftUI animated a view that had already had its model index shifted.
- Folder grid icon is a 3×3 mini-tile rendered by `FolderIconView`.

### Magnification
- Gaussian falloff centered on cursor (`onContinuousHover` reports `dockHoverPoint`).
- Icons are **pre-rasterized to 256×256** in `IconCache` (`NSWorkspace.shared.icon` drawn into a fresh high-res `NSImage`). SwiftUI was originally upscaling small-rep icons → blurry; cache forces a high-res source.
- Display uses `.frame(width: iconSize * scale, height: iconSize * scale)` instead of `.scaleEffect()` so SwiftUI rasterizes at the displayed size each frame (no bitmap upscale).
- **Dock height does not change with magnification**: the visible dock chrome is bottom-anchored at `restingThickness` (resting icon size + perpendicular padding + 8). The window itself is sized to fit `max(magnified, effectiveIcon)` so the icons have headroom to grow upward without resizing the chrome.
- The `Magnified size` slider only affects icon growth; bottom of the dock stays put.

### Layout / position
- Default: anchored to the **bottom** of the screen, centered, like the native Dock.
- Settings → General → Layout has:
  - **Snap to edge** picker (Bottom / Top / Left / Right).
  - **Edge offset** slider (distance from anchored edge; ignored when Flush is on).
  - **Edit Layout** toggle — makes the dock draggable. Releasing within ~180 ms snaps it to whichever edge the dock's center is closest to (`windowDidMove` → debounced snap).
  - **Show Finder as the first icon** — virtual Finder entry prepended to renderedItems. Uses a **stable static UUID** so SwiftUI doesn't churn the view identity each render (this was the cause of the "Finder icon jumps" bug).
- **Orientation auto-flips** by edge: bottom/top → `HStack`; left/right → `VStack`. Hit-testing in `DragState` accounts for axis via `isVertical`.

### Flush with edge
- Pref key kept as `flushBottom` for storage compatibility, surfaced as **"Flush with Edge"**.
- Applies to whichever edge the dock is on:
  - `bottom` → `y = area.minY`, square bottom-left + bottom-right
  - `top` → `y = area.maxY - thickness`, square top-left + top-right
  - `left` → `x = area.minX`, square top-left + bottom-left
  - `right` → `x = area.maxX - thickness`, square top-right + bottom-right
- Uses `screen.frame` (full extent) instead of `screen.visibleFrame` so the dock can sit against the absolute edge.
- Corner squaring is implemented via `UnevenRoundedRectangle` (`dockShape` computed property).
- The "dock has a gap below screen edge when flush" bug has reappeared three times historically (commits `401f62d`, `827a29e`, `634bb50`). Root cause is SwiftUI/`NSHostingController` introducing safe-area insets on the borderless `NSPanel`, and ZStack-based edge anchoring is fragile against any sub-pixel rounding the system layer adds. The current defense is **belt-and-suspenders**:
  1. `.ignoresSafeArea()` on the `DockView` root.
  2. ZStack uses `alignment: dockAlignment` so the resting-thickness chrome pins to the configured edge.
  3. `DockHostingController` — a thin `NSHostingController` subclass — negates `view.safeAreaInsets` by setting `additionalSafeAreaInsets` to their negative on every `viewDidLayout`, hard-zeroing the host's safe area at the AppKit level.
  4. **Edge bleed**: when flush, the window frame is extended 3 pt past the screen edge in the perpendicular axis. The chrome stays anchored to the edge inside the larger window, so those 3 pt sit off-screen and any residual SwiftUI inset is swallowed by the bleed. The bleed is invisible (off-screen) so it has no cosmetic cost.
  Do not regress any of these four — removing any single one could re-open the bug under a future macOS / SwiftUI build.

### Padding (inside the dock)
- Four sliders for Top / Bottom / Left / Right *internal* padding (between dock border and icons).
- Earlier the same prefs controlled *screen margins*. Reinterpreted on first launch via a one-time migration (`didMigratePadding`) bumping defaults to padding-appropriate values.
- Top/Bottom were originally swapped because both were applying `.padding(.vertical, paddingTop)` — now uses explicit `.padding(.top, …)` / `.padding(.bottom, …)`.
- **"All" toggle** at top of the section: when on, shows one slider that drives all four uniformly.

### Appearance
- **Icon size** 32–128 pt.
- **Spacing** 0–40 pt — hidden when "Fill width" is on (auto-spacing).
- **Fill width** toggle — sizes the dock to `screen.width - 16` and computes spacing automatically: `(interior - n × icon) / (n - 1)`.
- **Labels** picker: Tool tip (system native), Above icon, Below icon.
- **Magnify on hover** + **Magnified size** slider.
- **Corner radius** slider (0–40 pt).

### Dock background & border
- Background uses `NSVisualEffectView` material `.popover` (theme-aware light/dark) as the base. An optional tint overlay (RGBA + alpha) is drawn on top of the blur, behind the border.
- Border: show/hide toggle, color + opacity picker, width slider 0–6 pt.
- Color values persist as `[r,g,b,a]` arrays via the `Preferences.RGBA` struct, bridged to SwiftUI `Color` through `rgbaBinding(_:)` (round-trips through sRGB `NSColor`).
- A small custom **color preview swatch** appears next to each `ColorPicker` showing the chosen hue at full opacity (separate from macOS's diagonal-split swatch which can be confusing at low alpha).

### Click-to-edit numbers
- `EditableNumber` SwiftUI view: shows monospaced text, click → focused `TextField`, commits on Return / focus-loss. Applied to every numeric slider (icon size, spacing, magnified, border width, corner radius, edge offset, all padding sliders).

### Labels & tooltips
- `nativeToolTip(_ text: String)` is a custom helper that sets `NSView.toolTip` directly via an `NSViewRepresentable`. SwiftUI's built-in `.help()` was being intercepted by `.onContinuousHover` on the dock background and didn't reliably register on the complex DockItemView hierarchy. The native helper bypasses that.

### Tree view (Settings → Apps)
- Top-level items + folders shown with collapsible chevrons.
- Folders are renamable inline (`TextField` bound to `library.renameFolder`) and have a per-folder **Columns** picker (Auto / 1–6).
- Drag-and-drop: app rows drag with the app's UUID via `NSItemProvider`. Drop targets are folder rows (drop-into) or a dashed "move to top level" row at the bottom.
- Empty folders auto-remove.
- A gear button in the folder popover sends a `SettingsRouter.openFolder` notification → AppDelegate opens Settings → Apps tab → tree expands the matching folder.

### Folder popover
- Responsive size: width and column count compute from `folder.columns ?? min(5, ceil(√count))`.
- Inline-rename folder name (double-click to edit).
- Apps inside honor the dock's `labelMode` (tooltip / above / below).

### Behavior (macOS Dock parity)
Settings → General → Behavior toggles:
- Automatically hide and show the dock — pref only (visual not yet implemented).
- Animate opening applications (bounce) — pref only.
- **Show indicators for open applications** — implemented: small dot below running app icons, matched against `NSWorkspace.shared.runningApplications` by bundle URL.
- Show recent apps in dock — pref only.

The three system-window settings from macOS's Desktop & Dock pane (minimize animation, title-bar double-click action, minimize-into-app-icon) are intentionally omitted — they're system-window behaviors only Apple's Dock can control. The "system-settings banner" idea was explicitly dismissed (cannot inject UI into Apple's System Settings).

### System integration
- **System Settings link** at the top of every Settings tab opens macOS's Desktop & Dock pane via `x-apple.systempreferences:com.apple.preference.dock`.
- **System Dock take-over:** on first launch the app prompts the user; accepting writes `autohide`, `autohide-delay`, `autohide-time-modifier` in `com.apple.dock` and runs `killall Dock`. Original values are stashed in our UserDefaults and restored on `applicationWillTerminate` or via the live Settings toggle.
- **About tab** has a green "Your system Dock is safe" badge confirming restore-on-quit/uninstall.
- **About tab** has a purple "Help shape Focus: Dock" badge with View on GitHub / Submit an issue links.
- **About → Installed files & permissions** disclosure lists every path the app touches (with reveal-in-Finder buttons) and every permission used. Explicit note: no Accessibility or Screen Recording permission is requested.

### Settings window
- Three tabs: About / General / Apps.
- First time settings is shown → defaults to **About** tab. Every subsequent open → **General** (controlled by a `hasSeenSettings` UserDefault flag).
- **Resizable** (`.frame(minWidth: 480, idealWidth: 600, maxWidth: .infinity, minHeight: 420, idealHeight: 560, maxHeight: .infinity)`).
- Reliable settings opening: tries `showSettingsWindow:` (macOS 14+) → `showPreferencesWindow:` → main-menu Settings item → `SettingsWindowFallback.show()` which manually hosts `SettingsView` in a plain `NSWindow`.

### Reset
- Every controllable preference in General has a circular-arrow reset button next to it with a confirmation dialog.
- A "Reset All to Defaults" destructive button at the bottom of General returns every value to defaults (apps and folders not affected).
- All defaults centralized in `Preferences.defaultValues : [Key: Any]`. RGBA prefs are special-cased in `reset(_:)`/`resetAll()`.
- The "Use macOS Native Default" buttons in the Background/Border sections were removed per user request (per-setting + Reset All cover that need).

### App identity / icon
- Custom-drawn app icon: iOS-style blue→purple gradient with a 3×3 grid of white rounded squares, generated at launch via `NSApp.applicationIconImage` (no asset catalog needed for MVP).
- Activation policy is hard-coded to `.regular`. The "Show Dock Icon" pref was removed since the system Dock is hidden anyway.

---

## Key bugs found and fixed (in order, for future-debugging context)

1. **Initial dock window invisible** — `NSPanel` with titled style was only rendering the red close button against transparent content. Switched to `.borderless, .nonactivatingPanel`.
2. **Settings window didn't open reliably** — multi-selector fallback (`showSettingsWindow:` → `showPreferencesWindow:` → main-menu → `SettingsWindowFallback`).
3. **Icons blurry on hover** — `.scaleEffect` upscales rasterized bitmap. Switched to `.frame(width:height:)` with pre-rasterized 256pt source.
4. **Magnification grew dock window** — bottom-anchored chrome with separate `restingThickness`.
5. **Drop didn't create folder** — model mutation was inside `withAnimation`; SwiftUI animated a view whose model had already moved. Moved mutation outside.
6. **Margins did nothing** — `flushBottom` had silently been written `true`; original code made flush *override* `marginBottom`. Re-architected so margins → internal padding, added a separate `edgeOffset`, and flush no longer overrides positioning logic on padding.
7. **"Flush with Edge" left a gap** — `NSHostingController` applies SwiftUI safe-area insets to borderless panels. Fixed via `.ignoresSafeArea()`.
8. **Finder icon hover-jumped** — virtual Finder entry got a fresh `UUID()` each render; SwiftUI saw a new view identity each tick. Fixed with a static `finderID` constant.
9. **Top/Bottom padding swapped** — both were using `.padding(.vertical, paddingTop)`. Switched to explicit `.top` / `.bottom` modifiers.
10. **Tooltips didn't appear** — SwiftUI's `.help()` was intercepted by `.onContinuousHover` on the parent. Replaced with `nativeToolTip(_:)` (sets `NSView.toolTip` via a representable).
11. **Dock height grew past visible icons when icon-size slider maxed** — `effectiveIcon` (post-compression) now drives the thickness calculation in `applyLayout`, not the raw slider value.
12. **Crash on launch from invalid UUID string** — `UUID(uuidString: "F1ND3R00-…")` returned nil because of `N` and `R` (non-hex). Replaced with a valid hex literal.

---

## Privacy & permissions

The app does **not** request Accessibility, Full Disk Access, or Screen Recording. Operations it performs:
- Modifies `com.apple.dock` user defaults and runs `killall Dock`.
- Reads installed app icons via `NSWorkspace.shared.icon(forFile:)`.
- Launches apps via `NSWorkspace.shared.open(_:)`.
- Reads/writes `~/Library/Application Support/FocusDock/library.json`.
- Reads/writes its own UserDefaults plist.
- Displays a borderless non-activating `NSPanel` at `floating` window level.

---

## Open work / not yet implemented

- **Restore-on-uninstall**: `applicationWillTerminate` only fires on clean quit. Trashing the app while running won't restore the system Dock. Robust fix needs a LaunchAgent that runs at login and restores prefs if the app has been deleted.
- **TestFlight / App Store**: requires real Developer ID team, App Sandbox entitlements, security-scoped bookmarks for user-added app paths, archive + notarization.
- **Auto-hide dock**, **bounce-on-launch**, **show-recent-apps** prefs are storable but not yet wired to visual behavior.
- **Scroll-on-overflow with chevron arrows** — currently overflowing icons are compressed instead. Either/both behaviors could be added with a toggle.
- **Right-click context menus** on dock icons (keep in dock, options, quit-running-app, etc.).
- **Multiple displays**: layout uses `NSScreen.main`; multi-monitor behavior isn't tested.
