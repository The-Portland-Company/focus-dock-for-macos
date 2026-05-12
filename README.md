# Focus: Dock

An iOS-style replacement dock for macOS that supports **folder creation by drag-and-hold**, the one Dock feature Apple never shipped on the Mac.

Drag any app onto another, hold for about a second, and a folder forms — exactly like iOS. Drop and the app drops in.

---

## Why a replacement dock instead of modifying the real one?

Apple's Dock (the process `Dock.app`) is owned by the system and protected by System Integrity Protection and the App Store sandbox. Third-party apps cannot inject drag behavior, animations, or folder logic into it. The only way to deliver this feature is to ship a separate dock that runs alongside — or in place of — the system Dock.

When you launch the app, it offers to hide the system Dock automatically. Quitting Focus: Dock (or deleting it from `/Applications`) restores the native Dock to its original state. Nothing about the system Dock is permanently altered.

---

## Features

### iOS-style folder creation
- Drag an app onto another to start a folder.
- Holding ~0.8 s triggers iOS "edit mode": all icons begin to **wiggle** and a folder-formation halo appears under the target.
- Releasing inside a folder appends to it; releasing on a plain app converts it into a 2-app folder.
- Quick drop (under the 0.8 s threshold) also creates the folder — like iOS.
- Folder icons render the iOS-style 3×3 mini-grid of contained app icons.
- Tapping a folder opens a popover showing all apps inside; tap any app to launch.

### Cloning & coexistence with the system Dock
- On first launch, the app reads `com.apple.dock` → `persistent-apps` and seeds itself with your existing Dock contents.
- "Clone System Dock" button in Settings → Apps re-clones any time.
- "Take over the macOS Dock?" dialog on first launch optionally hides the system Dock by writing `autohide`, `autohide-delay`, and `autohide-time-modifier` in `com.apple.dock`, then `killall Dock`.
- Original values are saved and **automatically restored** on app quit or uninstall.
- Live toggle in Settings → General → System Dock lets you hide/show the system Dock at any time.

### Folder Tree View (Settings → Apps)
- Collapsible folders with chevrons; inline rename via plain `TextField`.
- Full drag-and-drop:
  - Drag any app row (top-level or nested) onto a folder to move it in.
  - Drag onto the dashed "Drop here to move to top level" zone at the bottom to pull an app out of a folder.
  - Folders auto-remove when emptied.
- Per-row trash button removes from anywhere in the tree.
- "Add App…" picks `.app` bundles via `NSOpenPanel`.

### Magnification (native-style)
- Hover causes nearby icons to scale up with a Gaussian falloff, centered on the cursor.
- Magnified icons grow *upward* into headroom; the dock background height does not change.
- Icons are pre-rasterized at 256×256 (via `NSWorkspace.shared.icon` drawn into a high-res `NSImage`) so magnified icons stay sharp instantly — no second-pass "snap into focus" blur.

### Layout & position
- Default snaps the dock to the **bottom** of the screen, centered, matching the native Dock.
- "Edit Layout" mode (toggle in the menu bar or Settings) makes the dock draggable; release near any screen edge to snap there — bottom, top, left, or right.
- Orientation auto-flips: bottom/top render horizontally; left/right render vertically.
- Four screen-margin sliders (Top/Bottom/Right/Left) push the dock inward from the corresponding edge and constrain its perpendicular size.

### Appearance
- **Icon size** slider (32–128 pt).
- **Spacing** slider (0–40 pt).
- **Labels**: Tool tip (system native), Above icon, or Below icon.
- **Magnify on hover** toggle + **magnified size** slider (up to 192 pt).
- **Corner radius** slider (0–40 pt).
- **Flush with bottom of screen** toggle — drops the dock against the absolute screen bottom and squares off the bottom-left/bottom-right corners via `UnevenRoundedRectangle`.
- **Dock background** — toggle a custom tint over the system blur material; full color + opacity picker; "Use macOS Native Default" button.
- **Dock border** — show/hide toggle; color + opacity picker; width slider (0–6 pt, 0.5 step); "Use macOS Native Default" button (white at 12 % opacity, 0.5 pt).
- All chrome uses `NSVisualEffectView` with the `.popover` material, so the dock adapts to Light and Dark mode automatically.

### Presentation
- **Show Dock icon** toggle — switches `NSApp.setActivationPolicy` live between `.regular` and `.accessory`.
- **Show menu-bar (Toolbar) icon** toggle — installs/removes an `NSStatusItem` with Show Dock / Edit Layout / Settings… / Quit menu items.
- A custom-drawn app icon (iOS-style blue→purple gradient with a 3×3 grid) is rendered at launch via `NSApp.applicationIconImage`.

### Reset & defaults
- Every controllable preference in General has a circular-arrow reset button next to it; a confirmation dialog appears before any reset.
- **Reset All to Defaults** button at the bottom of General returns every value to its built-in default (apps and folders are not touched).
- All defaults are centralized in `Preferences.defaultValues` keyed by `Preferences.Key`.

### Settings window
- Three tabs: **About**, **General**, **Apps**.
- About is the default tab on the very first time Settings is shown; from then on **General** is the default. (Controlled by a `hasSeenSettings` flag.)
- About includes:
  - App icon, name, version.
  - Plain-English explanation of what the app does.
  - Explanation of why a replacement dock is necessary.
  - **Green badge** confirming the system Dock is restored on quit / uninstall.
  - **Installed files & permissions** accordion listing every file path the app uses (with a "reveal in Finder" magnifier button per row) and every permission the app exercises (with SF Symbol icons and detailed descriptions). No Accessibility or Screen Recording permission is requested.

---

## Privacy & permissions

The app does **not** request Accessibility, Full Disk Access, or Screen Recording. Specifically, it:

- Modifies `com.apple.dock` user defaults (autohide, autohide-delay, autohide-time-modifier) and runs `killall Dock` to apply.
- Reads installed app icons via `NSWorkspace.shared.icon(forFile:)`.
- Launches other applications via `NSWorkspace.shared.open(_:)` when you click an icon.
- Reads/writes its own library file at `~/Library/Application Support/FocusDock/library.json`.
- Reads/writes its own UserDefaults plist (`~/Library/Preferences/com.theportlandcompany.FocusDock.plist`).
- Displays a borderless non-activating `NSPanel` at floating window level.

---

## Building

Requirements:
- macOS 13.0 or newer (Apple Silicon or Intel).
- Xcode 15+ or Command Line Tools.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/The-Portland-Company/focus-dock-for-macos.git
cd focus-dock-for-macos
xcodegen generate
xcodebuild -project FocusDock.xcodeproj -scheme FocusDock -configuration Debug -derivedDataPath build build
cp -R "build/Build/Products/Debug/Focus Dock.app" "/Applications/Focus Dock.app"
open "/Applications/Focus Dock.app"
```

---

## Project layout

```
focus-dock-for-macos/
├── project.yml              # XcodeGen spec
├── Sources/iOSDock/         # Swift sources (folder name retained for git history)
│   ├── iOSDockApp.swift     # @main, AppDelegate, menu-bar item, dock-icon drawing
│   ├── DockWindow.swift     # Floating dock panel, drag/hover/wiggle, magnification
│   ├── AppLibrary.swift     # DockItem/AppEntry/FolderEntry, persistence, tree mutation
│   ├── Preferences.swift    # UserDefaults-backed settings + RGBA persistence
│   ├── SettingsView.swift   # About / General / Apps tabs + folder tree
│   ├── SystemDockManager.swift # Read & hide/restore com.apple.dock
│   └── SettingsWindowFallback.swift
└── README.md
```

---

## Status

**MVP** — not yet on the App Store or TestFlight. Currently builds with ad-hoc signing.

Open work for App Store submission:
- App Sandbox entitlements + security-scoped bookmarks for app paths added by the user.
- Notarization & signing with a real Developer ID.
- LaunchAgent for restore-on-uninstall (currently restore is only guaranteed on clean quit).

---

## License

© The Portland Company. All rights reserved.
