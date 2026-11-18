import AppKit
import FileSystemKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted (on main) when type icons finished rasterizing; visible rows should refresh their icons.
    static let typeIconsDidChange = Notification.Name("KansioTypeIconsDidChange")
}

/// One icon per type, not per file. Lookups are by lowercased extension → UTType → NSImage.
///
/// `NSWorkspace.icon(for:)` returns an IconServices image that is re-rendered on every draw
/// (~40 µs each), so each type is rasterized once into 16 pt bitmaps (1×, 2× and 3× — the 48 px one serves the
/// list's larger zoom levels, up to 24 pt icons on Retina) and drawing a
/// row is a plain blit. Rasterizing costs ~0.5 ms per type, which adds up to a dropped frame
/// the first time a folder with many new types appears — so it happens off the main thread:
/// unseen types show the generic icon for a frame and are swapped in when ready. Common types
/// are pre-warmed at launch. Items with their own icon (apps, custom icons, links) use
/// `FileIconLoader`.
@MainActor
final class IconCache {
    static let shared = IconCache()

    private var byKey: [String: NSImage] = [:]
    private var inflight: Set<String> = []
    private var notifyPending = false
    private lazy var folder = Self.rasterized(NSWorkspace.shared.icon(for: .folder))
    private lazy var genericFile = Self.rasterized(NSWorkspace.shared.icon(for: .data))
    private lazy var symlink = Self.rasterized(NSWorkspace.shared.icon(for: .symbolicLink))
    private lazy var genericPackage = Self.rasterized(NSWorkspace.shared.icon(for: .package))
    private lazy var application = Self.rasterized(NSWorkspace.shared.icon(for: .applicationBundle))

    func icon(for item: FileItem) -> NSImage {
        if item.isFolder { return folder }
        if item.kind == .symlink { return item.flags.contains(.linkToPackage) ? genericPackage : symlink }
        let ext = item.pathExtension
        if ext.isEmpty { return item.kind == .directory ? genericPackage : genericFile }
        if item.kind == .directory && ext == "app" { return application }
        let key = item.kind == .directory ? "/" + ext : ext
        if let cached = byKey[key] { return cached }
        load([key])
        return item.kind == .directory ? genericPackage : genericFile
    }

    /// Rasterizes icons for common extensions in the background (call at launch).
    func prewarm() {
        load(["txt", "pdf", "jpg", "jpeg", "png", "heic", "gif", "md", "rtf", "doc", "docx", "xls", "xlsx",
              "ppt", "pptx", "key", "pages", "numbers", "zip", "dmg", "pkg", "mov", "mp4", "mp3", "m4a", "wav",
              "html", "css", "js", "json", "xml", "swift", "c", "h", "py", "sh", "log", "csv", "svg", "webp", "tiff"])
    }

    private func load(_ keys: [String]) {
        let todo = keys.filter { byKey[$0] == nil && !inflight.contains($0) }
        guard !todo.isEmpty else { return }
        inflight.formUnion(todo)
        Task.detached(priority: .userInitiated) { [todo] in
            let results = todo.map { key in (key, SendableReps(reps: Self.rasterizedReps(Self.typeIcon(forKey: key)))) }
            await IconCache.shared.finish(results)
        }
    }

    private func finish(_ results: [(String, SendableReps)]) {
        for (key, reps) in results {
            inflight.remove(key)
            let image = NSImage(size: Self.pointSize)
            reps.reps.forEach { image.addRepresentation($0) }
            byKey[key] = image
        }
        guard !notifyPending else { return }
        notifyPending = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.notifyPending = false
                NotificationCenter.default.post(name: .typeIconsDidChange, object: nil)
            }
        }
    }

    /// Off-main: the system icon for a cache key ("ext" for files, "/ext" for packages).
    nonisolated private static func typeIcon(forKey key: String) -> NSImage {
        let isPackage = key.hasPrefix("/")
        let ext = isPackage ? String(key.dropFirst()) : key
        let conformance: UTType = isPackage ? .package : .data
        let type = UTType(filenameExtension: ext, conformingTo: conformance) ?? conformance
        return NSWorkspace.shared.icon(for: type)
    }

    nonisolated static let pointSize = NSSize(width: 16, height: 16)

    static func rasterized(_ icon: NSImage) -> NSImage {
        let result = NSImage(size: pointSize)
        rasterizedReps(icon).forEach { result.addRepresentation($0) }
        return result
    }

    /// The folder icon (menus of folders).
    var folderIcon: NSImage { folder }

    /// Renders `icon` into bitmap representations at 1×, 2× and 3× of `pointSize` (NSImage picks the closest one
    /// for each drawing size: 16 pt on Retina uses the 32 px one, 24 pt the 48 px one).
    /// Safe off the main thread (each call draws into its own bitmap context).
    nonisolated static func rasterizedReps(_ icon: NSImage) -> [NSBitmapImageRep] {
        [1, 2, 3].compactMap { scale in
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(pointSize.width) * scale, pixelsHigh: Int(pointSize.height) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }
            rep.size = pointSize
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            icon.draw(in: NSRect(origin: .zero, size: pointSize))
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
    }
}
