import Foundation
import AppKit

/// Tracks whether `~/.Trash` is empty so the dock's Trash icon can render
/// the correct empty/full bitmap.
///
/// macOS makes this annoyingly hard for unsandboxed third-party apps:
///   * `FileManager.contentsOfDirectory(atPath: ~/.Trash)` → EPERM (TCC).
///   * In-process `NSAppleScript → Finder` → TCC refuses to even prompt for
///     ad-hoc-signed apps ("Policy disallows prompt for ...").
///   * The system Dock's AX tree exposes the trash item but no attribute
///     reveals its empty/full state.
///
/// What does work: shelling out to `/usr/bin/osascript`. It's an
/// Apple-signed binary whose AppleEvents authorization is independent of
/// ours, so macOS shows a normal Automation prompt for it (once) and
/// remembers the answer.
final class TrashWatcher {
    static let shared = TrashWatcher()

    private var timer: Timer?
    private let pollInterval: TimeInterval = 3.0

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
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "tell application \"Finder\" to count items of trash"]
            let out = Pipe(); let err = Pipe()
            task.standardOutput = out
            task.standardError = err
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                NSLog("[TrashWatcher] task.run failed: \(error)")
                return
            }
            let stdoutText = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderrText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            NSLog("[TrashWatcher] exit=\(task.terminationStatus) out=\(stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).debugDescription) err=\(stderrText.trimmingCharacters(in: .whitespacesAndNewlines).debugDescription)")
            guard task.terminationStatus == 0,
                  let count = Int(stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))
            else { return }
            let isEmpty = count == 0
            DispatchQueue.main.async {
                if AppLibrary.shared.trashIsEmpty != isEmpty {
                    AppLibrary.shared.trashIsEmpty = isEmpty
                    NSLog("[TrashWatcher] published isEmpty=\(isEmpty)")
                }
            }
        }
    }
}
