import CoreServices
import Darwin
import Foundation
import Synchronization

/// Blocking file-system work for the folder tree. Runs on its own queues so tree work never
/// delays the file list's listing (and a hung network mount stalls only tree work).
public enum FolderTreeIO {
    /// Listing for expansion and the reveal (user-visible: high priority).
    static let listQueue = DispatchQueue(label: "kansio.tree.list", qos: .userInitiated, attributes: .concurrent)
    /// "Has a subfolder?" checks for rows on screen (serial: one at a time, cancelled when scrolled away).
    static let checkQueue = DispatchQueue(label: "kansio.tree.check", qos: .utility)

    public struct Listing: Sendable {
        /// Folders and links to folders (packages excluded), in Finder order.
        public let items: [FileItem]
        public let realPath: String?
    }

    /// The subfolders of `url` (blocking). Symlinks are classified with one `stat` each; only
    /// links to folders are kept. Hidden folders are included (the tree filters them).
    public static func listFoldersBlocking(_ url: URL, cancel: CancellationFlag = CancellationFlag()) throws(FileSystemError) -> Listing {
        var folders: [FileItem] = []
        let base = url.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        try BulkDirectoryLister().list(url) { batch in
            for item in batch {
                switch item.kind {
                case .directory where !item.isPackage:
                    folders.append(item)
                case .symlink:
                    var link = item
                    link.flags.insert(SymlinkResolver.classify(prefix + item.name))
                    if link.flags.contains(.linkToFolder) { folders.append(link) }
                default:
                    break
                }
            }
            return !cancel.isCancelled
        }
        let order = NameCollation.sortedIndices(of: folders.map(\.name))
        return Listing(items: order.map { folders[Int($0)] }, realPath: realPath(base))
    }

    /// `listFoldersBlocking` off the caller's thread; `timeout` (network volumes) gives up waiting
    /// (the syscall itself can't be interrupted) and reports `.timedOut`.
    public static func listFolders(_ url: URL, timeout: Duration? = nil, cancel: CancellationFlag = CancellationFlag()) async -> Result<Listing, FileSystemError> {
        let work: @Sendable () -> Result<Listing, FileSystemError> = {
            do throws(FileSystemError) { return .success(try listFoldersBlocking(url, cancel: cancel)) }
            catch { return .failure(error) }
        }
        guard let timeout else { return await run(on: listQueue, work) }
        return await withDeadline(timeout, on: listQueue, work) ?? .failure(FileSystemError(.timedOut, path: url.path))
    }

    /// Whether `url` contains at least one folder the tree would show: reads entries until the first
    /// one and stops (blocking). Links count if they lead to a folder.
    public static func hasShownSubfolderBlocking(_ url: URL, showHidden: Bool, cancel: CancellationFlag = CancellationFlag()) -> Bool {
        var found = false
        let base = url.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        try? BulkDirectoryLister().list(url) { batch in
            for item in batch where showHidden || !item.isHidden {
                if item.kind == .directory, !item.isPackage { found = true; break }
                if item.kind == .symlink, SymlinkResolver.classify(prefix + item.name).contains(.linkToFolder) { found = true; break }
            }
            return !found && !cancel.isCancelled
        }
        return found
    }

    /// The check off the caller's thread, serially on the check queue (skipped when cancelled before
    /// it starts); nil when cancelled or past `timeout`.
    public static func hasShownSubfolder(_ url: URL, showHidden: Bool, timeout: Duration? = nil,
                                         cancel: CancellationFlag) async -> Bool? {
        let work: @Sendable () -> Bool? = {
            cancel.isCancelled ? nil : hasShownSubfolderBlocking(url, showHidden: showHidden, cancel: cancel)
        }
        guard let timeout else { return await run(on: checkQueue, work) }
        return await withDeadline(timeout, on: checkQueue, work) ?? nil
    }

    /// "/a/b/" → "/a/b" ("/" stays).
    public static func normalizedPath(_ path: String) -> String { FolderTree.normalized(path) }

    public static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func run<T: Sendable>(on queue: DispatchQueue, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: work()) } }
    }

    /// Result if `work` finishes within `timeout`, else nil (the work keeps running; its result is dropped).
    private static func withDeadline<T: Sendable>(_ timeout: Duration, on queue: DispatchQueue,
                                                  _ work: @escaping @Sendable () -> T) async -> T? {
        let once = Mutex<CheckedContinuation<T?, Never>?>(nil)
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            once.withLock { $0 = continuation }
            queue.async {
                let value = work()
                once.withLock { $0?.resume(returning: value); $0 = nil }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) {
                once.withLock { $0?.resume(returning: nil); $0 = nil }
            }
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

/// Directory-level FSEvents for the tree: one recursive stream per root, reporting which
/// *directories* changed (no file-level events). The tree re-reads the ones it has listed.
public final class TreeWatcher: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        /// These directories' entries changed (real paths).
        case changed(Set<String>)
        /// FSEvents lost detail below this path: re-read every listed folder under it.
        case rescan(String)
    }

    public let rootPath: String
    private let handler: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "kansio.tree.watcher", qos: .utility)
    private var stream: FSEventStreamRef?
    private let stopped = Atomic<Bool>(false)

    /// `rootPath` is resolved (FSEvents reports real paths).
    public init(rootPath: String, handler: @escaping @Sendable (Event) -> Void) {
        self.rootPath = FolderTreeIO.realPath(rootPath) ?? rootPath
        self.handler = handler
        self.idHandler = nil
    }

    /// Like `init(rootPath:handler:)`, but changed directories come with the FSEvents id of their latest
    /// event (folder sizes: a change older than a measurement is already in it).
    public init(rootPath: String, changes: @escaping @Sendable ([String: UInt64]) -> Void,
                rescan: @escaping @Sendable (String) -> Void) {
        self.rootPath = FolderTreeIO.realPath(rootPath) ?? rootPath
        self.handler = { if case .rescan(let path) = $0 { rescan(path) } }
        self.idHandler = changes
    }

    private let idHandler: (@Sendable ([String: UInt64]) -> Void)?

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Starts on the watcher's own queue (no FSEvents setup on the caller's thread); `since`: replay
    /// what changed after that event id first (a paused window catching up).
    public func start(latency: TimeInterval = 0.3, since eventID: UInt64? = nil) {
        queue.async { self.startOnQueue(latency: latency, since: eventID) }
    }

    private func startOnQueue(latency: TimeInterval, since eventID: UInt64?) {
        guard stream == nil, !stopped.load(ordering: .relaxed) else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, treeWatcherCallback, &context, [rootPath] as CFArray,
                                               eventID.map { FSEventStreamEventId($0) } ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latency, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

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

    fileprivate func handle(paths: [String], flags: [FSEventStreamEventFlags], ids: [UInt64]) {
        guard !stopped.load(ordering: .relaxed) else { return }
        var changed = Set<String>()
        var latest: [String: UInt64] = [:]
        for (i, (path, flag)) in zip(paths, flags).enumerated() {
            if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            let path = FolderTree.normalized(path)
            if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                             | kFSEventStreamEventFlagKernelDropped) != 0 {
                handler(.rescan(path))
                continue
            }
            // Directory-level events name the folder whose entries changed (a created/removed/renamed
            // folder is reported as a change of its parent).
            changed.insert(path)
            if i < ids.count { latest[path] = max(latest[path] ?? 0, ids[i]) }
        }
        guard !changed.isEmpty else { return }
        if let idHandler { idHandler(latest) } else { handler(.changed(changed)) }
    }
}

private let treeWatcherCallback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
    guard let info else { return }
    let watcher = Unmanaged<TreeWatcher>.fromOpaque(info).takeUnretainedValue()
    let array = unsafeBitCast(paths, to: NSArray.self)
    watcher.handle(paths: (0..<count).compactMap { array[$0] as? String }, flags: (0..<count).map { flags[$0] },
                   ids: (0..<count).map { UInt64(ids[$0]) })
}
