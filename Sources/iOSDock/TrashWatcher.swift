import Foundation
import AppKit

/// Tracks whether `~/.Trash` is empty so the dock's Trash icon can render
/// the correct empty/full bitmap.
///
/// We can't just read the directory: macOS TCC blocks `~/.Trash` for any
/// process without Full Disk Access, and `FileManager.contentsOfDirectory`
/// returns EPERM. Instead we ask Finder, which owns the Trash, via
/// AppleScript. That requires Automation permission for Finder — macOS
/// prompts the user once and remembers the answer.
final class TrashWatcher {
    static let shared = TrashWatcher()

    private var timer: Timer?
    private let pollInterval: TimeInterval = 3.0
    private let script = NSAppleScript(source: "tell application \"Finder\" to count items of trash")

    func start() {
        stop()
        tick()
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // Run the AppleScript off the main thread — Finder can take a beat
        // to answer if it's busy, and the result is published back on main.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var err: NSDictionary?
            let result = self.script?.executeAndReturnError(&err)
            guard err == nil, let result, result.descriptorType != 0 else { return }
            let count = Int(result.int32Value)
            let isEmpty = count == 0
            DispatchQueue.main.async {
                if AppLibrary.shared.trashIsEmpty != isEmpty {
                    AppLibrary.shared.trashIsEmpty = isEmpty
                }
            }
        }
    }
}
