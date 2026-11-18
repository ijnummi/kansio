import Darwin
import Foundation

// P2-3: Compress and Extract. The model shared by both engines (7-Zip's `7zz`, macOS's libarchive).

/// What Compress writes.
public enum ArchiveFormat: String, Sendable, CaseIterable {
    case sevenZip = "7z"
    case zip

    public var fileExtension: String { rawValue }
    public var title: String { self == .sevenZip ? "7z" : "zip" }
}

/// Compression level (Settings ▸ Archives).
public enum ArchiveLevel: String, Sendable, CaseIterable {
    case fast, normal, maximum

    /// 7-Zip's `-mx` (and libarchive's compression-level).
    public var number: Int {
        switch self {
        case .fast: 1
        case .normal: 5
        case .maximum: 9
        }
    }
}

/// One item in an archive's listing.
public struct ArchiveEntry: Sendable, Equatable {
    /// Relative path, "/"-separated, no leading "./" or "/", no trailing "/".
    public var path: String
    public var isFolder: Bool
    public var isSymlink: Bool
    /// Uncompressed size (regular files).
    public var size: Int64
    public var isEncrypted: Bool
    /// When the entry was last modified, if the archive says (browsing shows it, P3-5).
    public var modified: Date?

    public init(path: String, isFolder: Bool, isSymlink: Bool = false, size: Int64 = 0, isEncrypted: Bool = false, modified: Date? = nil) {
        self.path = ArchiveEntry.clean(path)
        self.isFolder = isFolder
        self.isSymlink = isSymlink
        self.size = size
        self.isEncrypted = isEncrypted
        self.modified = modified
    }

    static func clean(_ path: String) -> String {
        var p = Substring(path)
        while p.hasPrefix("./") { p = p.dropFirst(2) }
        while p.hasPrefix("/") { p = p.dropFirst() }
        while p.hasSuffix("/") { p = p.dropLast() }
        return String(p)
    }

    var components: [Substring] { path.split(separator: "/") }
}

/// Recognizing archives and naming what comes out of them.
public enum ArchiveNames {
    /// Compound extensions first (longest match wins).
    static let extensions = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst", "tar.lz", "tar.lzma",
                             "7z", "zip", "rar", "tar", "tgz", "tbz", "tbz2", "txz", "tzst", "cab", "iso", "xar", "cpio"]
    /// Formats whose listing needs the whole archive decompressed (no quick look while a menu opens).
    static let streamed: Set<String> = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst", "tar.lz", "tar.lzma", "tar", "tgz", "tbz", "tbz2", "txz", "tzst", "cpio"]

    /// The archive extension of `name` ("tar.gz", "7z"…), nil if it isn't an archive we extract.
    public static func archiveExtension(_ name: String) -> String? {
        let lower = name.lowercased()
        for ext in extensions where lower.hasSuffix("." + ext) && lower.count > ext.count + 1 { return ext }
        return nil
    }

    public static func isArchive(_ name: String) -> Bool { archiveExtension(name) != nil }

    /// True for tar-like formats: their listing can't be read quickly.
    public static func isStreamed(_ name: String) -> Bool { archiveExtension(name).map(streamed.contains) ?? false }

    /// "Photos.tar.gz" → "Photos": the folder name for "Extract as".
    public static func baseName(_ name: String) -> String {
        guard let ext = archiveExtension(name) else { return name }
        let base = String(name.dropLast(ext.count + 1))
        return base.isEmpty ? name : base
    }

    /// The archive name for compressing `items` (all in one folder): one folder "Photos" → "Photos", one file
    /// "report.pdf" → "report", several → the parent folder's name (7-Zip's "Add to “Folder.7z”").
    public static func suggestedBase(for items: [URL], isFolder: (URL) -> Bool) -> String {
        if items.count == 1, let item = items.first {
            let name = item.lastPathComponent
            if isFolder(item) || name.hasPrefix(".") && (name as NSString).deletingPathExtension.isEmpty { return name }
            let base = (name as NSString).deletingPathExtension
            return base.isEmpty ? name : base
        }
        let parent = items.first?.deletingLastPathComponent().lastPathComponent ?? ""
        return parent.isEmpty || parent == "/" ? "Archive" : parent
    }

    /// `base.ext`, or "base (2).ext"… — the first name not taken in `folder`.
    public static func freeName(_ base: String, extension ext: String?, in folder: String) -> String {
        for n in 1...10_000 {
            let numbered = n == 1 ? base : "\(base) (\(n))"
            let candidate = ext.map { "\(numbered).\($0)" } ?? numbered
            var st = stat()
            if lstat((folder as NSString).appendingPathComponent(candidate), &st) != 0 { return candidate }
        }
        let fallback = "\(base) \(UUID().uuidString)"
        return ext.map { "\(fallback).\($0)" } ?? fallback
    }
}

/// What an archive's listing says about its layout.
public struct ArchiveLayout: Sendable, Equatable {
    /// Distinct first path components.
    public var topLevel: [String]
    /// The archive holds exactly one top-level item and it's a folder.
    public var singleTopFolder: String?
    /// All files (and symlinks) sit in one folder ("" = the top level); nil if they're spread over several.
    /// Empty folders are ignored.
    public var filesFolder: String?
    public var fileCount: Int
    public var totalBytes: Int64
    public var isEncrypted: Bool

    public init(_ entries: [ArchiveEntry]) {
        var top: [String] = []
        var seen = Set<String>()
        var folders = Set<String>()
        var fileParents = Set<String>()
        var files = 0
        var bytes: Int64 = 0
        var encrypted = false
        for entry in entries where !entry.path.isEmpty {
            let parts = entry.components
            guard let first = parts.first else { continue }
            if seen.insert(String(first)).inserted { top.append(String(first)) }
            if entry.isEncrypted { encrypted = true }
            // Every ancestor is a folder (archives may omit the folder entries themselves).
            for depth in 1..<max(parts.count, 1) { folders.insert(parts.prefix(depth).joined(separator: "/")) }
            if entry.isFolder {
                folders.insert(entry.path)
            } else {
                files += 1
                bytes += entry.size
                fileParents.insert(parts.dropLast().joined(separator: "/"))
            }
        }
        topLevel = top
        singleTopFolder = top.count == 1 && folders.contains(top[0]) ? top[0] : nil
        filesFolder = fileParents.count == 1 ? fileParents.first : (fileParents.isEmpty ? "" : nil)
        fileCount = files
        totalBytes = bytes
        isEncrypted = encrypted
    }
}

/// Errors specific to archives.
public enum ArchiveError {
    public static func encrypted(_ path: String) -> FileSystemError {
        FileSystemError(.other("Password-protected archives aren’t supported yet"), path: path)
    }
    public static func unreadable(_ path: String, _ detail: String) -> FileSystemError {
        FileSystemError(.other(detail.isEmpty ? "Can’t open this archive" : "Can’t open this archive: \(detail)"), path: path)
    }
    public static func notFlat(_ path: String) -> FileSystemError {
        FileSystemError(.other("Its files are in more than one folder, so it can’t be extracted flat"), path: path)
    }
    public static func verifyFailed(_ path: String, _ detail: String) -> FileSystemError {
        FileSystemError(.other("The archive didn’t match the originals (\(detail)), so the originals were kept"), path: path)
    }
}

/// Creates, lists and extracts archives. Blocking: the operations run it off the main thread.
public protocol ArchiveEngine: Sendable {
    var name: String { get }
    /// The archive's entries. Throws for unreadable or unsupported archives.
    func list(_ archive: URL, cancel: CancellationFlag) throws(FileSystemError) -> [ArchiveEntry]
    /// Writes `items` (names in `base`) into a new archive at `archive` (which must not exist).
    /// `progress` gets 0…1. Symlinks are stored as links; extended attributes aren't stored (portable archives).
    func create(_ archive: URL, base: URL, items: [String], format: ArchiveFormat, level: ArchiveLevel,
                cancel: CancellationFlag, progress: @escaping @Sendable (Double) -> Void) throws(FileSystemError)
    /// Extracts everything into the empty folder `folder`. Never writes outside it.
    func extract(_ archive: URL, into folder: URL, cancel: CancellationFlag,
                 progress: @escaping @Sendable (Double) -> Void) throws(FileSystemError)
    /// Extracts only the entries at `paths` (archive-relative; a folder with everything in it) into the empty folder
    /// `folder`, at their paths inside the archive (P3-5: opening or copying items out of a browsed archive).
    func extract(_ archive: URL, only paths: [String], into folder: URL, cancel: CancellationFlag,
                 progress: @escaping @Sendable (Double) -> Void) throws(FileSystemError)
}

extension ArchiveEngine {
    public func extract(_ archive: URL, only paths: [String], into folder: URL, cancel: CancellationFlag,
                        progress: @escaping @Sendable (Double) -> Void) throws(FileSystemError) {
        throw ArchiveError.unreadable(archive.path(percentEncoded: false), "\(name) can’t extract single items")
    }
}

/// Thrown by the engines when the operation was cancelled.
public let archiveCancelled = FileSystemError(.posix(ECANCELED), path: "")

/// What's on disk under `base` for `items`: relative paths of files/links (with sizes) and folders — the "originals"
/// that Compress into checks the archive against.
enum ArchiveSource {
    struct Tree: Sendable {
        var files: [String: Int64] = [:] // NFC path → size (symlinks: 0, skipped in size checks)
        var symlinks = Set<String>()
        var folders = Set<String>()
        var items: Int { files.count + folders.count }
        var bytes: Int64 { files.values.reduce(0, +) }
    }

    static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping }

    static func scan(base: URL, items: [String], cancel: CancellationFlag) -> Tree {
        var tree = Tree()
        let basePath = base.path(percentEncoded: false)
        // A work list, not recursion: deep trees must not overflow the worker thread's stack.
        var pending = Array(items.reversed())
        while let rel = pending.popLast(), !cancel.isCancelled {
            let full = (basePath as NSString).appendingPathComponent(rel)
            var st = stat()
            guard lstat(full, &st) == 0 else { continue }
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                tree.folders.insert(key(rel))
                let children = (try? FileManager.default.contentsOfDirectory(atPath: full)) ?? []
                pending += children.reversed().map { rel + "/" + $0 }
            case S_IFLNK:
                tree.files[key(rel)] = 0
                tree.symlinks.insert(key(rel))
            default:
                tree.files[key(rel)] = Int64(st.st_size)
            }
        }
        return tree
    }

    /// Nil if the archive's entries hold every file (same size) and folder in `tree`; else what's wrong.
    static func mismatch(_ tree: Tree, _ entries: [ArchiveEntry]) -> String? {
        var files: [String: Int64] = [:]
        var folders = Set<String>()
        for entry in entries {
            let k = key(entry.path)
            if entry.isFolder { folders.insert(k) } else { files[k] = entry.size }
            let parts = entry.components
            for depth in 1..<max(parts.count, 1) { folders.insert(key(parts.prefix(depth).joined(separator: "/"))) }
        }
        for (path, size) in tree.files {
            guard let archived = files[path] else { return "“\(path)” is missing" }
            if !tree.symlinks.contains(path) && archived != size { return "“\(path)” has a different size" }
        }
        for folder in tree.folders where !folders.contains(folder) { return "folder “\(folder)” is missing" }
        return nil
    }
}
