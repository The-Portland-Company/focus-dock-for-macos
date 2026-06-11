import Foundation
import AppKit
import os

// Compiled out of the App Store build: MultitouchSupport is a private
// framework (no MAS-allowed symbols). Callers go through the ungated
// DesktopStripFeature facade. The @_silgen_name decls follow the same SPI
// pattern as MinimizeAnimator.swift / SpacesBridge.swift.
#if !APPSTORE

// MARK: - Private MultitouchSupport.framework SPI bridge
//
// MTDeviceCreateList / MTRegisterContactFrameCallback let us read raw trackpad
// contacts (position + velocity per finger, every frame) so we can detect a
// 3+ finger upward swipe ourselves and open OUR strip — the system swipe-up
// for Mission Control is consumed by the WindowServer and cannot be swallowed
// by an event tap, so we observe the multitouch stream directly instead.
//
// The framework is loaded via dlopen at runtime (it is not in a normal link
// path); the function pointers are resolved with dlsym. Defensive: if any
// symbol is missing the monitor self-disables (no crash, system swipe still
// works).

/// One finger's normalized position. MultitouchSupport reports `normalized`
/// with x,y in 0…1 (origin bottom-left), plus per-axis velocity.
private struct MTPoint { var x: Float; var y: Float }
private struct MTVector { var position: MTPoint; var velocity: MTPoint }

/// Mirror of the framework's MTTouch struct prefix. We only read the leading
/// fields (frame, timestamp, identifier, state, …, normalized vector); the
/// struct is larger but trailing fields are ignored. Layout verified against
/// the public reverse-engineered headers used by every multitouch utility.
private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var pathIndex: Int32
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    var normalized: MTVector
    var zTotal: Float
    var unknown1: Int32
    var size: Float
    var unknown2: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVector
    var unknown3: Int32
    var unknown4: Int32
    var unknown5: Float
    var unknown6: Float
}

private typealias MTDeviceRef = UnsafeMutableRawPointer
private typealias MTContactCallback = @convention(c) (
    MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Int32

private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTRegisterFn = @convention(c) (MTDeviceRef?, MTContactCallback) -> Void
private typealias MTStartFn = @convention(c) (MTDeviceRef?, Int32) -> Void
private typealias MTStopFn = @convention(c) (MTDeviceRef?) -> Void

/// Detects a fast 3-or-4-finger upward swipe on any trackpad and calls
/// `DesktopStripFeature.handleSwipeUp()`. Debounced so one physical swipe =
/// one toggle. While the strip is already open a swipe-up is ignored (the
/// strip's own Esc / outside-click closes it) — documented behavior.
enum TrackpadGestureMonitor {
    private static let log = Logger(subsystem: "com.theportlandcompany.FocusDock", category: "Spaces")

    private static var handle: UnsafeMutableRawPointer?
    private static var devices: [MTDeviceRef] = []
    private static var mtStop: MTStopFn?
    private static var running = false

    // Gesture-tracking state (touched only on the MT callback thread + the
    // small synchronized debounce on main).
    private static var gestureStartY: [Int32: Float] = [:]   // fingerID → start y
    private static var lastFireTime: TimeInterval = 0

    /// Velocity (normalized units/sec, y-up) every contributing finger must
    /// exceed, and the minimum normalized vertical travel, to count as a swipe.
    private static let minFingers = 3
    private static let minUpwardVelocity: Float = 0.9
    private static let minUpwardTravel: Float = 0.12
    private static let debounceInterval: TimeInterval = 0.6

    static var isRunning: Bool { running }

    @discardableResult
    static func start() -> Bool {
        guard !running else { return true }
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY) else {
            log.error("TrackpadGestureMonitor: dlopen MultitouchSupport failed — four-finger swipe-up unavailable")
            return false
        }
        handle = h
        guard let createPtr = dlsym(h, "MTDeviceCreateList"),
              let registerPtr = dlsym(h, "MTRegisterContactFrameCallback"),
              let startPtr = dlsym(h, "MTDeviceStart"),
              let stopPtr = dlsym(h, "MTDeviceStop") else {
            log.error("TrackpadGestureMonitor: missing MultitouchSupport symbols — swipe-up disabled")
            cleanup()
            return false
        }
        let create = unsafeBitCast(createPtr, to: MTDeviceCreateListFn.self)
        let register = unsafeBitCast(registerPtr, to: MTRegisterFn.self)
        let mtStart = unsafeBitCast(startPtr, to: MTStartFn.self)
        mtStop = unsafeBitCast(stopPtr, to: MTStopFn.self)

        // NB: a CFArray of opaque MTDevice pointers does NOT bridge to a Swift
        // [UnsafeMutableRawPointer] via `as?` (the elements aren't CFTypes Swift
        // can box), so read it manually with the CFArray C API — otherwise the
        // cast silently yields nil and the monitor wrongly reports "no trackpad".
        guard let listRef = create()?.takeRetainedValue() else {
            log.info("TrackpadGestureMonitor: MTDeviceCreateList returned null — swipe-up inactive")
            cleanup()
            return false
        }
        let count = CFArrayGetCount(listRef)
        guard count > 0 else {
            log.info("TrackpadGestureMonitor: no multitouch devices — swipe-up inactive (no trackpad?)")
            cleanup()
            return false
        }
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(listRef, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            register(device, contactCallback)
            mtStart(device, 0)
            devices.append(device)
        }
        guard !devices.isEmpty else {
            log.info("TrackpadGestureMonitor: device list had \(count) entries but none usable")
            cleanup()
            return false
        }
        running = true
        log.info("TrackpadGestureMonitor: observing \(devices.count) trackpad device(s) for 4-finger swipe-up")
        return true
    }

    static func stop() {
        guard running || handle != nil else { return }
        if let mtStop {
            for device in devices { mtStop(device) }
        }
        devices.removeAll()
        gestureStartY.removeAll()
        cleanup()
        running = false
        log.info("TrackpadGestureMonitor: stopped")
    }

    private static func cleanup() {
        if let handle { dlclose(handle) }
        handle = nil
        mtStop = nil
    }

    // MARK: - Contact callback (runs on a MultitouchSupport thread)

    private static let contactCallback: MTContactCallback = { _, touchesRaw, count, _, _ in
        guard let touchesRaw, count > 0 else {
            gestureStartY.removeAll()
            return 0
        }
        let touches = touchesRaw.bindMemory(to: MTTouch.self, capacity: Int(count))
        var active: [(id: Int32, y: Float, vy: Float)] = []
        for i in 0..<Int(count) {
            let t = touches[i]
            // state 4 = "touching" (full contact). Ignore lift/hover frames.
            guard t.state == 4 else { continue }
            active.append((t.fingerID, t.normalized.position.y, t.normalized.velocity.y))
        }

        guard active.count >= minFingers else {
            if active.isEmpty { gestureStartY.removeAll() }
            return 0
        }

        // Record each finger's first-seen y so we can measure total travel.
        for f in active where gestureStartY[f.id] == nil {
            gestureStartY[f.id] = f.y
        }

        // Require ALL contributing fingers moving upward fast, and the group's
        // average travel to exceed the distance threshold.
        let allMovingUpFast = active.allSatisfy { $0.vy >= minUpwardVelocity }
        let travels = active.compactMap { f -> Float? in
            guard let start = gestureStartY[f.id] else { return nil }
            return f.y - start
        }
        let avgTravel = travels.isEmpty ? 0 : travels.reduce(0, +) / Float(travels.count)

        if allMovingUpFast && avgTravel >= minUpwardTravel {
            let now = Date().timeIntervalSinceReferenceDate
            if now - lastFireTime >= debounceInterval {
                lastFireTime = now
                gestureStartY.removeAll()
                DispatchQueue.main.async { DesktopStripFeature.handleSwipeUp() }
            }
        }
        return 0
    }
}

#endif
