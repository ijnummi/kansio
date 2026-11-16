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
/// Building it costs one localized name sort (parallel; the expensive part).
/// After that, `ordered(by:)` for *any* column is plain integer/float comparison,
/// with the name rank as tie-breaker, so re-sorting never touches strings.
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

        var indices: [UInt32] = []
        indices.reserveCapacity(items.count)
        for i in items.indices where includeHidden || !items[i].isHidden { indices.append(UInt32(i)) }

        items.withUnsafeBufferPointer { items in
            nameRank.withUnsafeBufferPointer { rank in
                @inline(__always) func group(_ i: Int) -> Int { items[i].isFolder ? 0 : 1 }
                switch sort.field {
                case .name:
                    indices.sort { x, y in
                        let gx = group(Int(x)), gy = group(Int(y))
                        return gx != gy ? gx < gy : rank[Int(x)] < rank[Int(y)]
                    }
                case .dateModified:
                    indices.sort { x, y in
                        let gx = group(Int(x)), gy = group(Int(y))
                        if gx != gy { return gx < gy }
                        let dx = items[Int(x)].modificationDate, dy = items[Int(y)].modificationDate
                        return dx != dy ? dx < dy : rank[Int(x)] < rank[Int(y)]
                    }
                case .dateCreated:
                    indices.sort { x, y in
                        let gx = group(Int(x)), gy = group(Int(y))
                        if gx != gy { return gx < gy }
                        let dx = items[Int(x)].creationDate, dy = items[Int(y)].creationDate
                        return dx != dy ? dx < dy : rank[Int(x)] < rank[Int(y)]
                    }
                case .size:
                    indices.sort { x, y in
                        let gx = group(Int(x)), gy = group(Int(y))
                        if gx != gy { return gx < gy }
                        let sx = items[Int(x)].size, sy = items[Int(y)].size
                        return sx != sy ? sx < sy : rank[Int(x)] < rank[Int(y)]
                    }
                }
            }
        }
        if !sort.ascending { indices.reverse() }
        return indices.map { items[Int($0)] }
    }
}
