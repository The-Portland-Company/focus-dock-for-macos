import Foundation
import Darwin

/// Last-resort hooks that try to restore the system Dock when the app exits
/// through an abnormal path (signals, atexit). The normal quit path is handled
/// by `applicationShouldTerminate` / `applicationWillTerminate` in AppDelegate.
///
/// Notes:
/// - Signal handlers must be async-signal-safe. `SystemDockManager.restoreSystemDock`
///   uses CFPreferences + Process, which is NOT strictly async-signal-safe. We
///   accept that risk because the alternative (Dock stays hidden across reboots)
///   is worse. If the handler hangs or crashes, the OS still tears the process
///   down — at worst we get the same end state we'd have without a handler.
/// - `atexit` runs on normal exit() and is generally safe; we use it as a
///   secondary backstop.
enum QuitBackstop {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        atexit {
            if SystemDockManager.isHidden {
                SystemDockManager.restoreSystemDock()
            }
        }

        // Catch the common termination signals. Re-raise after restoring so
        // the default disposition still takes effect (correct exit status).
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            signal(sig) { received in
                if SystemDockManager.isHidden {
                    SystemDockManager.restoreSystemDock()
                }
                // Re-raise with default handler so the exit code reflects the signal.
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }
}
