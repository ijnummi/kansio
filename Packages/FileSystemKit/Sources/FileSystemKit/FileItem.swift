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
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

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
        /// Finder's kHasCustomIcon: the item has its own icon (needs a per-file icon lookup).
        public static let customIcon = Flags(rawValue: 1 << 5)
        /// Symlink whose target is a folder (set after resolution; see `SymlinkResolver`).
        public static let linkToFolder = Flags(rawValue: 1 << 6)
        /// Symlink whose target is a package (opens like one).
        public static let linkToPackage = Flags(rawValue: 1 << 7)
        /// Symlink whose target doesn't exist or can't be reached (includes loops).
        public static let brokenLink = Flags(rawValue: 1 << 8)
        /// Symlink whose target is a file (so "classified" is distinguishable from "not yet").
        public static let linkToFile = Flags(rawValue: 1 << 9)
        /// All symlink-classification flags.
        public static let linkTarget: Flags = [.linkToFolder, .linkToPackage, .brokenLink, .linkToFile]
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

    /// True for items the user navigates *into*: real folders and symlinks to folders
    /// (packages open as items instead). Folders sort before files.
    public var isFolder: Bool {
        switch kind {
        case .directory: !flags.contains(.package)
        case .symlink: flags.contains(.linkToFolder)
        default: false
        }
    }

    /// Lowercased extension after the last ".", or "" (a leading dot is not an extension).
    public var pathExtension: String {
        guard let dot = name.utf8.lastIndex(of: UInt8(ascii: ".")), dot != name.utf8.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }
}
