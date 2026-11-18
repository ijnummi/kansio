import Darwin
import Foundation
import Synchronization

/// Counts entries visited by a walk, so a watchdog can tell a slow walk from one blocked in a syscall.
public final class ProgressCounter: Sendable {
    private let state = Atomic<Int>(0)
    public init() {}
    public var value: Int { state.load(ordering: .relaxed) }
    func tick() { state.add(1, ordering: .relaxed) }
}

/// Counts items and bytes below some URLs — for Get Info (and later, folder sizes).
///
/// - Uses `lstat`: symlinks are counted as themselves and never followed (no loops, no
///   double counting through links).
/// - Hard links are counted once (by device + inode).
/// - Doesn't cross into other volumes mounted inside a folder.
/// - Cooperative: checks `cancel` and reports progress every ~2,000 items.
public enum ItemStatistics {
    public struct Totals: Sendable, Equatable {
        public var files = 0
        public var folders = 0
        public var others = 0 // symlinks, devices, …
        /// Logical size of regular files.
        public var bytes: Int64 = 0
        /// Folders that couldn't be read (permission denied…); totals are then a lower bound.
        public var unreadable = 0
        /// Folders not descended into on purpose (`Options`); totals are then a lower bound too.
        public var skipped = 0
        public var items: Int { files + folders + others }
        public init() {}
    }

    public struct Options: Sendable {
        /// Don't descend into dataless (evicted iCloud) folders — reading one downloads its listing — and
        /// don't let anything below be materialized (the thread's I/O policy; restored afterwards).
        public var skipDataless = false
        /// Folders (normalized paths) not descended into, e.g. other apps' containers: reading them can
        /// raise a privacy prompt.
        public var skipping: Set<String> = []
        /// Ticked for every entry visited (and before each folder is opened).
        public var counter: ProgressCounter?
        public init(skipDataless: Bool = false, skipping: Set<String> = [], counter: ProgressCounter? = nil) {
            self.skipDataless = skipDataless
            self.skipping = skipping
            self.counter = counter
        }
    }

    /// Blocking: call off the main thread.
    public static func measure(_ urls: [URL], options: Options = Options(), cancel: CancellationFlag = CancellationFlag(),
                               progress: ((Totals) -> Void)? = nil) -> Totals {
        var previousPolicy: Int32?
        if options.skipDataless {
            previousPolicy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        }
        defer {
            if let previousPolicy, previousPolicy >= 0 {
                setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previousPolicy)
            }
        }
        var totals = Totals()
        var seen = Set<Inode>()
        var counter = 0
        for url in urls {
            if cancel.isCancelled { break }
            let path = FolderTree.normalized(url.path(percentEncoded: false))
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            walk(path, st, device: st.st_dev, options: options, totals: &totals, seen: &seen, cancel: cancel, counter: &counter, progress: progress)
        }
        return totals
    }

    public static func measure(_ urls: [URL], cancel: CancellationFlag = CancellationFlag(),
                               progress: (@Sendable (Totals) -> Void)? = nil) async -> Totals {
        await runOnListingQueue { measure(urls, cancel: cancel, progress: progress.map { p in { p($0) } }) }
    }

    private struct Inode: Hashable { let dev: dev_t; let ino: ino_t }

    /// Depth-first over an explicit stack of open folders — not recursion: a deep tree (node_modules, the fixtures'
    /// `deep`) overflowed the 512 KB stack of the worker thread in debug builds.
    private static func walk(_ root: String, _ rootStat: stat, device: dev_t, options: Options, totals: inout Totals, seen: inout Set<Inode>,
                             cancel: CancellationFlag, counter: inout Int, progress: ((Totals) -> Void)?) {
        var stack: [(dir: UnsafeMutablePointer<DIR>, prefix: String)] = []
        defer { for frame in stack { closedir(frame.dir) } }
        if let dir = visit(root, rootStat, device: device, options: options, totals: &totals, seen: &seen, counter: &counter, progress: progress) {
            stack.append((dir, root.hasSuffix("/") ? root : root + "/"))
        }
        while let top = stack.last {
            if cancel.isCancelled { return }
            guard let entry = readdir(top.dir) else {
                closedir(top.dir)
                stack.removeLast()
                continue
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            let child = top.prefix + name
            var cst = stat()
            guard lstat(child, &cst) == 0 else { continue }
            if let dir = visit(child, cst, device: device, options: options, totals: &totals, seen: &seen, counter: &counter, progress: progress) {
                stack.append((dir, child + "/"))
            }
        }
    }

    /// Counts one entry; for a folder to descend into, returns it opened.
    private static func visit(_ path: String, _ st: stat, device: dev_t, options: Options, totals: inout Totals, seen: inout Set<Inode>,
                              counter: inout Int, progress: ((Totals) -> Void)?) -> UnsafeMutablePointer<DIR>? {
        options.counter?.tick()
        counter += 1
        if counter % 2000 == 0 { progress?(totals) }
        switch st.st_mode & S_IFMT {
        case S_IFREG:
            if st.st_nlink > 1 && !seen.insert(Inode(dev: st.st_dev, ino: st.st_ino)).inserted { return nil } // hard link seen
            totals.files += 1
            totals.bytes += Int64(st.st_size)
        case S_IFDIR:
            totals.folders += 1
            guard st.st_dev == device else { return nil } // a volume mounted inside: don't descend
            if options.skipDataless && st.st_flags & UInt32(SF_DATALESS) != 0 { totals.skipped += 1; return nil }
            if !options.skipping.isEmpty && options.skipping.contains(path) { totals.skipped += 1; return nil }
            guard let dir = opendir(path) else { totals.unreadable += 1; return nil }
            return dir
        default:
            totals.others += 1
        }
        return nil
    }
}
