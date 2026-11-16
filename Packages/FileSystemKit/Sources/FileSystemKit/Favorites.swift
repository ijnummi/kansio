import Foundation

/// A pinned folder (P1-2). The path is what was last seen; the bookmark finds the folder again
/// after it was renamed or moved (it records the file's identity, not just its path).
public struct FavoriteEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var path: String
    public var bookmark: Data?
    /// The folder's name as last seen (shown while the bookmark is being resolved).
    public var title: String

    public init(id: UUID = UUID(), path: String, bookmark: Data? = nil, title: String? = nil) {
        self.id = id
        self.path = FolderTree.normalized(path)
        self.bookmark = bookmark
        self.title = title ?? (path as NSString).lastPathComponent
    }

    public var url: URL { URL(filePath: path, directoryHint: .isDirectory) }
}

/// The ordered Favorites list: pin (no duplicates), unpin, reorder, update after resolving.
public struct FavoriteList: Codable, Sendable, Equatable {
    public private(set) var entries: [FavoriteEntry]

    public init(_ entries: [FavoriteEntry] = []) { self.entries = entries }

    public func index(ofPath path: String) -> Int? {
        let normalized = FolderTree.normalized(path)
        return entries.firstIndex { $0.path == normalized }
    }

    public func contains(path: String) -> Bool { index(ofPath: path) != nil }

    /// Pins `entry` at `index` (end when nil). False if that folder is already pinned.
    @discardableResult
    public mutating func pin(_ entry: FavoriteEntry, at index: Int? = nil) -> Bool {
        guard !contains(path: entry.path) else { return false }
        let position = min(max(index ?? entries.count, 0), entries.count)
        entries.insert(entry, at: position)
        return true
    }

    public mutating func unpin(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// Moves the entry at `from` so it lands before the entry currently at `to` (`to == count`: last) —
    /// the index a drop between rows reports.
    public mutating func move(from: Int, to: Int) {
        guard entries.indices.contains(from), (0...entries.count).contains(to) else { return }
        let entry = entries.remove(at: from)
        entries.insert(entry, at: to > from ? to - 1 : to)
    }

    /// After resolving a bookmark: the folder's current location (and a fresh bookmark if it was stale).
    public mutating func update(_ id: UUID, path: String, title: String, bookmark: Data?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].path = FolderTree.normalized(path)
        entries[i].title = title
        if let bookmark { entries[i].bookmark = bookmark }
    }
}

/// Bookmark data for pinned folders (blocking: call off the main thread — resolving can touch a
/// network volume). Never mounts volumes or shows UI.
public enum Bookmarks {
    public static func make(_ url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public enum Resolution: Sendable, Equatable {
        /// The folder is here (maybe moved/renamed); `refreshed` replaces stale bookmark data.
        case found(URL, refreshed: Data?)
        /// Deleted, in the Trash, or on a volume that isn't mounted.
        case missing
    }

    public static func resolve(_ data: Data) -> Resolution {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return .missing }
        let path = url.path(percentEncoded: false)
        // A folder moved to the Trash still resolves — to the Trash. For Favorites that's "missing"
        // (kept, dimmed: Undo brings it back and the bookmark finds it again).
        if path.contains("/.Trash/") || path.contains("/.Trashes/") { return .missing }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return .missing }
        return .found(url, refreshed: stale ? make(url) : nil)
    }
}
