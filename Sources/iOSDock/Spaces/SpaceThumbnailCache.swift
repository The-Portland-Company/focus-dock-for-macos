import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit
import os

// Compiled out of the App Store build: thumbnails are part of the private-API
// desktop-strip feature (DMG/dev only). ScreenCaptureKit itself is public,
// but without the SkyLight spaces bridge there is nothing to key captures by.
#if !APPSTORE

/// Real per-Space screenshot thumbnails for the desktop strip (M4).
///
/// We can only photograph what is on screen, so the cache captures the
/// CURRENT space of each display and files it under that display's
/// current-space uuid. Thumbnails therefore accumulate as the user visits
/// desktops; spaces never visited keep their gradient placeholders.
///
/// Capture triggers (all current-space-only, all cheap):
///  a) `NSWorkspace.activeSpaceDidChangeNotification` + 0.4 s settle delay,
///     re-verified against SpacesBridge so a mid-transition frame is never
///     filed under the wrong uuid. This also covers "after a successful
///     switch" — SpaceSwitcher's switches land on the same notification.
///  b) strip open (DesktopStripFeature.toggleStrip → captureCurrentSpaces).
///  c) a 60 s timer while the feature is enabled, so a long-lived desktop's
///     thumbnail stays fresh.
///
/// Storage: memory `[space uuid: NSImage]` (published for live tile updates)
/// + disk at ~/Library/Application Support/FocusDock/spaceThumbs/<uuid>.jpg
/// (≤480 px wide, JPEG 0.7) so a relaunch shows thumbnails immediately.
/// Orphan files (uuids no longer in the space list) are pruned at startup;
/// names in SpaceNameStore are deliberately NOT pruned the same way.
///
/// Permission: everything is gated on `CGPreflightScreenCaptureAccess()`.
/// When Screen Recording is missing we never call the capture APIs (no
/// re-prompt loops, no log spam) — the strip simply keeps its placeholders.
/// `requestPermission()` (Settings, user-initiated) asks once per session.
final class SpaceThumbnailCache: ObservableObject {
    private static let log = Logger(subsystem: "com.theportlandcompany.FocusDock", category: "Spaces")

    /// uuid → thumbnail. Published so visible strip tiles re-render the
    /// moment a capture (or the warm disk load) lands.
    @Published private(set) var images: [String: NSImage] = [:]

    private static let maxThumbWidth = 480
    private static let jpegQuality: CGFloat = 0.7
    private static let settleDelay: TimeInterval = 0.4
    private static let timerInterval: TimeInterval = 60

    /// Background queue for disk I/O, downscale and JPEG encode.
    private let io = DispatchQueue(label: "com.theportlandcompany.FocusDock.SpaceThumbnailCache", qos: .utility)
    private var spaceObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    /// Displays with a capture in flight — collapses overlapping triggers.
    private var inFlightDisplays: Set<String> = []

    // MARK: - Lifecycle

    init() {
        Self.log.info("thumbs: cache started, screenRecording=\(self.hasPermission) sck=\(Self.usesScreenCaptureKit, privacy: .public)")
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleSpaceChange() }
        // Weak self so the timer never retains the cache past stop()/teardown.
        let timer = Timer.scheduledTimer(withTimeInterval: Self.timerInterval, repeats: true) { [weak self] _ in
            self?.captureCurrentSpaces(reason: "timer")
        }
        timer.tolerance = 5
        refreshTimer = timer
        warmFromDiskAndPrune()
        // Seed the current desktop right away (same path as the strip-open
        // refresh) so the first strip open already has at least one thumb.
        captureCurrentSpaces(reason: "start")
    }

    deinit { stop() }

    /// Tears down the timer + observer. Called by DesktopStripFeature when
    /// the feature is disabled or the app quits; idempotent.
    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
    }

    // MARK: - Permission

    /// True when Screen Recording is granted. When false no capture API is
    /// ever called — tiles keep their gradient placeholders.
    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Static twin for UI that needs the state before/without a live cache
    /// instance (the Settings tab while the feature is toggled off).
    static var permissionGranted: Bool { CGPreflightScreenCaptureAccess() }

    private static var permissionRequestedThisSession = false

    /// Shows the system Screen Recording prompt (or just returns the current
    /// state if the user already decided). User-initiated from Settings only;
    /// guarded so repeat clicks don't hammer TCC.
    func requestPermission() { Self.requestPermission() }

    static func requestPermission() {
        guard !permissionRequestedThisSession else { return }
        permissionRequestedThisSession = true
        let granted = CGRequestScreenCaptureAccess()
        log.info("thumbs: screen-recording request → granted=\(granted)")
    }

    // MARK: - Lookup

    func image(for uuid: String) -> NSImage? { images[uuid] }

    // MARK: - Capture triggers

    /// Captures the current space of every display (strip open, timer, start).
    func captureCurrentSpaces(reason: String) {
        guard hasPermission else { return }
        for (displayIdentifier, uuid) in Self.currentSpacesByDisplay() {
            capture(displayIdentifier: displayIdentifier, spaceUUID: uuid, reason: reason)
        }
    }

    /// Space changed (user gesture, our switcher, anything): wait for the
    /// slide animation to settle, then re-verify each display still shows the
    /// space we saw at notification time before photographing it. If another
    /// switch happened meanwhile, skip — its own notification handles it.
    private func handleSpaceChange() {
        guard hasPermission else { return }
        let expected = Self.currentSpacesByDisplay()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self else { return }
            for (displayIdentifier, uuid) in Self.currentSpacesByDisplay()
            where expected[displayIdentifier] == uuid {
                self.capture(displayIdentifier: displayIdentifier, spaceUUID: uuid, reason: "spaceChange")
            }
        }
    }

    /// displayIdentifier → current space uuid, fresh from SkyLight.
    private static func currentSpacesByDisplay() -> [String: String] {
        var result: [String: String] = [:]
        for display in SpacesBridge.fetchDisplaySpaces() {
            if let uuid = display.currentSpaceUUID { result[display.displayIdentifier] = uuid }
        }
        return result
    }

    // MARK: - Capture

    private static var usesScreenCaptureKit: Bool {
        if #available(macOS 14.0, *) { return true } else { return false }
    }

    private func capture(displayIdentifier: String, spaceUUID: String, reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard hasPermission else { return }
        guard !inFlightDisplays.contains(displayIdentifier) else { return }
        guard let screen = SpacesModel.screen(forDisplayIdentifier: displayIdentifier),
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            Self.log.warning("thumbs: no screen for display \(displayIdentifier, privacy: .public), skipping capture")
            return
        }
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        inFlightDisplays.insert(displayIdentifier)

        let finish: (CGImage?, String?) -> Void = { [weak self] cgImage, failure in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlightDisplays.remove(displayIdentifier)
                guard let cgImage else {
                    Self.log.error("thumbs: capture(\(reason, privacy: .public)) failed for \(displayIdentifier, privacy: .public): \(failure ?? "unknown", privacy: .public)")
                    return
                }
                // Capture has latency of its own — drop the frame if the
                // display moved to another space while it was being taken.
                let current = SpacesBridge.fetchDisplaySpaces()
                    .first { $0.displayIdentifier == displayIdentifier }?.currentSpaceUUID
                guard current == spaceUUID else {
                    Self.log.info("thumbs: dropped stale frame for \(spaceUUID, privacy: .public) (space changed mid-capture)")
                    return
                }
                self.store(cgImage, for: spaceUUID, reason: reason)
            }
        }

        if #available(macOS 14.0, *) {
            Self.captureViaScreenCaptureKit(displayID: displayID, completion: finish)
        } else {
            captureViaCoreGraphics(displayID: displayID, completion: finish)
        }
    }

    /// macOS 14+: ScreenCaptureKit single-frame capture, scaled to thumbnail
    /// size at the source and with OUR windows (dock panels, strip) excluded
    /// so they never pollute the shot.
    @available(macOS 14.0, *)
    private static func captureViaScreenCaptureKit(displayID: CGDirectDisplayID, completion: @escaping (CGImage?, String?) -> Void) {
        // excludingDesktopWindows: false — we WANT the wallpaper in the thumb.
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            guard let content else {
                completion(nil, "SCShareableContent: \(error?.localizedDescription ?? "no content")")
                return
            }
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                completion(nil, "no SCDisplay for id \(displayID)")
                return
            }
            let ourPID = pid_t(ProcessInfo.processInfo.processIdentifier)
            let ourApps = content.applications.filter { $0.processID == ourPID }
            let filter = SCContentFilter(display: scDisplay, excludingApplications: ourApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let aspect = Double(scDisplay.height) / Double(max(1, scDisplay.width))
            config.width = maxThumbWidth
            config.height = max(1, Int((Double(maxThumbWidth) * aspect).rounded()))
            config.showsCursor = false
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                completion(image, error?.localizedDescription)
            }
        }
    }

    /// macOS 13 fallback. No window exclusion is possible here — our dock may
    /// appear in the thumb, which is acceptable on 13 (plan-approved).
    private func captureViaCoreGraphics(displayID: CGDirectDisplayID, completion: @escaping (CGImage?, String?) -> Void) {
        io.async {
            // Deprecated from macOS 15, but this branch only runs on 13.x
            // (ScreenCaptureKit's SCScreenshotManager handles 14+).
            guard let full = CGDisplayCreateImage(displayID) else {
                completion(nil, "CGDisplayCreateImage returned nil")
                return
            }
            completion(full, nil)
        }
    }

    // MARK: - Store (memory publish + disk write)

    private func store(_ raw: CGImage, for uuid: String, reason: String) {
        io.async { [weak self] in
            guard let self else { return }
            let cg = Self.downscale(raw, maxWidth: Self.maxThumbWidth) ?? raw
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            DispatchQueue.main.async {
                self.images[uuid] = image
                Self.log.info("thumbs: cached \(cg.width)x\(cg.height) for \(uuid, privacy: .public) (\(reason, privacy: .public))")
            }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: Self.jpegQuality]) else {
                Self.log.error("thumbs: JPEG encode failed for \(uuid, privacy: .public)")
                return
            }
            do {
                try FileManager.default.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true)
                try data.write(to: Self.fileURL(for: uuid), options: .atomic)
            } catch {
                Self.log.error("thumbs: disk write failed for \(uuid, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// ≤ maxWidth, preserving aspect. Returns the input untouched when it is
    /// already small enough (the ScreenCaptureKit path scales at the source).
    private static func downscale(_ image: CGImage, maxWidth: Int) -> CGImage? {
        guard image.width > maxWidth else { return image }
        let scale = Double(maxWidth) / Double(image.width)
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: maxWidth, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: height))
        return ctx.makeImage()
    }

    // MARK: - Disk cache

    static var directoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("FocusDock/spaceThumbs", isDirectory: true)
    }

    private static func fileURL(for uuid: String) -> URL {
        directoryURL.appendingPathComponent("\(uuid).jpg")
    }

    /// Startup pass: prune thumbnails for uuids no longer in the space list
    /// (names are kept — only thumbs are pruned, per plan), then load the
    /// surviving files into memory so a warm relaunch shows thumbnails
    /// immediately, no revisits needed.
    private func warmFromDiskAndPrune() {
        io.async { [weak self] in
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: Self.directoryURL, includingPropertiesForKeys: nil)
            else { return } // no cache dir yet — nothing to warm or prune
            let live = Set(SpacesBridge.fetchDisplaySpaces().flatMap { $0.spaces.map(\.uuid) })
            var loaded: [String: NSImage] = [:]
            var pruned = 0
            for file in files where file.pathExtension.lowercased() == "jpg" {
                let uuid = file.deletingPathExtension().lastPathComponent
                // Only prune against a healthy space list; if the bridge ever
                // returns [] (shape drift) keep everything.
                if !live.isEmpty && !live.contains(uuid) {
                    try? fm.removeItem(at: file)
                    pruned += 1
                    continue
                }
                if let image = NSImage(contentsOf: file) { loaded[uuid] = image }
            }
            if pruned > 0 { Self.log.info("thumbs: pruned \(pruned) orphan thumbnail file(s)") }
            guard !loaded.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Captures that landed while we were reading disk win.
                self.images.merge(loaded) { fresh, _ in fresh }
                Self.log.info("thumbs: warmed \(loaded.count) thumbnail(s) from disk")
            }
        }
    }
}

#endif
