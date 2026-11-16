import Darwin
import Foundation

/// Moves items to the Trash. Injectable so tests and the self-test never touch the user's Trash.
public protocol Trasher: Sendable {
    /// Moves `url` to the trash and returns where it went (needed later for Undo).
    func trash(_ url: URL) throws -> URL
}

/// The real Trash (`FileManager.trashItem`): the volume's own Trash folder (~/.Trash on the
/// startup disk, `.Trashes/<uid>` on other volumes). Never deletes permanently.
public struct SystemTrasher: Trasher {
    public init() {}
    public func trash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }
}

/// Test double: "trash" = move into `directory` (on the same volume), Finder-style unique names.
public struct DirectoryTrasher: Trasher {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func trash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = url.lastPathComponent
        for n in 1...10_000 {
            let target = directory.appending(path: FileNames.numbered(name, n))
            // RENAME_EXCL: plain rename(2) would silently replace an existing file.
            if renamex_np(url.path(percentEncoded: false), target.path(percentEncoded: false), UInt32(RENAME_EXCL)) == 0 { return target }
            if errno != EEXIST && errno != ENOTEMPTY { throw FileSystemError(errno: errno, path: url.path(percentEncoded: false)) }
        }
        throw FileSystemError(.other("Too many items with the same name in the trash"), path: url.path(percentEncoded: false))
    }
}

/// The simple, single-step operations (rename, new folder, move to trash).
///
/// All are *blocking* (a network volume can take a while): call the async variants, which
/// run on the listing queue. They never overwrite and never delete permanently.
public enum FileOperations {
    public enum RenameError: Error, Sendable, Equatable, CustomStringConvertible {
        case invalidName(FileNames.Problem)
        case alreadyExists(String)
        case failed(FileSystemError)

        public var description: String {
            switch self {
            case .invalidName(let p): p.description
            case .alreadyExists(let name): "An item named “\(name)” already exists."
            case .failed(let e): e.description
            }
        }
    }

    /// Renames the item at `url` to `newName` in the same folder. Returns the new URL.
    ///
    /// Uses `renamex_np(RENAME_EXCL)`, so an existing item is never replaced — except when only
    /// the letter case changes on a case-insensitive volume ("a.txt" → "A.txt"), where the
    /// "existing" item *is* this one.
    public static func renameBlocking(_ url: URL, to newName: String) throws(RenameError) -> URL {
        if let problem = FileNames.validate(newName) { throw .invalidName(problem) }
        let oldPath = url.path(percentEncoded: false)
        let oldName = (oldPath as NSString).lastPathComponent
        let parent = (oldPath as NSString).deletingLastPathComponent
        let newPath = (parent as NSString).appendingPathComponent(newName)
        let newURL = URL(filePath: newPath)
        if newName == oldName { return url } // byte-identical: nothing to do
        if renamex_np(oldPath, newPath, UInt32(RENAME_EXCL)) == 0 { return newURL }
        let err = errno
        if err == EEXIST {
            // Case-only (or normalization-only) change on an insensitive volume: same file.
            if isSameFile(oldPath, newPath) {
                if renamex_np(oldPath, newPath, 0) == 0 { return newURL }
                throw .failed(FileSystemError(errno: errno, path: oldPath))
            }
            throw .alreadyExists(newName)
        }
        throw .failed(FileSystemError(errno: err, path: oldPath))
    }

    public static func rename(_ url: URL, to newName: String) async -> Result<URL, RenameError> {
        await runOnListingQueue {
            do throws(RenameError) { return .success(try renameBlocking(url, to: newName)) } catch { return .failure(error) }
        }
    }

    /// Creates a folder in `parent` named `preferredName`, or "name (2)", "name (3)"… if taken.
    /// Returns the name actually used.
    public static func createFolderBlocking(in parent: URL, preferredName: String = "New folder") throws(FileSystemError) -> String {
        let base = parent.path(percentEncoded: false)
        for n in 1...10_000 {
            let name = FileNames.numbered(preferredName, n)
            if mkdir((base as NSString).appendingPathComponent(name), 0o777) == 0 { return name }
            if errno != EEXIST { throw FileSystemError(errno: errno, path: base) }
        }
        throw FileSystemError(.other("Too many folders named “\(preferredName)”"), path: base)
    }

    public static func createFolder(in parent: URL, preferredName: String = "New folder") async -> Result<String, FileSystemError> {
        await runOnListingQueue {
            do throws(FileSystemError) { return .success(try createFolderBlocking(in: parent, preferredName: preferredName)) }
            catch { return .failure(error) }
        }
    }

    public struct TrashOutcome: Sendable {
        /// Original URL → where it is now.
        public var trashed: [(original: URL, inTrash: URL)] = []
        public var failed: [(url: URL, error: FileSystemError)] = []
    }

    /// Moves each item to the trash; failures don't stop the rest and are all reported.
    public static func trashBlocking(_ urls: [URL], using trasher: any Trasher) -> TrashOutcome {
        let state = Signposts.fileOps.beginInterval("Trash", "\(urls.count) items")
        defer { Signposts.fileOps.endInterval("Trash", state) }
        var outcome = TrashOutcome()
        for url in urls {
            do {
                outcome.trashed.append((url, try trasher.trash(url)))
            } catch {
                outcome.failed.append((url, error as? FileSystemError ?? FileSystemError(foundation: error, path: url.path(percentEncoded: false))))
            }
        }
        return outcome
    }

    public static func trash(_ urls: [URL], using trasher: any Trasher) async -> TrashOutcome {
        await runOnListingQueue { trashBlocking(urls, using: trasher) }
    }

    /// True if both paths name the same file system object (same device + inode).
    static func isSameFile(_ a: String, _ b: String) -> Bool {
        var sa = stat(), sb = stat()
        guard lstat(a, &sa) == 0, lstat(b, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }
}
