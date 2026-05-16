# Focus Dock - Project Agent Rules (Grok)

## Build + Relaunch Mandate (Critical)

This is a native macOS application (Xcode/SwiftUI/AppKit floating NSPanel + menu bar extra).

- Every single time you run a build (`xcodebuild`, clean build, incremental build, etc.), you **must** also relaunch the app afterward.
- You may never finish a build task and stop — the user will still be running the old binary.
- Always use `-derivedDataPath DerivedData` when invoking xcodebuild so the fresh binary is written to the exact path the dev instance uses: `DerivedData/Build/Products/Debug/Focus Dock.app`
- Standard relaunch sequence after a successful build:
  1. `killall "Focus Dock" 2>/dev/null || true`
  2. `sleep 0.6`
  3. `open "DerivedData/Build/Products/Debug/Focus Dock.app"`
- Verify with `ps` that the new PID is using the just-built binary from the local DerivedData before considering the task complete.

This rule exists because the app is a live-replacement Dock (hides system Dock, installs floating panels, runs in the background). Code changes are invisible until the process is replaced.

## Other Standing Rules

- Follow the global `~/.grok/Agents.md` communication style at all times (maximum terseness, act first, no permission-seeking).
- When the user says "deploy", "publish", "ship", or similar, follow the full deployment checklist in `CLAUDE.md`.
- Never ask the user to run build/launch/kill commands — you execute them.