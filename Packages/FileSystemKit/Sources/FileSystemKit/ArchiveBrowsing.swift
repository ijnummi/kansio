import Darwin
import Foundation
import Synchronization

/// Browsing an archive as a read-only folder (P3-5). The locations inside it are ordinary paths that go *through*
/// the archive file — `/Users/me/Downloads/photos.zip/2024/June` — so history, Up, the address bar and the tree work
/// on them like on any folder; `OpenedArchives` says which paths are inside an archive that has been opened.

/// An archive's listing as folders: the items in each folder (folders the paths imply but the archive doesn't list
/// are added), as `FileItem`s for the list and the tree.
public struct ArchiveIndex: Sendable {
    /// The archive file's path as it was opened (normalized: no trailing slash).
    public let archivePath: String
    /// The archive file's size and date when it was read (a changed archive is read again).
    public let size: Int64
    public let modified: Date
    public let isEncrypted: Bool
    /// Inner folder path ("" = the archive's top level) → its items, in no particular order.
    private let folders: [String: [FileItem]]
    /// Inner path → the entry's path as the archive stores it (what the engines extract by).
    private let storedPaths: [String: String]

    public init(archivePath: String, entries: [ArchiveEntry], size: Int64, modified: Date) {
        self.archivePath = FolderTree.normalized(archivePath)
        self.size = size
        self.modified = modified
        var folders: [String: [String: FileItem]] = ["": [:]]
        var stored: [String: String] = [:]
        var encrypted = false
        func parent(_ path: String) -> (String, String) {
            guard let slash = path.lastIndex(of: "/") else { return ("", path) }
            return (String(path[..<slash]), String(path[path.index(after: slash)...]))
        }
        /// Adds `path` as a folder (and every folder above it) unless it's there already.
        func addFolder(_ path: String, date: Date?) {
            var path = path
            while !path.isEmpty {
                let (up, name) = parent(path)
                if folders[path] == nil { folders[path] = [:] }
                if folders[up]?[name] == nil {
                    folders[up, default: [:]][name] = FileItem(name: name, kind: .directory, flags: Self.flags(name), modificationDate: date ?? modified,
                                                               creationDate: date ?? modified, fileID: Self.id(path))
                } else if let date, folders[up]?[name]?.kind == .directory {
                    folders[up]?[name]?.modificationDate = date // an explicit entry's date wins over an implied one's
                    folders[up]?[name]?.creationDate = date
                }
                path = up
            }
        }
        for entry in entries where !entry.path.isEmpty && entry.path != "." {
            if entry.isEncrypted { encrypted = true }
            stored[entry.path] = entry.path
            if entry.isFolder {
                addFolder(entry.path, date: entry.modified)
                continue
            }
            let (up, name) = parent(entry.path)
            addFolder(up, date: nil)
            // A symlink inside an archive is shown (and opened) as a file: its target may be anywhere.
            folders[up, default: [:]][name] = FileItem(name: name, kind: .file, flags: Self.flags(name), size: entry.size,
                                                       modificationDate: entry.modified ?? modified, creationDate: entry.modified ?? modified,
                                                       fileID: Self.id(entry.path))
        }
        self.folders = folders.mapValues { Array($0.values) }
        storedPaths = stored
        isEncrypted = encrypted
    }

    private static func flags(_ name: String) -> FileItem.Flags { name.hasPrefix(".") ? [.hidden, .inArchive] : [.inArchive] }

    /// A stable identity for an inner path (FNV-1a), unlike any inode in practice (top bit set).
    static func id(_ path: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash | (1 << 63)
    }

    /// The items in folder `inner` ("" = the top level); nil if the archive has no such folder.
    public func items(in inner: String) -> [FileItem]? { folders[ArchiveEntry.clean(inner)] }

    /// Just the folders in `inner`, in Finder order (the tree).
    public func subfolders(in inner: String) -> [FileItem]? {
        guard let items = items(in: inner) else { return nil }
        let folders = items.filter { $0.kind == .directory }
        return NameCollation.sortedIndices(of: folders.map(\.name)).map { folders[Int($0)] }
    }

    public var folderCount: Int { folders.count - 1 }
    public var itemCount: Int { folders.values.reduce(0) { $0 + $1.count } }

    /// The archive path to extract for `name` in folder `inner`.
    public func storedPath(of name: String, in inner: String) -> String {
        let clean = ArchiveEntry.clean(inner)
        let path = clean.isEmpty ? name : clean + "/" + name
        return storedPaths[path] ?? path
    }

    /// Reads `archive` with the first engine that can (blocking).
    public static func readBlocking(_ archive: URL, engines: [any ArchiveEngine], cancel: CancellationFlag) throws(FileSystemError) -> ArchiveIndex {
        let path = archive.path(percentEncoded: false)
        var st = stat()
        guard stat(path, &st) == 0 else { throw FileSystemError(errno: errno, path: path) }
        guard st.st_mode & S_IFMT == S_IFREG else { throw ArchiveError.unreadable(path, "not a file") }
        let entries = try ArchiveOperations(engines: engines).listWithFallback(archive, cancel: cancel)
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        return ArchiveIndex(archivePath: path, entries: entries, size: Int64(st.st_size), modified: modified)
    }
}

/// The archives opened (browsed) in this run, by path: thread-safe, read by the list (main actor) and the folder
/// tree's listing queues. Only these are browsable as folders, and only these appear in the tree (as folders under
/// the folder they're in) — an archive nobody opened stays a file everywhere.
public final class OpenedArchives: Sendable {
    public static let shared = OpenedArchives()

    private struct State {
        /// Archive path (as opened, and its real path) → index.
        var byPath: [String: ArchiveIndex] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// Remembers `index` under its path and its real path (`/var/…` and `/private/var/…` both find it).
    public func register(_ index: ArchiveIndex) {
        let real = FolderTreeIO.realPath(index.archivePath).map(FolderTree.normalized)
        state.withLock { state in
            state.byPath[index.archivePath] = index
            if let real { state.byPath[real] = index }
        }
    }

    public func index(forArchive path: String) -> ArchiveIndex? {
        state.withLock { $0.byPath[FolderTree.normalized(path)] }
    }

    /// The opened archive `path` is in (or is), and the folder inside it ("" = its top level).
    public func location(of path: String) -> (index: ArchiveIndex, inner: String)? {
        let path = FolderTree.normalized(path)
        return state.withLock { state -> (ArchiveIndex, String)? in
            guard !state.byPath.isEmpty else { return nil }
            // Walk up from the path: the deepest archive wins (an archive opened from inside another is extracted
            // to a temporary folder first, so nesting doesn't happen in practice).
            var candidate = Substring(path)
            while !candidate.isEmpty {
                if let index = state.byPath[String(candidate)] {
                    let inner = path.count > candidate.count ? String(path.dropFirst(candidate.count + 1)) : ""
                    return (index, inner)
                }
                guard let slash = candidate.lastIndex(of: "/"), slash != candidate.startIndex else { break }
                candidate = candidate[..<slash]
            }
            return nil
        }
    }

    public func isInsideArchive(_ path: String) -> Bool { location(of: path) != nil }

    /// Opened archives directly in `folder` (names), for the tree.
    public func archiveNames(inFolder folder: String) -> Set<String> {
        let folder = FolderTree.normalized(folder)
        let prefix = folder == "/" ? "/" : folder + "/"
        return state.withLock { state in
            Set(state.byPath.keys.filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }.map { String($0.dropFirst(prefix.count)) })
        }
    }

    /// Forgets `archivePath` (it changed on disk or went away).
    public func forget(_ archivePath: String) {
        let path = FolderTree.normalized(archivePath)
        state.withLock { state in
            guard let index = state.byPath[path] else { return }
            state.byPath = state.byPath.filter { $0.value.archivePath != index.archivePath }
        }
    }

    public func removeAll() { state.withLock { $0.byPath = [:] } }
}

extension ArchiveOperations {
    /// Copies items out of a browsed archive (P3-5): the entries at `paths` (archive-relative) are extracted into a
    /// temporary folder in `destination`, then each is moved into place under its own name — conflicts asked by the
    /// resolver, never overwriting; nothing half-extracted is left behind.
    public func extractItems(from archive: URL, paths: [String], into destination: URL,
                             progress: @escaping @Sendable (OperationProgress) -> Void = { _ in }) async -> ExtractResult {
        let flag = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                FileOperationQueue.queue.async {
                    continuation.resume(returning: self.extractItemsBlocking(from: archive, paths: paths, into: destination, cancel: flag, progress: progress))
                }
            }
        } onCancel: { flag.cancel() }
    }

    public func extractItemsBlocking(from archive: URL, paths: [String], into destination: URL, cancel: CancellationFlag,
                              progress report: @escaping @Sendable (OperationProgress) -> Void) -> ExtractResult {
        var result = ExtractResult()
        let destPath = CopyEngine.trimmed(destination.path(percentEncoded: false))
        let reporter = ProgressReporter(report, interval: .milliseconds(50))
        var progress = OperationProgress()
        progress.totalItems = paths.count
        progress.totalBytes = 1_000
        progress.currentName = archive.lastPathComponent
        progress.isPreparing = false
        reporter.update(progress, force: true)
        let temp = (destPath as NSString).appendingPathComponent(".kansio-partial-\(UUID().uuidString)")
        defer { if CopyEngine.exists(temp) { _ = CopyEngine.removeTree(temp) } } // only our temporary folder
        guard mkdir(temp, 0o755) == 0 else {
            result.errors.append((archive, FileSystemError(errno: errno, path: temp)))
            return result
        }
        let base = progress
        do throws(FileSystemError) {
            try extractWithFallback(archive, only: paths, into: URL(filePath: temp), cancel: cancel) { fraction in
                var p = base
                p.completedBytes = Int64(fraction * 900)
                reporter.update(p)
            }
        } catch {
            if error == archiveCancelled || cancel.isCancelled { result.cancelled = true } else { result.errors.append((archive, error)) }
            return result
        }
        let extracted = paths.map { (temp as NSString).appendingPathComponent(ArchiveEntry.clean($0)) }.filter(CopyEngine.exists)
        if extracted.count < paths.count {
            for path in paths where !CopyEngine.exists((temp as NSString).appendingPathComponent(ArchiveEntry.clean(path))) {
                result.errors.append((archive.appending(path: path), FileSystemError(.other("It isn’t in the archive"), path: path)))
            }
        }
        place(extracted, into: destPath, result: &result, cancel: cancel)
        progress.completedBytes = progress.totalBytes
        progress.completedItems = paths.count
        reporter.update(progress, force: true)
        return result
    }
}
