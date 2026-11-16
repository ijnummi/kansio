import AppKit
import FileSystemKit
import UniformTypeIdentifiers

/// One icon per type, not per file. Lookups are by lowercased extension → UTType → NSImage.
/// `NSWorkspace.icon(for:)` returns an IconServices image that is re-rendered on every
/// draw (~40 µs each); we rasterize it once per type into 16 pt bitmaps (1× and 2×), so
/// drawing a row is a plain bitmap blit. Items with their own icon (apps, custom icons,
/// links) use `FileIconLoader` and show the type icon until theirs arrives.
@MainActor
final class IconCache {
    static let shared = IconCache()

    private var byExtension: [String: NSImage] = [:]
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
        if let cached = byExtension[key] { return cached }
        let conformance: UTType = item.kind == .directory ? .package : .data
        let type = UTType(filenameExtension: ext, conformingTo: conformance) ?? conformance
        let image = Self.rasterized(NSWorkspace.shared.icon(for: type))
        byExtension[key] = image
        return image
    }

    nonisolated static let pointSize = NSSize(width: 16, height: 16)

    static func rasterized(_ icon: NSImage) -> NSImage {
        let result = NSImage(size: pointSize)
        rasterizedReps(icon).forEach { result.addRepresentation($0) }
        return result
    }

    /// Renders `icon` into bitmap representations at 1× and 2× of `pointSize`.
    /// Safe off the main thread (each call draws into its own bitmap context).
    nonisolated static func rasterizedReps(_ icon: NSImage) -> [NSBitmapImageRep] {
        [1, 2].compactMap { scale in
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
