import Foundation

/// One entry in a directory listing.
///
/// This is a plain value: everything here is read once, in bulk, during listing.
/// Nothing in the UI may ask the file system for more per row; if a column needs
/// data, it belongs in this struct (or in a separate lazily filled cache).
public struct FileItem: Sendable, Hashable {
    public enum Kind: UInt8, Sendable, Hashable {
        case file
        case directory
        case symlink
        /// FIFOs, sockets, devices.
        case other
    }

    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// Name starts with "." or the UF_HIDDEN flag is set (same rule as Finder / `URLResourceKey.isHiddenKey`).
        public static let hidden = Flags(rawValue: 1 << 0)
        /// A directory shown and opened as a single item (`.app`, `.photoslibrary`, …).
        public static let package = Flags(rawValue: 1 << 1)
        /// A Finder alias file (not a symlink; symlinks are `Kind.symlink`).
        public static let alias = Flags(rawValue: 1 << 2)
        /// Dataless (e.g. iCloud "optimized storage") file: contents are not local.
        /// Reading the contents triggers a download, so never do that just to display it.
        public static let dataless = Flags(rawValue: 1 << 3)
        /// The file system reported an error for this entry; other fields may be defaults.
        public static let hadError = Flags(rawValue: 1 << 4)
    }

    /// The name exactly as the file system returned it (normalization preserved).
    public var name: String
    public var kind: Kind
    public var flags: Flags
    /// Logical size in bytes (data + resource fork). 0 for directories.
    public var size: Int64
    public var modificationDate: Date
    public var creationDate: Date
    /// Inode number. Stable identity within a volume; used for diffing live updates.
    public var fileID: UInt64

    public init(
        name: String,
        kind: Kind,
        flags: Flags = [],
        size: Int64 = 0,
        modificationDate: Date = .distantPast,
        creationDate: Date = .distantPast,
        fileID: UInt64 = 0
    ) {
        self.name = name
        self.kind = kind
        self.flags = flags
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.fileID = fileID
    }

    public var isHidden: Bool { flags.contains(.hidden) }
    public var isPackage: Bool { flags.contains(.package) }

    /// True for directories the user navigates *into* (packages open as items instead).
    public var isFolder: Bool { kind == .directory && !flags.contains(.package) }
}
