# Stable Development Code Signing (Recommended)

## The Problem

Every time you run `xcodebuild` + relaunch during development, macOS shows the Accessibility permission dialog again.

This happens because the project was using ad-hoc signing (`CODE_SIGN_IDENTITY: "-"`) . Every rebuild produces a binary with a **different code signature hash**. macOS's TCC system treats it as a brand new app, so the Accessibility grant doesn't stick.

## The Solution: One Stable Development Certificate

Create a long-lived self-signed code signing certificate. Once created, it stays in your Keychain and produces the **same signature** across hundreds of rebuilds.

### One-time Setup (macOS 14+ / Sonoma+)

Run these commands in Terminal:

```bash
# 1. Create a self-signed code signing certificate valid for 5 years
security delete-certificate -c "Focus Dock Developer" ~/Library/Keychains/login.keychain-db 2>/dev/null || true

openssl req -new -newkey rsa:2048 -x509 -days 1825 -nodes \
  -subj "/CN=Focus Dock Developer" \
  -out /tmp/focus-dock-dev.cer \
  -keyout /tmp/focus-dock-dev.key

# 2. Import it into your login keychain as a trusted code signing cert
security import /tmp/focus-dock-dev.cer -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
security import /tmp/focus-dock-dev.key -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign

# 3. Trust it for code signing (prevents "untrusted" warnings)
security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db /tmp/focus-dock-dev.cer

# 4. Clean up
rm /tmp/focus-dock-dev.cer /tmp/focus-dock-dev.key
```

### Verify

```bash
security find-identity -v -p codesigning
```

You should see something like:

```
  1) XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX "Focus Dock Developer"
```

### After Setup

1. Run `xcodegen` (or just open the project — it should regenerate).
2. In Xcode, for the **Debug** configuration, you should now see **"Focus Dock Developer"** selected instead of "Sign to Run Locally".
3. Clean build once (`Shift + Command + K`).
4. Grant Accessibility permission one last time.

From now on, `xcodebuild` + relaunch cycles should **no longer** trigger repeated Accessibility prompts.

## Reverting (if needed)

If you want to go back to ad-hoc signing temporarily:

Edit `project.yml` and change the Debug section back to:

```yaml
Debug:
  CODE_SIGN_STYLE: Automatic
  CODE_SIGN_IDENTITY: "-"
```

Then regenerate the project.

## Notes

- This certificate is only for local development. Production builds (DMG) should continue using a real Apple Developer ID certificate + notarization.
- The certificate name **must** match exactly: `Focus Dock Developer`.
- You only need to do this setup once per machine.