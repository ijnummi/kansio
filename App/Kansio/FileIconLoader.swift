import AppKit
import FileSystemKit

/// Per-file icons for the few items whose icon isn't determined by their type: apps,
/// items with a custom icon, Finder aliases and symlinks (target icon + arrow badge).
///
/// Loading reads the bundle / resource fork, so it happens off the main thread, only for
/// rows that are on screen, and is cancelled when the row scrolls away or the folder changes.
/// Results are rasterized once (16 pt at 1× and 2×) and cached by path + modification date.
@MainActor
final class FileIconLoader {
    /// Called with the path whose icon just arrived.
    var onLoaded: ((String) -> Void)?

    /// Shared by all windows; in-flight loads belong to one view.
    private static var cache: [String: NSImage] = [:]
    private var inflight: [String: Task<Void, Never>] = [:]
    private let maxCached = 4000

    static func needsPerFileIcon(_ item: FileItem) -> Bool {
        if item.kind == .symlink || item.flags.contains(.alias) || item.flags.contains(.customIcon) { return true }
        return item.kind == .directory && item.isPackage && item.pathExtension == "app"
    }

    private static func key(path: String, item: FileItem) -> String {
        "\(path)\u{0}\(item.modificationDate.timeIntervalSinceReferenceDate)"
    }

    /// The cached icon, or nil after starting a background load (the caller shows the type icon meanwhile).
    func icon(forPath path: String, item: FileItem) -> NSImage? {
        let key = Self.key(path: path, item: item)
        if let cached = Self.cache[key] { return cached }
        guard inflight[path] == nil else { return nil }
        inflight[path] = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else { return }
            let reps = Self.load(path: path)
            guard !Task.isCancelled else { return }
            await self?.finish(path: path, key: key, reps: reps)
        }
        return nil
    }

    /// Cancels loads for paths no longer on screen.
    func retainOnly(_ visiblePaths: Set<String>) {
        for (path, task) in inflight where !visiblePaths.contains(path) {
            task.cancel()
            inflight[path] = nil
        }
    }

    func cancelAll() {
        inflight.values.forEach { $0.cancel() }
        inflight.removeAll()
    }

    private func finish(path: String, key: String, reps: SendableReps?) {
        inflight[path] = nil
        guard let reps else { return }
        if Self.cache.count >= maxCached { Self.cache.removeAll(keepingCapacity: true) }
        let image = NSImage(size: IconCache.pointSize)
        reps.reps.forEach { image.addRepresentation($0) }
        Self.cache[key] = image
        onLoaded?(path)
    }

    /// Off-main: fetch the effective icon (what Finder shows) and rasterize it.
    nonisolated private static func load(path: String) -> SendableReps? {
        let url = URL(filePath: path)
        guard let icon = (try? url.resourceValues(forKeys: [.effectiveIconKey]))?.effectiveIcon as? NSImage else { return nil }
        return SendableReps(reps: IconCache.rasterizedReps(icon))
    }
}

/// Bitmap reps are immutable once drawn; safe to hand from the loader thread to main.
struct SendableReps: @unchecked Sendable {
    let reps: [NSBitmapImageRep]
}
