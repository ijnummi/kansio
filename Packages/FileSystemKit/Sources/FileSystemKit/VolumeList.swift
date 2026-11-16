import Foundation

/// A mounted, user-visible volume (what the sidebar's "Volumes" section shows).
public struct Volume: Sendable, Hashable {
    public let url: URL
    public let name: String
    public let isRoot: Bool
    public let isInternal: Bool
    public let isEjectable: Bool
    public let isNetwork: Bool

    public init(url: URL, name: String, isRoot: Bool, isInternal: Bool, isEjectable: Bool, isNetwork: Bool) {
        self.url = url
        self.name = name
        self.isRoot = isRoot
        self.isInternal = isInternal
        self.isEjectable = isEjectable
        self.isNetwork = isNetwork
    }

    /// True if `path` is this volume's mount point or inside it.
    public func contains(path: String) -> Bool {
        let mount = url.path(percentEncoded: false)
        let prefix = mount.hasSuffix("/") ? mount : mount + "/"
        return path == mount || path.hasPrefix(prefix) || path + "/" == prefix
    }
}

public enum VolumeList {
    static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey,
        .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
    ]

    /// Mounted browsable volumes: the startup disk first, then by name (Finder order).
    /// Blocking — a stale network mount can make this slow; use `mountedVolumes()` from async code.
    public static func mountedBlocking() -> [Volume] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let volumes: [Volume] = urls.compactMap { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.volumeIsBrowsable == false { return nil }
            let isRoot = v?.volumeIsRootFileSystem == true
            return Volume(
                url: url,
                name: v?.volumeLocalizedName ?? (isRoot ? "Macintosh HD" : url.lastPathComponent),
                isRoot: isRoot,
                isInternal: v?.volumeIsInternal == true,
                isEjectable: v?.volumeIsEjectable == true || v?.volumeIsRemovable == true,
                isNetwork: v?.volumeIsLocal == false
            )
        }
        return volumes.sorted { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            return NameCollation.compare(a.name, b.name) == .orderedAscending
        }
    }

    /// `mountedBlocking()` on the listing queue (never blocks the main thread or the cooperative pool).
    public static func mountedVolumes() async -> [Volume] {
        await runOnListingQueue { mountedBlocking() }
    }
}
