import Foundation
import Synchronization

/// Folder sizes computed in the background (P1-6), shared app-wide and keyed by real path.
///
/// Each entry remembers the FSEvents id from just before it was measured: a view that shows the
/// folder again replays FSEvents since then and invalidates only what changed (a change anywhere
/// inside a folder changes its size — and its ancestors' sizes). Bounded: the oldest entries go
/// first beyond `limit`.
public final class FolderSizeCache: Sendable {
    public static let shared = FolderSizeCache()

    public struct Entry: Sendable, Equatable {
        public let totals: ItemStatistics.Totals
        /// FSEvents id taken just before measuring started.
        public let eventID: UInt64
        public init(totals: ItemStatistics.Totals, eventID: UInt64) {
            self.totals = totals
            self.eventID = eventID
        }
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var order: [String] = [] // insertion order, for trimming
    }

    private let state = Mutex(State())
    public let limit: Int

    public init(limit: Int = 20_000) { self.limit = limit }

    public func entry(_ path: String) -> Entry? {
        let key = FolderTree.normalized(path)
        return state.withLock { $0.entries[key] }
    }

    public func store(_ entry: Entry, for path: String) {
        let key = FolderTree.normalized(path)
        state.withLock { s in
            if s.entries.updateValue(entry, forKey: key) == nil { s.order.append(key) }
            if s.order.count > limit {
                let drop = s.order.count - limit
                for old in s.order.prefix(drop) { s.entries[old] = nil }
                s.order.removeFirst(drop)
            }
        }
    }

    /// Something changed in these folders (FSEvents directory paths): every cached folder that contains
    /// one of them (the folder itself and its ancestors) is out of date. Returns the paths dropped.
    @discardableResult
    public func invalidate(changed paths: some Sequence<String>) -> Set<String> {
        state.withLock { s in
            var dropped = Set<String>()
            for path in paths {
                var current = FolderTree.normalized(path)
                while true {
                    if s.entries.removeValue(forKey: current) != nil { dropped.insert(current) }
                    guard current != "/", !current.isEmpty else { break }
                    current = FolderTree.normalized((current as NSString).deletingLastPathComponent)
                }
            }
            if !dropped.isEmpty { s.order.removeAll { dropped.contains($0) } }
            return dropped
        }
    }

    /// Like `invalidate(changed:)` with each change's FSEvents id: an entry measured after a change
    /// (its `eventID` is newer) already includes it and stays. Returns the paths dropped.
    @discardableResult
    public func invalidate(changedAt changes: [String: UInt64]) -> Set<String> {
        state.withLock { s in
            var dropped = Set<String>()
            for (path, id) in changes {
                var current = FolderTree.normalized(path)
                while true {
                    if let entry = s.entries[current], entry.eventID < id {
                        s.entries[current] = nil
                        dropped.insert(current)
                    }
                    guard current != "/", !current.isEmpty else { break }
                    current = FolderTree.normalized((current as NSString).deletingLastPathComponent)
                }
            }
            if !dropped.isEmpty { s.order.removeAll { dropped.contains($0) } }
            return dropped
        }
    }

    /// FSEvents lost detail below `path`: everything at or below it (and its ancestors) is out of date.
    @discardableResult
    public func invalidate(subtree path: String) -> Set<String> {
        let base = FolderTree.normalized(path)
        let prefix = base == "/" ? "/" : base + "/"
        let below: [String] = state.withLock { s in s.entries.keys.filter { $0.hasPrefix(prefix) } }
        return invalidate(changed: below + [base])
    }

    public var count: Int { state.withLock { $0.entries.count } }
    public func removeAll() { state.withLock { $0 = State() } }
}
