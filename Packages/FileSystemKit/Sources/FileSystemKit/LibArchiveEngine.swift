import Darwin
import Foundation

/// The archive engine that uses macOS's own libarchive (`/usr/lib/libarchive.2.dylib`, the library behind `tar`).
/// No dependency: the SDK has no headers for it, so the few functions used are looked up at run time (`dlsym`).
/// Single-threaded compression; reads zip, 7z, tar (+gz/bz2/xz/zstd), RAR, cpio, ISO…; can't open encrypted 7z.
///
/// Extraction is in-process with libarchive's safety checks: no ".." components, no absolute paths, and never
/// through a symlink (`ARCHIVE_EXTRACT_SECURE_*`); only data, folders, symlinks, times and permissions are written.
public struct LibArchiveEngine: ArchiveEngine {
    public var name: String { "libarchive" }
    public init() {}

    /// Whether the system library and every function used were found.
    public static var isAvailable: Bool { LA.shared != nil }

    public func list(_ archive: URL, cancel: CancellationFlag) throws(FileSystemError) -> [ArchiveEntry] {
        let path = archive.path(percentEncoded: false)
        guard let la = LA.shared else { throw ArchiveError.unreadable(path, "the system’s libarchive isn’t available") }
        let reader = try openReader(la, path)
        defer { _ = la.read_free(reader) }
        var entries: [ArchiveEntry] = []
        var entry: OpaquePointer?
        while true {
            if cancel.isCancelled { throw archiveCancelled }
            let rc = la.read_next_header(reader, &entry)
            if rc == ARCHIVE_EOF { break }
            if rc < ARCHIVE_WARN { throw readError(la, reader, path) }
            guard let entry else { break }
            entries.append(Self.entry(la, entry))
            _ = la.read_data_skip(reader)
        }
        return entries
    }

    public func extract(_ archive: URL, into folder: URL, cancel: CancellationFlag,
                        progress: @escaping @Sendable (Double) -> Void) throws(FileSystemError) {
        try extract(archive, selection: nil, into: folder, cancel: cancel, progress: progress)
    }

    public func extract(_ archive: URL, only paths: [String], into folder: URL, cancel: CancellationFlag,
                        progress: @escaping @Sendable (Double) -> Void) throws(FileSystemError) {
        guard !paths.isEmpty else { return }
        try extract(archive, selection: Set(paths.map(ArchiveEntry.clean)), into: folder, cancel: cancel, progress: progress)
    }

    /// An entry is selected when its path, or a folder it's in, is in `selection`.
    static func isSelected(_ relative: String, _ selection: Set<String>) -> Bool {
        var path = Substring(relative)
        while true {
            if selection.contains(String(path)) { return true }
            guard let slash = path.lastIndex(of: "/") else { return false }
            path = path[..<slash]
        }
    }

    private func extract(_ archive: URL, selection: Set<String>?, into folder: URL, cancel: CancellationFlag,
                         progress: @escaping @Sendable (Double) -> Void) throws(FileSystemError) {
        let path = archive.path(percentEncoded: false)
        guard let la = LA.shared else { throw ArchiveError.unreadable(path, "the system’s libarchive isn’t available") }
        var st = stat()
        let archiveSize = stat(path, &st) == 0 ? max(Int64(st.st_size), 1) : 1
        let reader = try openReader(la, path)
        defer { _ = la.read_free(reader) }
        guard let writer = la.write_disk_new() else { throw ArchiveError.unreadable(path, "out of memory") }
        defer { _ = la.write_free(writer) }
        _ = la.write_disk_set_options(writer, Self.extractFlags)
        // The real path: SECURE_SYMLINKS refuses any symlink on the way (e.g. /var → /private/var).
        var root = folder.path(percentEncoded: false)
        if let real = realpath(root, nil) { root = String(cString: real); free(real) }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var entry: OpaquePointer?
        var lastReport = 0.0
        while true {
            if cancel.isCancelled { throw archiveCancelled }
            let rc = la.read_next_header(reader, &entry)
            if rc == ARCHIVE_EOF { break }
            if rc < ARCHIVE_WARN { throw readError(la, reader, path) }
            guard let entry else { break }
            if la.entry_is_encrypted(entry) != 0 { throw ArchiveError.encrypted(path) }
            // Write under `folder`: the entry's path made relative and checked (the secure flags check again).
            let name = la.entry_pathname_utf8(entry).map { String(cString: $0) } ?? ""
            guard let relative = Self.safeRelative(name) else { _ = la.read_data_skip(reader); continue }
            if let selection, !Self.isSelected(ArchiveEntry.clean(relative), selection) { _ = la.read_data_skip(reader); continue }
            _ = la.entry_update_pathname_utf8(entry, prefix + relative)
            if let link = la.entry_hardlink_utf8(entry).map({ String(cString: $0) }) {
                guard let target = Self.safeRelative(link) else { _ = la.read_data_skip(reader); continue }
                _ = la.entry_update_hardlink_utf8(entry, prefix + target)
            }
            let written = la.read_extract2(reader, entry, writer)
            if written != ARCHIVE_OK {
                if la.entry_is_encrypted(entry) != 0 { throw ArchiveError.encrypted(path) }
                throw readError(la, reader, path, fallback: la.error_string(writer).map { String(cString: $0) })
            }
            let fraction = Double(la.filter_bytes(reader, -1)) / Double(archiveSize)
            if fraction - lastReport >= 0.01 { lastReport = fraction; progress(min(fraction, 1)) }
        }
        progress(1)
    }

    public func create(_ archive: URL, base: URL, items: [String], format: ArchiveFormat, level: ArchiveLevel,
                       cancel: CancellationFlag, progress: @escaping @Sendable (Double) -> Void) throws(FileSystemError) {
        let path = archive.path(percentEncoded: false)
        guard let la = LA.shared, let writer = la.write_new() else {
            throw ArchiveError.unreadable(path, "the system’s libarchive isn’t available")
        }
        defer { _ = la.write_free(writer) }
        switch format {
        case .sevenZip:
            _ = la.write_set_format_7zip(writer)
            _ = la.write_set_options(writer, "compression=lzma2,compression-level=\(level.number)")
        case .zip:
            _ = la.write_set_format_zip(writer)
            _ = la.write_set_options(writer, "compression-level=\(level.number),hdrcharset=UTF-8")
        }
        guard la.write_open_filename(writer, path) == ARCHIVE_OK else {
            throw FileSystemError(.other(la.error_string(writer).map { String(cString: $0) } ?? "Can’t create the archive"), path: path)
        }
        let basePath = base.path(percentEncoded: false)
        let total = max(ArchiveSource.scan(base: base, items: items, cancel: cancel).bytes, 1)
        var done: Int64 = 0
        var lastReport = 0.0
        var buffer = [UInt8](repeating: 0, count: 1 << 20)

        /// Writes one entry; a folder returns its children (added next, in order — a work list rather than recursion,
        /// so a deep tree can't overflow the worker thread's stack).
        func add(_ relative: String) throws(FileSystemError) -> [String] {
            if cancel.isCancelled { throw archiveCancelled }
            let full = (basePath as NSString).appendingPathComponent(relative)
            var st = stat()
            guard lstat(full, &st) == 0 else { throw FileSystemError(errno: errno, path: full) }
            guard let entry = la.entry_new() else { throw FileSystemError(errno: ENOMEM, path: full) }
            defer { la.entry_free(entry) }
            let type = st.st_mode & S_IFMT
            la.entry_set_pathname_utf8(entry, relative)
            la.entry_set_perm(entry, st.st_mode & 0o7777)
            la.entry_set_mtime(entry, st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec)
            switch type {
            case S_IFDIR:
                la.entry_set_filetype(entry, UInt32(S_IFDIR))
                la.entry_set_size(entry, 0)
                try check(la.write_header(writer, entry), full)
                let children = ((try? FileManager.default.contentsOfDirectory(atPath: full)) ?? []).sorted()
                return children.map { relative + "/" + $0 }
            case S_IFLNK:
                var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = readlink(full, &target, Int(PATH_MAX))
                guard n >= 0 else { throw FileSystemError(errno: errno, path: full) }
                la.entry_set_filetype(entry, UInt32(S_IFLNK))
                la.entry_set_size(entry, 0)
                la.entry_set_symlink_utf8(entry, String(decoding: target.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self))
                try check(la.write_header(writer, entry), full)
            case S_IFREG:
                la.entry_set_filetype(entry, UInt32(S_IFREG))
                la.entry_set_size(entry, Int64(st.st_size))
                try check(la.write_header(writer, entry), full)
                let fd = open(full, O_RDONLY | O_NOFOLLOW)
                guard fd >= 0 else { throw FileSystemError(errno: errno, path: full) }
                defer { close(fd) }
                while true {
                    if cancel.isCancelled { throw archiveCancelled }
                    let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    if n < 0 { throw FileSystemError(errno: errno, path: full) }
                    if n == 0 { break }
                    let w = buffer.withUnsafeBytes { la.write_data(writer, $0.baseAddress, n) }
                    if w < 0 { throw FileSystemError(.other(la.error_string(writer).map { String(cString: $0) } ?? "Write failed"), path: path) }
                    done += Int64(n)
                    let fraction = Double(done) / Double(total)
                    if fraction - lastReport >= 0.01 { lastReport = fraction; progress(min(fraction, 0.99)) }
                }
            default:
                break // sockets, devices, FIFOs: not archived
            }
            return []
        }
        func check(_ rc: Int32, _ file: String) throws(FileSystemError) {
            if rc < ARCHIVE_WARN {
                throw FileSystemError(.other(la.error_string(writer).map { String(cString: $0) } ?? "Can’t add it"), path: file)
            }
        }
        var pending = Array(items.reversed()) // depth first, each folder before its contents
        while let next = pending.popLast() { pending += try add(next).reversed() }
        guard la.write_close(writer) == ARCHIVE_OK else {
            throw FileSystemError(.other(la.error_string(writer).map { String(cString: $0) } ?? "Can’t finish the archive"), path: path)
        }
        progress(1)
    }

    // MARK: Helpers

    /// TIME | PERM | SECURE_SYMLINKS | SECURE_NODOTDOT (absolute paths are ours: the destination prefix).
    static let extractFlags: Int32 = 0x0004 | 0x0002 | 0x0100 | 0x0200

    /// The entry path made relative; nil if it's empty or climbs out ("..").
    static func safeRelative(_ name: String) -> String? {
        let clean = ArchiveEntry.clean(name)
        let parts = clean.split(separator: "/")
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts.filter { $0 != "." }.joined(separator: "/")
    }

    private func openReader(_ la: LA, _ path: String) throws(FileSystemError) -> OpaquePointer {
        guard let reader = la.read_new() else { throw ArchiveError.unreadable(path, "out of memory") }
        _ = la.read_support_filter_all(reader)
        _ = la.read_support_format_all(reader)
        if la.read_open_filename(reader, path, 1 << 16) != ARCHIVE_OK {
            let error = readError(la, reader, path)
            _ = la.read_free(reader)
            throw error
        }
        return reader
    }

    private func readError(_ la: LA, _ reader: OpaquePointer, _ path: String, fallback: String? = nil) -> FileSystemError {
        let message = la.error_string(reader).map { String(cString: $0) } ?? fallback ?? ""
        if message.localizedCaseInsensitiveContains("encrypt") || message.localizedCaseInsensitiveContains("passphrase") {
            return ArchiveError.encrypted(path)
        }
        let code = la.errno_(reader)
        if code == ENOENT || code == EACCES || code == EPERM || code == ENOSPC { return FileSystemError(errno: code, path: path) }
        return ArchiveError.unreadable(path, message)
    }

    private static func entry(_ la: LA, _ entry: OpaquePointer) -> ArchiveEntry {
        let name = la.entry_pathname_utf8(entry).map { String(cString: $0) } ?? ""
        let type = la.entry_filetype(entry)
        let modified: Date? = la.entry_mtime.flatMap { mtime in
            if let isSet = la.entry_mtime_is_set, isSet(entry) == 0 { return nil }
            return Date(timeIntervalSince1970: TimeInterval(mtime(entry)))
        }
        return ArchiveEntry(path: name, isFolder: type == S_IFDIR || name.hasSuffix("/"), isSymlink: type == S_IFLNK,
                            size: la.entry_size(entry), isEncrypted: la.entry_is_encrypted(entry) != 0, modified: modified)
    }
}

private let ARCHIVE_EOF: Int32 = 1
private let ARCHIVE_OK: Int32 = 0
private let ARCHIVE_WARN: Int32 = -20

/// libarchive's functions, looked up once.
private struct LA: @unchecked Sendable {
    typealias A = OpaquePointer
    typealias E = OpaquePointer
    let read_new: @convention(c) () -> A?
    let read_support_filter_all: @convention(c) (A) -> Int32
    let read_support_format_all: @convention(c) (A) -> Int32
    let read_open_filename: @convention(c) (A, UnsafePointer<CChar>, Int) -> Int32
    let read_next_header: @convention(c) (A, UnsafeMutablePointer<E?>) -> Int32
    let read_data_skip: @convention(c) (A) -> Int32
    let read_extract2: @convention(c) (A, E, A) -> Int32
    let read_free: @convention(c) (A) -> Int32
    let filter_bytes: @convention(c) (A, Int32) -> Int64
    let error_string: @convention(c) (A) -> UnsafePointer<CChar>?
    let errno_: @convention(c) (A) -> Int32
    let write_disk_new: @convention(c) () -> A?
    let write_disk_set_options: @convention(c) (A, Int32) -> Int32
    let write_new: @convention(c) () -> A?
    let write_set_format_7zip: @convention(c) (A) -> Int32
    let write_set_format_zip: @convention(c) (A) -> Int32
    let write_set_options: @convention(c) (A, UnsafePointer<CChar>) -> Int32
    let write_open_filename: @convention(c) (A, UnsafePointer<CChar>) -> Int32
    let write_header: @convention(c) (A, E) -> Int32
    let write_data: @convention(c) (A, UnsafeRawPointer?, Int) -> Int
    let write_close: @convention(c) (A) -> Int32
    let write_free: @convention(c) (A) -> Int32
    let entry_new: @convention(c) () -> E?
    let entry_free: @convention(c) (E) -> Void
    let entry_pathname_utf8: @convention(c) (E) -> UnsafePointer<CChar>?
    let entry_hardlink_utf8: @convention(c) (E) -> UnsafePointer<CChar>?
    let entry_update_pathname_utf8: @convention(c) (E, UnsafePointer<CChar>) -> Int32
    let entry_update_hardlink_utf8: @convention(c) (E, UnsafePointer<CChar>) -> Int32
    let entry_size: @convention(c) (E) -> Int64
    let entry_filetype: @convention(c) (E) -> mode_t
    let entry_is_encrypted: @convention(c) (E) -> Int32
    let entry_set_pathname_utf8: @convention(c) (E, UnsafePointer<CChar>) -> Void
    let entry_set_size: @convention(c) (E, Int64) -> Void
    let entry_set_filetype: @convention(c) (E, UInt32) -> Void
    let entry_set_perm: @convention(c) (E, mode_t) -> Void
    let entry_set_mtime: @convention(c) (E, Int, Int) -> Void
    let entry_set_symlink_utf8: @convention(c) (E, UnsafePointer<CChar>) -> Void
    /// Optional (dates when browsing an archive): looked up without failing the rest.
    var entry_mtime: (@convention(c) (E) -> Int)? = nil
    var entry_mtime_is_set: (@convention(c) (E) -> Int32)? = nil

    static let shared: LA? = {
        guard let handle = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else { return nil }
        func f<T>(_ name: String, _: T.Type = T.self) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let read_new = f("archive_read_new", (@convention(c) () -> A?).self),
              let read_support_filter_all = f("archive_read_support_filter_all", (@convention(c) (A) -> Int32).self),
              let read_support_format_all = f("archive_read_support_format_all", (@convention(c) (A) -> Int32).self),
              let read_open_filename = f("archive_read_open_filename", (@convention(c) (A, UnsafePointer<CChar>, Int) -> Int32).self),
              let read_next_header = f("archive_read_next_header", (@convention(c) (A, UnsafeMutablePointer<E?>) -> Int32).self),
              let read_data_skip = f("archive_read_data_skip", (@convention(c) (A) -> Int32).self),
              let read_extract2 = f("archive_read_extract2", (@convention(c) (A, E, A) -> Int32).self),
              let read_free = f("archive_read_free", (@convention(c) (A) -> Int32).self),
              let filter_bytes = f("archive_filter_bytes", (@convention(c) (A, Int32) -> Int64).self),
              let error_string = f("archive_error_string", (@convention(c) (A) -> UnsafePointer<CChar>?).self),
              let errno_ = f("archive_errno", (@convention(c) (A) -> Int32).self),
              let write_disk_new = f("archive_write_disk_new", (@convention(c) () -> A?).self),
              let write_disk_set_options = f("archive_write_disk_set_options", (@convention(c) (A, Int32) -> Int32).self),
              let write_new = f("archive_write_new", (@convention(c) () -> A?).self),
              let write_set_format_7zip = f("archive_write_set_format_7zip", (@convention(c) (A) -> Int32).self),
              let write_set_format_zip = f("archive_write_set_format_zip", (@convention(c) (A) -> Int32).self),
              let write_set_options = f("archive_write_set_options", (@convention(c) (A, UnsafePointer<CChar>) -> Int32).self),
              let write_open_filename = f("archive_write_open_filename", (@convention(c) (A, UnsafePointer<CChar>) -> Int32).self),
              let write_header = f("archive_write_header", (@convention(c) (A, E) -> Int32).self),
              let write_data = f("archive_write_data", (@convention(c) (A, UnsafeRawPointer?, Int) -> Int).self),
              let write_close = f("archive_write_close", (@convention(c) (A) -> Int32).self),
              let write_free = f("archive_write_free", (@convention(c) (A) -> Int32).self),
              let entry_new = f("archive_entry_new", (@convention(c) () -> E?).self),
              let entry_free = f("archive_entry_free", (@convention(c) (E) -> Void).self),
              let entry_pathname_utf8 = f("archive_entry_pathname_utf8", (@convention(c) (E) -> UnsafePointer<CChar>?).self),
              let entry_hardlink_utf8 = f("archive_entry_hardlink_utf8", (@convention(c) (E) -> UnsafePointer<CChar>?).self),
              let entry_update_pathname_utf8 = f("archive_entry_update_pathname_utf8", (@convention(c) (E, UnsafePointer<CChar>) -> Int32).self),
              let entry_update_hardlink_utf8 = f("archive_entry_update_hardlink_utf8", (@convention(c) (E, UnsafePointer<CChar>) -> Int32).self),
              let entry_size = f("archive_entry_size", (@convention(c) (E) -> Int64).self),
              let entry_filetype = f("archive_entry_filetype", (@convention(c) (E) -> mode_t).self),
              let entry_is_encrypted = f("archive_entry_is_encrypted", (@convention(c) (E) -> Int32).self),
              let entry_set_pathname_utf8 = f("archive_entry_set_pathname_utf8", (@convention(c) (E, UnsafePointer<CChar>) -> Void).self),
              let entry_set_size = f("archive_entry_set_size", (@convention(c) (E, Int64) -> Void).self),
              let entry_set_filetype = f("archive_entry_set_filetype", (@convention(c) (E, UInt32) -> Void).self),
              let entry_set_perm = f("archive_entry_set_perm", (@convention(c) (E, mode_t) -> Void).self),
              let entry_set_mtime = f("archive_entry_set_mtime", (@convention(c) (E, Int, Int) -> Void).self),
              let entry_set_symlink_utf8 = f("archive_entry_set_symlink_utf8", (@convention(c) (E, UnsafePointer<CChar>) -> Void).self)
        else { return nil }
        var la = LA(read_new: read_new, read_support_filter_all: read_support_filter_all, read_support_format_all: read_support_format_all,
                  read_open_filename: read_open_filename, read_next_header: read_next_header, read_data_skip: read_data_skip,
                  read_extract2: read_extract2, read_free: read_free, filter_bytes: filter_bytes, error_string: error_string,
                  errno_: errno_, write_disk_new: write_disk_new, write_disk_set_options: write_disk_set_options,
                  write_new: write_new, write_set_format_7zip: write_set_format_7zip, write_set_format_zip: write_set_format_zip,
                  write_set_options: write_set_options, write_open_filename: write_open_filename, write_header: write_header,
                  write_data: write_data, write_close: write_close, write_free: write_free, entry_new: entry_new,
                  entry_free: entry_free, entry_pathname_utf8: entry_pathname_utf8, entry_hardlink_utf8: entry_hardlink_utf8,
                  entry_update_pathname_utf8: entry_update_pathname_utf8, entry_update_hardlink_utf8: entry_update_hardlink_utf8,
                  entry_size: entry_size, entry_filetype: entry_filetype, entry_is_encrypted: entry_is_encrypted,
                  entry_set_pathname_utf8: entry_set_pathname_utf8, entry_set_size: entry_set_size,
                  entry_set_filetype: entry_set_filetype, entry_set_perm: entry_set_perm, entry_set_mtime: entry_set_mtime,
                  entry_set_symlink_utf8: entry_set_symlink_utf8)
        la.entry_mtime = f("archive_entry_mtime", (@convention(c) (E) -> Int).self)
        la.entry_mtime_is_set = f("archive_entry_mtime_is_set", (@convention(c) (E) -> Int32).self)
        return la
    }()
}
