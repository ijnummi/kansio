import Darwin
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// Directory listing via `getattrlistbulk(2)`.
///
/// One syscall returns many entries *with* their metadata (type, size, dates,
/// flags, inode) packed into a buffer, instead of `readdir` + one `stat`/`getattrlist`
/// per entry. This is the fastest public API for listing on APFS/HFS+/SMB.
public struct BulkDirectoryLister: DirectoryLister {
    /// Bytes per syscall. Each entry is ~150 bytes plus its name, so 128 KiB ≈ 700–900 entries.
    public var bufferSize: Int
    /// Used when the volume doesn't support `getattrlistbulk` (ENOTSUP).
    public var fallback: any DirectoryLister

    public init(bufferSize: Int = 128 * 1024, fallback: any DirectoryLister = FoundationDirectoryLister()) {
        precondition(bufferSize >= 1024, "buffer must hold at least one entry with a 255-byte name")
        self.bufferSize = bufferSize
        self.fallback = fallback
    }

    // attr.h values. Defined here because some don't import into Swift as `attrgroup_t` cleanly.
    private static let commonAttrs: attrgroup_t =
        0x8000_0000 /* ATTR_CMN_RETURNED_ATTRS */
        | 0x0000_0001 /* ATTR_CMN_NAME */
        | 0x2000_0000 /* ATTR_CMN_ERROR */
        | 0x0000_0008 /* ATTR_CMN_OBJTYPE */
        | 0x0000_0200 /* ATTR_CMN_CRTIME */
        | 0x0000_0400 /* ATTR_CMN_MODTIME */
        | 0x0000_4000 /* ATTR_CMN_FNDRINFO */
        | 0x0004_0000 /* ATTR_CMN_FLAGS */
        | 0x0200_0000 /* ATTR_CMN_FILEID */
    private static let fileAttrs: attrgroup_t = 0x0000_0002 /* ATTR_FILE_TOTALSIZE */

    public func list(_ directory: URL, onBatch: ([FileItem]) -> Bool) throws(FileSystemError) {
        let path = directory.path(percentEncoded: false)
        let state = Signposts.listing.beginInterval("getattrlistbulk", "\(path, privacy: .private)")
        defer { Signposts.listing.endInterval("getattrlistbulk", state) }

        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw FileSystemError(errno: errno, path: path) }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Self.commonAttrs
        request.fileattr = Self.fileAttrs

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var first = true
        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count < 0 {
                let err = errno
                if err == EINTR { continue }
                if first && (err == ENOTSUP || err == EINVAL) {
                    // Some third-party/FUSE file systems don't implement it.
                    try fallback.list(directory, onBatch: onBatch)
                    return
                }
                throw FileSystemError(errno: err, path: path)
            }
            first = false
            if count == 0 { return }

            var items: [FileItem] = []
            items.reserveCapacity(Int(count))
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                if let item = Self.parseEntry(entry) { items.append(item) }
                entry += length
            }
            if !onBatch(items) { return }
        }
    }

    /// Parses one packed entry. Layout (only attributes present in `returned` appear,
    /// in this order): length, returned attrs, error, name ref, objtype, crtime,
    /// modtime, finderinfo, flags, fileid, then file attrs (totalsize).
    private static func parseEntry(_ entry: UnsafeRawPointer) -> FileItem? {
        var field = entry + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr

        var flags: FileItem.Flags = []
        if common & 0x2000_0000 != 0 { // ERROR
            if field.loadUnaligned(as: UInt32.self) != 0 { flags.insert(.hadError) }
            field += MemoryLayout<UInt32>.size
        }

        guard common & 0x0000_0001 != 0 else { return nil } // NAME (always requested; never absent in practice)
        let nameRef = field.loadUnaligned(as: attrreference_t.self)
        let nameStart = field + Int(nameRef.attr_dataoffset)
        let nameLength = max(0, Int(nameRef.attr_length) - 1) // length includes the NUL
        let name = String(decoding: UnsafeRawBufferPointer(start: nameStart, count: nameLength), as: UTF8.self)
        field += MemoryLayout<attrreference_t>.size

        var kind: FileItem.Kind = .other
        if common & 0x0000_0008 != 0 { // OBJTYPE (enum vtype)
            kind = switch field.loadUnaligned(as: UInt32.self) {
            case 1: .file       // VREG
            case 2: .directory  // VDIR
            case 5: .symlink    // VLNK
            default: .other
            }
            field += MemoryLayout<fsobj_type_t>.size
        }

        var creation = Date.distantPast
        if common & 0x0000_0200 != 0 {
            creation = date(field.loadUnaligned(as: timespec.self))
            field += MemoryLayout<timespec>.size
        }
        var modification = Date.distantPast
        if common & 0x0000_0400 != 0 {
            modification = date(field.loadUnaligned(as: timespec.self))
            field += MemoryLayout<timespec>.size
        }

        if common & 0x0000_4000 != 0 { // FNDRINFO: 32 bytes, big-endian. finderFlags at offset 8 for files and folders.
            let finderFlags = UInt16(bigEndian: (field + 8).loadUnaligned(as: UInt16.self))
            if finderFlags & 0x8000 != 0 { flags.insert(.alias) }       // kIsAlias
            if finderFlags & 0x2000 != 0, kind == .directory { flags.insert(.package) } // kHasBundle
            field += 32
        }

        if common & 0x0004_0000 != 0 { // FLAGS (st_flags)
            let stFlags = field.loadUnaligned(as: UInt32.self)
            if stFlags & UInt32(UF_HIDDEN) != 0 { flags.insert(.hidden) }
            if stFlags & UInt32(SF_DATALESS) != 0 { flags.insert(.dataless) }
            field += MemoryLayout<UInt32>.size
        }

        var fileID: UInt64 = 0
        if common & 0x0200_0000 != 0 {
            fileID = field.loadUnaligned(as: UInt64.self)
            field += MemoryLayout<UInt64>.size
        }

        var size: Int64 = 0
        if returned.fileattr & 0x0000_0002 != 0 { // TOTALSIZE (non-directories)
            // Symlinks report the length of their target path; only regular files show a size.
            if kind == .file { size = field.loadUnaligned(as: off_t.self) }
            field += MemoryLayout<off_t>.size
        }

        if name.utf8.first == UInt8(ascii: ".") { flags.insert(.hidden) }
        if kind == .directory, !flags.contains(.package), PackageExtensions.isPackage(name: name) {
            flags.insert(.package)
        }

        return FileItem(
            name: name, kind: kind, flags: flags, size: size,
            modificationDate: modification, creationDate: creation, fileID: fileID
        )
    }

    @inline(__always)
    private static func date(_ ts: timespec) -> Date {
        Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000)
    }
}

/// Decides whether a directory extension denotes a package (`.app`, `.bundle`, `.photoslibrary`, …)
/// using the system type database. Cached per extension: there are few distinct ones.
enum PackageExtensions {
    private static let cache = Mutex<[String: Bool]>([:])

    static func isPackage(name: String) -> Bool {
        guard let dot = name.utf8.lastIndex(of: UInt8(ascii: ".")), dot != name.utf8.startIndex else { return false }
        let ext = String(name[name.index(after: dot)...]).lowercased()
        guard !ext.isEmpty else { return false }
        if let cached = cache.withLock({ $0[ext] }) { return cached }
        let result = UTType(filenameExtension: ext, conformingTo: .directory)?.conforms(to: .package) ?? false
        cache.withLock { $0[ext] = result }
        return result
    }
}
