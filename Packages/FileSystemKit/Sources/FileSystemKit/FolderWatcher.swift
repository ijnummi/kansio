import CoreServices
import Darwin
import Foundation
import Synchronization

/// Watches one folder for changes to its direct children with FSEvents (file-level events).
///
/// - Events are coalesced by FSEvents (`latency`) and delivered as the set of child *names* that
///   changed (created, removed, renamed — old and new name — or modified). The caller re-reads
///   just those names.
/// - `.rescan` when FSEvents says it lost track (dropped events / must scan): re-list once and diff.
/// - `.folderGone` when the folder itself was deleted, moved or renamed.
/// - Paths are compared in resolved form: FSEvents reports real paths ("/private/var/…").
///
/// FSEvents covers local volumes; network shares (SMB) only report changes made from this Mac.
public final class FolderWatcher: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case changed(Set<String>)
        case rescan
        case folderGone
    }

    public let folder: URL
    private let realFolder: String
    private let handler: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "kansio.watcher", qos: .userInitiated)
    private var stream: FSEventStreamRef?
    private let stopped = Atomic<Bool>(false)

    public init(folder: URL, handler: @escaping @Sendable (Event) -> Void) {
        self.folder = folder
        self.handler = handler
        realFolder = Self.realPath(folder.path(percentEncoded: false))
    }

    deinit {
        // Last reference gone: the queue blocks above hold `self`, so by now the stream is torn down
        // or was never created.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Starts watching (from "now": earlier changes aren't replayed). The stream is created on the
    /// watcher's own queue, so this returns immediately (no FSEvents setup on the caller's thread).
    public func start(latency: TimeInterval = 0.05) {
        queue.async { self.startOnQueue(latency: latency) }
    }

    private func startOnQueue(latency: TimeInterval) {
        guard stream == nil, !stopped.load(ordering: .relaxed) else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, watcherCallback, &context, [realFolder] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Stops delivering events at once; the stream is torn down on the watcher's queue (after any
    /// pending start, so the order is always create → destroy).
    public func stop() {
        guard !stopped.exchange(true, ordering: .relaxed) else { return }
        queue.async {
            guard let stream = self.stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    fileprivate func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard !stopped.load(ordering: .relaxed) else { return }
        var names = Set<String>()
        var rescan = false, gone = false
        let prefix = realFolder == "/" ? "/" : realFolder + "/"
        for (path, flag) in zip(paths, flags) {
            let path = Self.trimmed(path)
            if flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0 { gone = true; continue }
            if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                             | kFSEventStreamEventFlagKernelDropped) != 0 {
                if path == realFolder || realFolder.hasPrefix(path + "/") || path.hasPrefix(prefix) { rescan = true }
                continue
            }
            if path == realFolder {
                // The folder itself was removed or renamed (otherwise: its own metadata changed).
                if flag & UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0,
                   access(realFolder, F_OK) != 0 { gone = true }
                continue
            }
            guard path.hasPrefix(prefix) else { continue }
            let rest = path.dropFirst(prefix.count)
            guard !rest.isEmpty, !rest.contains("/") else { continue } // deeper changes don't show in this folder
            names.insert(String(rest))
        }
        if gone { handler(.folderGone); return }
        if rescan { handler(.rescan); return }
        if !names.isEmpty { handler(.changed(names)) }
    }

    static func realPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(path, &buffer) != nil else { return trimmed(path) }
        return trimmed(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

private let watcherCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
    guard let info else { return }
    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
    let array = unsafeBitCast(paths, to: NSArray.self)
    let pathList = (0..<count).compactMap { array[$0] as? String }
    let flagList = (0..<count).map { flags[$0] }
    watcher.handle(paths: pathList, flags: flagList)
}

/// Turning watcher events into model changes.
public enum LiveChanges {
    /// Beyond this many changed names in one batch, a single re-list + diff is cheaper.
    public static let relistThreshold = 2000

    /// Re-reads `names` in `folder` (blocking; one getattrlist each): present → added/updated,
    /// gone → removed. Symlink targets are classified for new links.
    public static func readChanges(_ names: Set<String>, in folder: URL) -> (removed: Set<String>, updated: [FileItem]) {
        var removed = Set<String>()
        var updated: [FileItem] = []
        let base = folder.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        for name in names {
            if var item = try? BulkDirectoryLister.readItem(at: URL(filePath: prefix + name)) {
                if item.kind == .symlink { item.flags.insert(SymlinkResolver.classify(prefix + name)) }
                updated.append(item)
            } else {
                removed.insert(name)
            }
        }
        return (removed, updated)
    }

    /// Full diff between two listings (after a re-list): what to remove and what to add/update.
    /// Unchanged items (same name, inode, size, dates, flags) aren't touched.
    public static func diff(old: [FileItem], new: [FileItem]) -> (removed: Set<String>, updated: [FileItem]) {
        let oldByName = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let newNames = Set(new.map(\.name))
        let removed = Set(old.map(\.name).filter { !newNames.contains($0) })
        let updated = new.filter { oldByName[$0.name] != $0 }
        return (removed, updated)
    }

    /// Renames among the changes: a removed name whose inode reappears under a new name.
    /// Lets the view carry the selection across an external rename.
    public static func renames(removed: Set<String>, updated: [FileItem], previous: FolderContents) -> [String: String] {
        let byInode = Dictionary(updated.map { ($0.fileID, $0.name) }, uniquingKeysWith: { a, _ in a })
        var result: [String: String] = [:]
        for name in removed {
            if let old = previous.item(named: name), old.fileID != 0, let newName = byInode[old.fileID] { result[name] = newName }
        }
        return result
    }
}
