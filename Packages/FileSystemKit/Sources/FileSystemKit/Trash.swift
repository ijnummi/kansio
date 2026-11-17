import Darwin
import Foundation
import Synchronization

// P2-1: the Trash — where trashed items are, where they came from, putting them back, emptying.
//
// macOS keeps one Trash folder per volume: `~/.Trash` for the startup disk and `<volume>/.Trashes/<uid>` for other
// local volumes. Network volumes have none (Finder deletes immediately there); Kansio can keep its own
// `.Trashes/<uid>` on a network volume when the user opts in. Where an item came from is known from Kansio's own
// history (every Move to Trash is recorded) or from Finder's put-back data in the Trash folder's `.DS_Store`.

// MARK: History

/// One item Kansio moved to a Trash.
public struct TrashRecord: Codable, Sendable, Hashable {
    /// Where it is now (canonical path: symlinks in its folder resolved).
    public var inTrash: String
    /// Where it was.
    public var original: String
    public var date: Date
    /// Its inode in the Trash: a different item that later lands on the same path isn't mistaken for this one.
    public var fileID: UInt64

    public init(inTrash: String, original: String, date: Date, fileID: UInt64) {
        self.inTrash = inTrash
        self.original = original
        self.date = date
        self.fileID = fileID
    }
}

/// Kansio's record of what it trashed, kept in a small JSON file (Application Support), loaded on first use.
/// Thread-safe. Changes are made in place and saved together a moment later on a background queue (trashing 10,000
/// items is one write, not 10,000); `flushNow()` saves at once (quitting).
public final class TrashHistory: Sendable {
    public let file: URL?
    /// Newest records kept (a Trash rarely holds more; the oldest are least likely to be put back).
    public static let limit = 20_000
    private struct State {
        var records: [String: TrashRecord]?
        var saveScheduled = false
    }
    private let state = Mutex(State())
    private let saveQueue = DispatchQueue(label: "kansio.trash-history", qos: .utility)

    /// `file` nil: memory only (tests).
    public init(file: URL?) { self.file = file }

    public func record(original: URL, inTrash: URL, date: Date = .now) {
        let path = TrashPaths.canonical(inTrash.path(percentEncoded: false))
        var st = stat()
        let fileID = lstat(path, &st) == 0 ? UInt64(st.st_ino) : 0
        let record = TrashRecord(inTrash: path, original: original.path(percentEncoded: false), date: date, fileID: fileID)
        mutate { $0[path] = record }
    }

    /// The record for the item now at `path` (canonical) with inode `fileID`.
    public func lookup(_ path: String, fileID: UInt64) -> TrashRecord? {
        let record = state.withLock { state in Self.load(&state, file)[path] }
        guard let record, record.fileID == 0 || fileID == 0 || record.fileID == fileID else { return nil }
        return record
    }

    public func forget(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        mutate { records in for path in paths { records.removeValue(forKey: path) } }
    }

    /// Drops records of items that are gone (`exists` false) and older than `age` (an Undo may still bring a younger one back).
    public func prune(olderThan age: TimeInterval = 30 * 86_400, exists: (String) -> Bool) {
        let cutoff = Date.now.addingTimeInterval(-age)
        let candidates = state.withLock { state in Self.load(&state, file).values.filter { $0.date < cutoff }.map(\.inTrash) }
        forget(candidates.filter { !exists($0) })
    }

    public var count: Int { state.withLock { state in Self.load(&state, file).count } }

    /// Saves now if a save is pending (blocking).
    public func flushNow() { saveQueue.sync { save() } }

    private func mutate(_ change: (inout [String: TrashRecord]) -> Void) {
        let schedule = state.withLock { state -> Bool in
            _ = Self.load(&state, file)
            change(&state.records!) // in place: no copy of the dictionary
            if state.records!.count > Self.limit + Self.limit / 10 { // trim now and then, not on every record
                let keep = state.records!.values.sorted { $0.date > $1.date }.prefix(Self.limit)
                state.records = Dictionary(uniqueKeysWithValues: keep.map { ($0.inTrash, $0) })
            }
            guard file != nil, !state.saveScheduled else { return false }
            state.saveScheduled = true
            return true
        }
        if schedule { saveQueue.asyncAfter(deadline: .now() + 0.3) { self.save() } }
    }

    private func save() {
        guard let file else { return }
        let snapshot: [TrashRecord]? = state.withLock { state in
            guard state.saveScheduled else { return nil }
            state.saveScheduled = false
            return state.records.map { Array($0.values) }
        }
        guard let snapshot else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
    }

    private static func load(_ state: inout State, _ file: URL?) -> [String: TrashRecord] {
        if let records = state.records { return records }
        let read = read(file)
        state.records = read
        return read
    }

    private static func read(_ file: URL?) -> [String: TrashRecord] {
        guard let file, let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([TrashRecord].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.inTrash, $0) }, uniquingKeysWith: { a, b in a.date > b.date ? a : b })
    }
}

/// A trasher that records each item in the history (wraps the real one or a test double).
public struct RecordingTrasher: Trasher {
    public let base: any Trasher
    public let history: TrashHistory

    public init(_ base: any Trasher, history: TrashHistory) {
        self.base = base
        self.history = history
    }

    public func trash(_ url: URL) throws -> URL {
        let inTrash = try base.trash(url)
        history.record(original: url, inTrash: inTrash)
        return inTrash
    }
}

/// Network volumes have no Trash (Finder deletes immediately there). This trasher sends items on a network volume to
/// that volume's own `.Trashes/<uid>` when the user opted in (`useVolumeFolders`), and refuses them otherwise — the
/// caller then asks before deleting them for good. Everything else goes to `base`. Undo/Redo and the copy engine's
/// Replace use it too, so they never fall back to deleting.
public final class VolumeAwareTrasher: Trasher {
    public let base: any Trasher
    private let useVolumeFolders: Atomic<Bool>
    /// The mount point of the network volume `url` is on (nil: not on a network volume). Blocking.
    public let networkRoot: @Sendable (URL) -> URL?

    public init(_ base: any Trasher, useVolumeFolders: Bool = false,
                networkRoot: @escaping @Sendable (URL) -> URL? = VolumeAwareTrasher.systemNetworkRoot) {
        self.base = base
        self.useVolumeFolders = Atomic(useVolumeFolders)
        self.networkRoot = networkRoot
    }

    public var usesVolumeFolders: Bool {
        get { useVolumeFolders.load(ordering: .relaxed) }
        set { useVolumeFolders.store(newValue, ordering: .relaxed) }
    }

    public func trash(_ url: URL) throws -> URL {
        guard let root = networkRoot(url) else { return try base.trash(url) }
        guard usesVolumeFolders else {
            throw FileSystemError(.other("Network volumes have no Trash"), path: url.path(percentEncoded: false))
        }
        return try DirectoryTrasher(directory: TrashFolders.volumeTrash(root: root)).trash(url)
    }

    public static let systemNetworkRoot: @Sendable (URL) -> URL? = { url in
        guard let volume = TrashFolders.volumeBlocking(of: url), volume.isNetwork else { return nil }
        return volume.root
    }
}

enum TrashPaths {
    /// `path` with symlinks in its folder resolved (`/var/…` → `/private/var/…`), the name kept as is.
    static func canonical(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let resolved = realpath(parent, nil) else { return path }
        defer { free(resolved) }
        return (String(cString: resolved) as NSString).appendingPathComponent(name)
    }

    static func canonicalFolder(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True if `path` is strictly inside `root` (both canonical).
    static func isInside(_ path: String, _ root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) && path.count > prefix.count
    }
}

// MARK: Trash folders

/// One Trash folder and the volume it belongs to (Finder's put-back paths are relative to the volume).
public struct TrashFolder: Sendable, Hashable {
    /// Canonical path.
    public let url: URL
    public let volumeRoot: URL
    public let isNetwork: Bool
    /// Canonical path, no trailing slash.
    public var path: String { TrashPaths.canonicalFolder(url.path(percentEncoded: false)) }

    public init(url: URL, volumeRoot: URL, isNetwork: Bool = false) {
        self.url = URL(filePath: TrashPaths.canonicalFolder(url.path(percentEncoded: false)), directoryHint: .isDirectory)
        self.volumeRoot = volumeRoot
        self.isNetwork = isNetwork
    }
}

public enum TrashFolders {
    /// `<volume>/.Trashes/<uid>`: a volume's Trash for this user (macOS's on local volumes, Kansio's on network ones).
    public static func volumeTrash(root: URL) -> URL {
        root.appending(path: ".Trashes", directoryHint: .isDirectory).appending(path: "\(getuid())", directoryHint: .isDirectory)
    }

    /// `~/.Trash`, plus the `.Trashes/<uid>` of every other mounted volume that has one. Network volumes only with
    /// `includeNetwork` (a stale mount can block; their Trash folders exist only if Kansio made them).
    /// Blocking: call off the main thread.
    public static func discoverBlocking(home: URL = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
                                        volumes: [Volume], includeNetwork: Bool) -> [TrashFolder] {
        var folders = [TrashFolder(url: home.appending(path: ".Trash", directoryHint: .isDirectory), volumeRoot: URL(filePath: "/"))]
        for volume in volumes where !volume.isRoot && (includeNetwork || !volume.isNetwork) {
            let trash = volumeTrash(root: volume.url)
            var st = stat()
            if lstat(trash.path(percentEncoded: false), &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                folders.append(TrashFolder(url: trash, volumeRoot: volume.url, isNetwork: volume.isNetwork))
            }
        }
        return folders
    }

    /// The volume `url` is on: its mount point and whether it's a network volume. Blocking.
    public static func volumeBlocking(of url: URL) -> (root: URL, isNetwork: Bool)? {
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsLocalKey]), let root = values.volume else { return nil }
        return (root, values.volumeIsLocal == false)
    }
}

// MARK: Finder's put-back data

/// Reads where Finder's trashed items came from: the Trash folder's `.DS_Store` holds, per name, "ptbL" (the original
/// folder, relative to the volume root) and "ptbN" (the original name). Read-only; never written.
public enum FinderPutBack {
    /// Name in the Trash folder → original absolute path. Empty if there's no readable `.DS_Store`.
    public static func read(_ folder: TrashFolder) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: folder.url.appending(path: ".DS_Store").path(percentEncoded: false)) else { return [:] }
        let root = folder.volumeRoot.path(percentEncoded: false)
        var result: [String: String] = [:]
        for (name, fields) in DSStore.records(data, codes: ["ptbL", "ptbN"]) {
            guard let location = fields["ptbL"] else { continue }
            let original = fields["ptbN"] ?? name
            let parent = (root as NSString).appendingPathComponent(location)
            result[name] = (parent as NSString).appendingPathComponent(original)
        }
        return result
    }
}

/// A minimal reader for Finder's `.DS_Store` (a B-tree in a "buddy allocator" file). Only string ("ustr") records
/// are returned; everything is bounds-checked, and a malformed file just yields fewer records.
enum DSStore {
    /// File name → [record code: string value], for the requested codes.
    static func records(_ data: Data, codes: Set<String>) -> [String: [String: String]] {
        var reader = Reader(bytes: [UInt8](data))
        return reader.read(codes: codes) ?? [:]
    }

    struct Reader {
        let bytes: [UInt8]
        var result: [String: [String: String]] = [:]
        var visited = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        func u32(_ at: Int) -> UInt32? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
        }

        mutating func read(codes: Set<String>) -> [String: [String: String]]? {
            // Header: 00 00 00 01 "Bud1" rootOffset rootSize rootOffset; offsets count from byte 4.
            guard bytes.count >= 36, u32(0) == 1, Array(bytes[4..<8]) == Array("Bud1".utf8),
                  let rootOffset = u32(8).map(Int.init) else { return nil }
            let root = rootOffset + 4
            guard let blockCount = u32(root).map(Int.init), blockCount < 1_000_000 else { return nil }
            var addresses: [UInt32] = []
            for i in 0..<blockCount {
                guard let a = u32(root + 8 + 4 * i) else { return nil }
                addresses.append(a)
            }
            // The address list is padded to a multiple of 256 entries; then the directory ("DSDB" → block number).
            var p = root + 8 + 4 * ((blockCount + 255) / 256 * 256)
            guard let dirCount = u32(p) else { return nil }
            p += 4
            var dsdb: Int?
            for _ in 0..<min(Int(dirCount), 64) {
                guard p < bytes.count else { return nil }
                let length = Int(bytes[p])
                guard p + 1 + length + 4 <= bytes.count else { return nil }
                let name = String(decoding: bytes[(p + 1)..<(p + 1 + length)], as: UTF8.self)
                let block = u32(p + 1 + length).map(Int.init)
                p += 1 + length + 4
                if name == "DSDB" { dsdb = block }
            }
            func offset(_ block: Int) -> Int? {
                guard block >= 0, block < addresses.count else { return nil }
                return Int(addresses[block] & ~0x1f) + 4
            }
            guard let dsdb, let header = offset(dsdb), let rootNode = u32(header).map(Int.init) else { return nil }
            walk(node: rootNode, offset: offset, codes: codes, depth: 0)
            return result
        }

        mutating func walk(node: Int, offset: (Int) -> Int?, codes: Set<String>, depth: Int) {
            visited += 1
            guard depth < 32, visited < 100_000, let start = offset(node),
                  let pointer = u32(start).map(Int.init), let count = u32(start + 4).map(Int.init) else { return }
            var p = start + 8
            for _ in 0..<count {
                if pointer != 0 { // internal node: child, record, child, record, …, rightmost child = pointer
                    guard let child = u32(p).map(Int.init) else { return }
                    p += 4
                    walk(node: child, offset: offset, codes: codes, depth: depth + 1)
                }
                guard let next = record(at: p, codes: codes) else { return }
                p = next
            }
            if pointer != 0 { walk(node: pointer, offset: offset, codes: codes, depth: depth + 1) }
        }

        /// Reads one record at `p`; returns where the next one starts (nil: unknown type, stop).
        mutating func record(at start: Int, codes: Set<String>) -> Int? {
            guard let length = u32(start).map(Int.init), length < 4096 else { return nil }
            var p = start + 4
            guard let name = utf16(at: p, count: length) else { return nil }
            p += 2 * length
            guard p + 8 <= bytes.count else { return nil }
            let code = String(decoding: bytes[p..<(p + 4)], as: UTF8.self)
            let type = String(decoding: bytes[(p + 4)..<(p + 8)], as: UTF8.self)
            p += 8
            switch type {
            case "bool": return p + 1
            case "long", "shor", "type": return p + 4
            case "comp", "dutc": return p + 8
            case "blob":
                guard let n = u32(p).map(Int.init) else { return nil }
                return p + 4 + n
            case "ustr":
                guard let n = u32(p).map(Int.init), let value = utf16(at: p + 4, count: n) else { return nil }
                if codes.contains(code) { result[name, default: [:]][code] = value }
                return p + 4 + 2 * n
            default:
                return nil
            }
        }

        func utf16(at p: Int, count: Int) -> String? {
            guard count >= 0, p + 2 * count <= bytes.count else { return nil }
            var units: [UInt16] = []
            units.reserveCapacity(count)
            for i in 0..<count { units.append(UInt16(bytes[p + 2 * i]) << 8 | UInt16(bytes[p + 2 * i + 1])) }
            return String(decoding: units, as: UTF16.self)
        }
    }
}

// MARK: Listing

/// One item in the Trash view.
public struct TrashEntry: Sendable, Hashable {
    /// The item; `name` is its absolute path without the leading "/" (so `"/" + name` is its URL path —
    /// the list builds URLs as folder prefix + name, and the Trash view's prefix is "/").
    public var item: FileItem
    /// The name shown (the name in the Trash).
    public var displayName: String
    /// Where it came from (absolute path), if known.
    public var original: String?
    public var dateDeleted: Date?

    public var path: String { "/" + item.name }
    /// The original folder, for the Original Location column.
    public var originalFolder: String? { original.map { ($0 as NSString).deletingLastPathComponent } }
}

/// How the Trash view is ordered: a regular column or one of its own.
public enum TrashSortKey: String, Sendable, Hashable {
    case originalLocation = "trash.original"
    case dateDeleted = "trash.deleted"
}

public enum TrashListing {
    /// Everything in `folders` (Finder's `.DS_Store` left out), with where each item came from and when it was deleted
    /// (Kansio's history first, then Finder's put-back data; the date falls back to when it was added to the folder).
    /// Blocking: call off the main thread. Folders that can't be read are reported, the others still listed.
    public static func listBlocking(_ folders: [TrashFolder], history: TrashHistory?) -> (entries: [TrashEntry], errors: [FileSystemError]) {
        let state = Signposts.listing.beginInterval("Trash", "\(folders.count) folders")
        defer { Signposts.listing.endInterval("Trash", state) }
        var entries: [TrashEntry] = []
        var errors: [FileSystemError] = []
        let lister = BulkDirectoryLister()
        for folder in folders {
            let base = folder.url.path(percentEncoded: false)
            let prefix = base.hasSuffix("/") ? base : base + "/"
            let items: [FileItem]
            do { items = try lister.listAll(folder.url) } catch {
                var st = stat()
                if lstat(base, &st) != 0 && errno == ENOENT { continue } // no Trash folder there (yet)
                errors.append(error)
                continue
            }
            let finder = FinderPutBack.read(folder)
            for var item in items where item.name != ".DS_Store" {
                let path = prefix + item.name
                let record = history?.lookup(path, fileID: item.fileID)
                let displayName = item.name
                let added = record == nil ? addedDate(path) : nil
                item.name = String(path.dropFirst())
                entries.append(TrashEntry(item: item, displayName: displayName,
                                          original: record?.original ?? finder[displayName],
                                          dateDeleted: record?.date ?? added))
            }
        }
        return (entries, errors)
    }

    /// When the item was put in its folder (APFS/HFS+ keep this; it's when it went to the Trash).
    static func addedDate(_ path: String) -> Date? {
        (try? URL(filePath: path).resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
    }

    /// Display order. `key` (Original Location / Date Deleted) wins over `sort` when set; otherwise the regular columns
    /// sort as in a folder (folders first when ascending, names by Finder's rules).
    public static func ordered(_ entries: [TrashEntry], sort: FileSort, key: TrashSortKey?, ascending: Bool,
                               includeHidden: Bool) -> [TrashEntry] {
        let visible = includeHidden ? entries : entries.filter { !$0.item.isHidden }
        let nameRank = NameCollation.ranks(of: visible.map(\.displayName))
        let items = visible.map(\.item)
        var primary = [UInt64](repeating: 0, count: visible.count)
        switch key {
        case .originalLocation:
            let ranks = NameCollation.ranks(of: visible.map { $0.originalFolder ?? "\u{10FFFF}" }) // unknown last
            for i in visible.indices { primary[i] = UInt64(ranks[i]) }
        case .dateDeleted:
            for i in visible.indices { primary[i] = FolderContents.sortable(visible[i].dateDeleted?.timeIntervalSinceReferenceDate ?? 0) }
        case nil:
            let kindRank = sort.field == .kind ? FolderContents.kindRanks(items) : sort.field == .fileExtension ? FolderContents.extensionRanks(items) : []
            for i in visible.indices {
                let item = items[i]
                primary[i] = switch sort.field {
                case .name: 0
                case .dateModified: FolderContents.sortable(item.modificationDate.timeIntervalSinceReferenceDate)
                case .dateCreated: FolderContents.sortable(item.creationDate.timeIntervalSinceReferenceDate)
                case .size: UInt64(bitPattern: item.size) ^ (1 << 63)
                case .kind, .fileExtension: UInt64(kindRank[i])
                }
            }
        }
        let foldersFirst = key == nil
        var order = Array(visible.indices)
        order.sort { a, b in
            if foldersFirst, items[a].isFolder != items[b].isFolder { return items[a].isFolder }
            if primary[a] != primary[b] { return primary[a] < primary[b] }
            return nameRank[a] != nameRank[b] ? nameRank[a] < nameRank[b] : a < b
        }
        let asc = key == nil ? sort.ascending : ascending
        let result = order.map { visible[$0] }
        return asc ? result : result.reversed()
    }
}

// MARK: Put Back, deleting

public enum TrashActions {
    /// Moves a trashed item back to `original`, recreating its folder if needed. Never replaces anything: an item
    /// already there is reported (the caller asks what to do). Across volumes through the copy engine.
    public static func putBack(_ inTrash: URL, to original: URL) async -> FileSystemError? {
        await UndoPerformer.place(inTrash, at: original, missingMessage: "It’s no longer in the Trash")?.1
    }

    public struct DeleteOutcome: Sendable {
        public var deleted: [URL] = []
        public var failed: [(url: URL, error: FileSystemError)] = []
    }

    /// **Permanent deletion** — only of items strictly inside one of `roots` (Trash folders, or a network volume the
    /// user chose to delete on). Anything else is refused and reported, as is a root itself. Symlinks are removed,
    /// never followed. Blocking: call off the main thread (`deletePermanently`).
    public static func deletePermanentlyBlocking(_ urls: [URL], within roots: [URL]) -> DeleteOutcome {
        let state = Signposts.fileOps.beginInterval("Delete", "\(urls.count) items")
        defer { Signposts.fileOps.endInterval("Delete", state) }
        let canonicalRoots = roots.map { TrashPaths.canonicalFolder($0.path(percentEncoded: false)) }
        var outcome = DeleteOutcome()
        for url in urls {
            let path = TrashPaths.canonical(url.path(percentEncoded: false))
            guard canonicalRoots.contains(where: { TrashPaths.isInside(path, $0) }) else {
                outcome.failed.append((url, FileSystemError(.other("Kansio only deletes items in the Trash"), path: path)))
                continue
            }
            do {
                try FileManager.default.removeItem(atPath: path)
                outcome.deleted.append(url)
            } catch {
                outcome.failed.append((url, error as? FileSystemError ?? FileSystemError(foundation: error, path: path)))
            }
        }
        return outcome
    }

    public static func deletePermanently(_ urls: [URL], within roots: [URL]) async -> DeleteOutcome {
        await withCheckedContinuation { continuation in
            DeleteQueue.queue.async { continuation.resume(returning: deletePermanentlyBlocking(urls, within: roots)) }
        }
    }

    /// Empty Trash: permanently deletes everything in `folders` (Finder's `.DS_Store` too). Blocking.
    public static func emptyBlocking(_ folders: [TrashFolder]) -> DeleteOutcome {
        var outcome = DeleteOutcome()
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.url.path(percentEncoded: false))) ?? []
            let urls = names.map { folder.url.appending(path: $0) }
            let result = deletePermanentlyBlocking(urls, within: [folder.url])
            outcome.deleted += result.deleted
            outcome.failed += result.failed
        }
        return outcome
    }

    public static func empty(_ folders: [TrashFolder]) async -> DeleteOutcome {
        await withCheckedContinuation { continuation in
            DeleteQueue.queue.async { continuation.resume(returning: emptyBlocking(folders)) }
        }
    }
}

/// Deleting a big folder (or one on a slow network volume) runs here, never on the listing queue.
enum DeleteQueue {
    static let queue = DispatchQueue(label: "kansio.delete", qos: .userInitiated)
}
