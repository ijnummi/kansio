import Darwin
import Foundation

/// Search in a folder and its subfolders (P1-5) — no Spotlight, no index: names are matched as
/// they're listed.
///
/// Matching: every word of the query must appear in the name, ignoring case, diacritics and
/// width ("cafe" finds "Café"). Names are folded once into one byte buffer and searched with
/// `memmem`, so filtering 100,000 names per keystroke costs a few milliseconds.
public enum FolderSearch {
    /// The query as folded words (empty: matches nothing).
    public static func words(_ query: String) -> [[UInt8]] {
        query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }.filter { !$0.isEmpty }
    }

    public static func fold(_ string: String) -> [UInt8] {
        Array(string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).utf8)
    }

    /// True if `folded` contains every word.
    public static func matches(_ folded: UnsafeRawBufferPointer, _ words: [[UInt8]]) -> Bool {
        guard !words.isEmpty, let base = folded.baseAddress else { return false }
        for word in words {
            let found = word.withUnsafeBytes { w in memmem(base, folded.count, w.baseAddress, w.count) != nil }
            if !found { return false }
        }
        return true
    }

    /// Folded names of one folder, built once (off-main) and reused for every keystroke.
    public struct Index: Sendable {
        private let buffer: [UInt8]
        private let offsets: [Int]
        public var count: Int { offsets.count - 1 }

        public init(names: [String]) {
            var buffer: [UInt8] = []
            buffer.reserveCapacity(names.count * 24)
            var offsets = [0]
            offsets.reserveCapacity(names.count + 1)
            for name in names {
                buffer.append(contentsOf: FolderSearch.fold(name))
                offsets.append(buffer.count)
            }
            self.buffer = buffer
            self.offsets = offsets
        }

        /// Indexes (into the names it was built from) of the names containing every word.
        public func matching(_ words: [[UInt8]]) -> [Int] {
            guard !words.isEmpty else { return [] }
            var result: [Int] = []
            buffer.withUnsafeBytes { all in
                for i in 0..<count {
                    let name = UnsafeRawBufferPointer(rebasing: all[offsets[i]..<offsets[i + 1]])
                    if FolderSearch.matches(name, words) { result.append(i) }
                }
            }
            return result
        }
    }

    /// A match below the searched folder: `item.name` is its path relative to that folder ("sub/dir/file.txt").
    public typealias Match = FileItem

    /// Walks the subfolders of `root` (not `root`'s own entries — the caller filters those) breadth-first
    /// and reports matches in batches (blocking: call off the main thread).
    /// - Never follows symlinks, doesn't descend into packages (they're single items) or other volumes.
    /// - Hidden items (and hidden folders' contents) only with `includeHidden`.
    /// - Unreadable folders are skipped and counted.
    /// Returns the number of folders searched and unreadable.
    @discardableResult
    /// P3-7: `filter` (size / date) must match too; with a filter, no words means every name matches.
    public static func searchSubfolders(of root: URL, query: String, includeHidden: Bool, cancel: CancellationFlag,
                                        filter: SearchQuery.Predicate? = nil,
                                        batchInterval: Duration = .milliseconds(60),
                                        onBatch: ([Match]) -> Void) -> (folders: Int, unreadable: Int) {
        let words = words(query)
        let filter = filter.flatMap { $0.isEmpty ? nil : $0 }
        guard !words.isEmpty || filter != nil else { return (0, 0) }
        let rootPath = root.path(percentEncoded: false)
        let base = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var rootStat = stat()
        guard lstat(rootPath, &rootStat) == 0 else { return (0, 1) }
        let device = rootStat.st_dev
        // Start with the root's subfolders.
        var queue: [String] = []
        var head = 0
        var folders = 0, unreadable = 0
        var pending: [Match] = []
        var lastFlush = ContinuousClock.now
        let lister = BulkDirectoryLister()

        func visit(_ relative: String) {
            let path = relative.isEmpty ? rootPath : base + relative
            let prefix = relative.isEmpty ? "" : relative + "/"
            do throws(FileSystemError) {
                try lister.list(URL(filePath: path, directoryHint: .isDirectory)) { batch in
                    for item in batch where includeHidden || !item.isHidden {
                        if !relative.isEmpty, filter?.matches(item) ?? true,
                           words.isEmpty || fold(item.name).withUnsafeBytes({ matches($0, words) }) {
                            var match = item
                            match.name = prefix + item.name
                            pending.append(match)
                        }
                        if item.kind == .directory, !item.isPackage { queue.append(prefix + item.name) }
                    }
                    return !cancel.isCancelled
                }
            } catch {
                unreadable += 1
            }
        }

        visit("") // the root's entries: only to find its subfolders (its own matches are the caller's)
        while head < queue.count, !cancel.isCancelled {
            let relative = queue[head]
            head += 1
            var st = stat()
            guard lstat(base + relative, &st) == 0, st.st_dev == device else { continue } // another volume mounted here
            folders += 1
            visit(relative)
            if !pending.isEmpty, ContinuousClock.now - lastFlush >= batchInterval {
                onBatch(pending)
                pending = []
                lastFlush = .now
            }
        }
        if !pending.isEmpty, !cancel.isCancelled { onBatch(pending) }
        return (folders, unreadable)
    }
}
