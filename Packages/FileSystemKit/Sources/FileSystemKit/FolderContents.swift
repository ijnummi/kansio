import Foundation

/// The single, global sort setting (Explorer-style: one setting for every folder).
public struct FileSort: Sendable, Hashable, Codable {
    public enum Field: String, Sendable, Hashable, Codable, CaseIterable {
        case name, dateModified, dateCreated, size, kind
        /// P1-7: the Extension column ("extension" in saved settings and column identifiers).
        case fileExtension = "extension"
    }

    public var field: Field
    public var ascending: Bool

    public init(field: Field, ascending: Bool = true) {
        self.field = field
        self.ascending = ascending
    }

    public static let `default` = FileSort(field: .name)
}

/// An immutable snapshot of a folder's entries plus precomputed sort keys.
///
/// Building it costs one localized name sort (the expensive part). After that,
/// `ordered(by:)` for *any* column sorts plain integer keys, with the name rank as
/// tie-breaker, so re-sorting never compares strings.
public struct FolderContents: Sendable {
    public let items: [FileItem]
    /// `nameRank[i]` = position of `items[i]` in localized standard name order.
    public let nameRank: [UInt32]

    public init(items: [FileItem], locale: Locale = .current) {
        self.items = items
        self.nameRank = NameCollation.ranks(of: items.map(\.name), locale: locale)
    }

    private init(items: [FileItem], nameRank: [UInt32]) {
        self.items = items
        self.nameRank = nameRank
    }

    /// Same entries (same names, same order) with updated metadata, reusing the name ranks.
    public func replacingItems(_ updated: [FileItem]) -> FolderContents {
        precondition(updated.count == items.count)
        return FolderContents(items: updated, nameRank: nameRank)
    }

    public static let empty = FolderContents(items: [])

    /// Applies a small change without re-ranking everything: removed names drop out, added
    /// items are binary-inserted into name order with the exact Finder comparator
    /// (O(n) + k·log n comparisons instead of an n·log n sort). A rename is remove + add.
    /// Used for the app's own operations now and for live file-system updates (M13).
    public func applying(removing removed: Set<String> = [], adding added: [FileItem] = [],
                         locale: Locale = .current) -> FolderContents {
        guard !removed.isEmpty || !added.isEmpty else { return self }
        // Current items in name order.
        var order = [Int](repeating: 0, count: items.count)
        for (i, r) in nameRank.enumerated() { order[Int(r)] = i }
        var sorted: [FileItem] = []
        sorted.reserveCapacity(items.count + added.count)
        for i in order where !removed.contains(items[i].name) { sorted.append(items[i]) }
        let addedNames = Set(added.map(\.name))
        if !addedNames.isEmpty { sorted.removeAll { addedNames.contains($0.name) } } // replace, don't duplicate
        for item in added {
            var lo = 0, hi = sorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if NameCollation.compare(sorted[mid].name, item.name, locale: locale) == .orderedDescending { hi = mid } else { lo = mid + 1 }
            }
            sorted.insert(item, at: lo)
        }
        return FolderContents(items: sorted, nameRank: (0..<UInt32(sorted.count)).map { $0 })
    }

    /// The item with this name, if present.
    public func item(named name: String) -> FileItem? { items.first { $0.name == name } }

    /// Items in display order.
    ///
    /// Explorer semantics: ascending puts folders first; descending reverses the
    /// whole list (so folders come last). Packages sort with files.
    /// `folderSizes` (by name): computed folder sizes (P1-6), used when sorting by size; folders without
    /// one sort as empty.
    public func ordered(by sort: FileSort, includeHidden: Bool, folderSizes: [String: Int64] = [:]) -> [FileItem] {
        let state = Signposts.sorting.beginInterval("Order", "\(items.count) items by \(sort.field.rawValue)")
        defer { Signposts.sorting.endInterval("Order", state) }

        // Key layout: (primary, tie) where tie = rank << 32 | index. Sorting 16-byte
        // integer pairs is ~10× faster than comparing FileItems in a closure.
        var folders: [SortKey] = []
        var files: [SortKey] = []
        folders.reserveCapacity(items.count / 8)
        files.reserveCapacity(items.count)
        let kindRank = sort.field == .kind ? Self.kindRanks(items) : sort.field == .fileExtension ? Self.extensionRanks(items) : []
        items.withUnsafeBufferPointer { items in
            for i in items.indices {
                let item = items[i]
                if !includeHidden && item.isHidden { continue }
                let primary: UInt64 = switch sort.field {
                case .name: 0
                case .dateModified: Self.sortable(item.modificationDate.timeIntervalSinceReferenceDate)
                case .dateCreated: Self.sortable(item.creationDate.timeIntervalSinceReferenceDate)
                case .size: UInt64(bitPattern: item.kind == .directory ? (folderSizes[item.name] ?? 0) : item.size) ^ (1 << 63)
                case .kind, .fileExtension: UInt64(kindRank[i])
                }
                let key = SortKey(primary: primary, tie: UInt64(nameRank[i]) << 32 | UInt64(i))
                if item.isFolder { folders.append(key) } else { files.append(key) }
            }
        }
        folders.sort()
        files.sort()

        var result: [FileItem] = []
        result.reserveCapacity(folders.count + files.count)
        for key in folders { result.append(items[Int(key.tie & 0xFFFF_FFFF)]) }
        for key in files { result.append(items[Int(key.tie & 0xFFFF_FFFF)]) }
        if !sort.ascending { result.reverse() }
        return result
    }

    /// Rank of each item's kind description in localized order. Few distinct kinds exist,
    /// so only those are collated; items map to them through a per-extension memo.
    static func kindRanks(_ items: [FileItem]) -> [UInt32] {
        var memo: [String: Int] = [:]       // memo key → index into `kinds`
        var kinds: [String] = []
        var kindIndex = [Int](repeating: 0, count: items.count)
        for (i, item) in items.enumerated() {
            let key: String = switch item.kind {
            case .directory: item.isPackage ? "/" + item.pathExtension : "/"
            case .symlink: "@"
            case .other: "?"
            case .file: item.flags.contains(.alias) ? "@" : item.pathExtension
            }
            if let k = memo[key] { kindIndex[i] = k; continue }
            let description = FileKind.description(for: item)
            let k = kinds.firstIndex(of: description) ?? { kinds.append(description); return kinds.count - 1 }()
            memo[key] = k
            kindIndex[i] = k
        }
        let order = NameCollation.ranks(of: kinds)
        return kindIndex.map { order[$0] }
    }

    /// Rank of each item's extension (`FileItem.displayExtension`) in localized order (so "JPG" and "jpg" sort
    /// together, case-insensitively); no extension sorts first. Only the distinct extensions are collated.
    static func extensionRanks(_ items: [FileItem]) -> [UInt32] {
        var memo: [String: Int] = [:]
        var extensions: [String] = []
        var index = [Int](repeating: 0, count: items.count)
        for (i, item) in items.enumerated() {
            let ext = item.displayExtension
            if let k = memo[ext] { index[i] = k; continue }
            memo[ext] = extensions.count
            index[i] = extensions.count
            extensions.append(ext)
        }
        let order = NameCollation.ranks(of: extensions)
        return index.map { order[$0] }
    }

    /// Maps a Double to a UInt64 with the same ordering (IEEE-754 trick).
    @inline(__always)
    static func sortable(_ d: Double) -> UInt64 {
        let bits = d.bitPattern
        return bits & (1 << 63) != 0 ? ~bits : bits | (1 << 63)
    }
}

struct SortKey: Comparable {
    var primary: UInt64
    var tie: UInt64

    @inline(__always)
    static func < (a: SortKey, b: SortKey) -> Bool {
        a.primary != b.primary ? a.primary < b.primary : a.tie < b.tie
    }
}
