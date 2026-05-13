import Foundation

/// Watches `~/.Trash` and bumps `AppLibrary.trashTick` whenever the directory
/// changes. We need this because `IconCache` already returns the correct
/// empty/full bin icon at lookup time, but nothing else re-renders the dock
/// when the trash transitions between empty and non-empty.
final class TrashWatcher {
    static let shared = TrashWatcher()

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    func start() {
        stop()
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .link, .extend],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            AppLibrary.shared.trashTick &+= 1
            // Re-arm by reopening — some events (delete/rename of the dir
            // itself) invalidate the descriptor. In practice ~/.Trash isn't
            // deleted, but if a mass-empty replaces it, we want to recover.
            if let self = self, src.data.contains(.delete) || src.data.contains(.rename) {
                self.start()
            }
        }
        src.setCancelHandler {
            close(descriptor)
        }
        src.resume()
        fd = descriptor
        source = src
        // Seed once so the icon is correct immediately on launch.
        AppLibrary.shared.trashTick &+= 1
    }

    func stop() {
        source?.cancel()
        source = nil
        fd = -1
    }
}
