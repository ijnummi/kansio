import Foundation

/// The single, global sort setting (Explorer-style: one setting for every folder).
public struct FileSort: Sendable, Hashable, Codable {
    public enum Field: String, Sendable, Hashable, Codable, CaseIterable {
        case name, dateModified, dateCreated, size
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

    public static let empty = FolderContents(items: [])

    /// Items in display order.
    ///
    /// Explorer semantics: ascending puts folders first; descending reverses the
    /// whole list (so folders come last). Packages sort with files.
    public func ordered(by sort: FileSort, includeHidden: Bool) -> [FileItem] {
        let state = Signposts.sorting.beginInterval("Order", "\(items.count) items by \(sort.field.rawValue)")
        defer { Signposts.sorting.endInterval("Order", state) }

        // Key layout: (primary, tie) where tie = rank << 32 | index. Sorting 16-byte
        // integer pairs is ~10× faster than comparing FileItems in a closure.
        var folders: [SortKey] = []
        var files: [SortKey] = []
        folders.reserveCapacity(items.count / 8)
        files.reserveCapacity(items.count)
        items.withUnsafeBufferPointer { items in
            for i in items.indices {
                let item = items[i]
                if !includeHidden && item.isHidden { continue }
                let primary: UInt64 = switch sort.field {
                case .name: 0
                case .dateModified: Self.sortable(item.modificationDate.timeIntervalSinceReferenceDate)
                case .dateCreated: Self.sortable(item.creationDate.timeIntervalSinceReferenceDate)
                case .size: UInt64(bitPattern: item.size) ^ (1 << 63)
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
