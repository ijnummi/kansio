import Foundation

/// The folders most recently copied or moved to with Copy To / Move To (P3-3), newest first, no duplicates
/// (paths compared as `FolderUsage.key` does: without a trailing slash, canonically equal), at most `limit`.
public struct RecentDestinations: Codable, Equatable, Sendable {
    public private(set) var paths: [String] = []
    public var limit: Int

    public init(limit: Int = 8) { self.limit = limit }

    public mutating func add(_ path: String) {
        let key = FolderUsage.key(path)
        paths.removeAll { $0 == key }
        paths.insert(key, at: 0)
        if paths.count > limit { paths.removeLast(paths.count - limit) }
    }

    public mutating func remove(_ path: String) {
        let key = FolderUsage.key(path)
        paths.removeAll { $0 == key }
    }

    public mutating func removeAll() { paths = [] }
}
