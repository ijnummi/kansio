import AppKit
import FileSystemKit

/// P1-6: folder sizes in the Size column, computed in the background.
///
/// - Once a folder is listed, its subfolders (and packages) are measured one at a time on their own
///   queue — visible rows first — with `ItemStatistics` (lstat: symlinks never followed, hard links
///   once, no crossing into other volumes). Navigating away, a hidden tab, or a search stops it.
/// - Results go into `FolderSizeCache` (app-wide, by real path), so coming back shows them at once;
///   a recursive directory-level FSEvents stream started *since* the oldest cached result replays
///   what changed meanwhile and keeps them current — only folders that changed are measured again.
/// - Sorting by Size uses the known folder sizes; the status bar adds them to the selection's size.
/// - On by default for local volumes; network volumes only with their own setting.
extension FileListViewController {
    @MainActor
    final class SizeState {
        var sizes: [String: Int64] = [:]
        /// FSEvents id taken before each folder's size was measured (cached or this visit).
        var measuredAt: [String: UInt64] = [:]
        var queue: [String] = []
        var queued: Set<String> = []
        let cancel = CancellationFlag()
        var worker: Task<Void, Never>?
        var watcher: TreeWatcher?
        var realBase = ""
        /// Subfolders that are themselves privacy-protected (Desktop… seen from the home folder): no size.
        var protected: Set<String> = []
        /// The folder being measured now (cancelled when this state stops).
        var walk: Walk?
        /// Never download evicted iCloud folders; protected folders only with Full Disk Access (no prompts).
        var options = ItemStatistics.Options(skipDataless: true)
        var resortTask: Task<Void, Never>?
        /// Folders measured (not from the cache) — self-test / measurement.
        var measured = 0
        var started = ContinuousClock.now
        var finished: ContinuousClock.Instant?
    }

    var folderSizes: [String: Int64] { sizeState?.sizes ?? [:] }
    /// Folders still waiting to be measured (0 = all sizes known).
    var pendingFolderSizes: Int { sizeState.map { $0.queue.count + ($0.worker == nil ? 0 : 1) } ?? 0 }
    var foldersMeasured: Int { sizeState?.measured ?? 0 }
    var folderSizesDuration: Duration? { sizeState.flatMap { s in s.finished.map { $0 - s.started } } }

    var folderSizesEnabled: Bool {
        guard settings.folderSizes else { return false }
        let path = folder.path(percentEncoded: false)
        let volume = mountedVolumes.filter { $0.contains(path: path) }.max { $0.url.path.count < $1.url.path.count }
        return volume?.isNetwork != true || settings.folderSizesOnNetwork
    }

    /// Starts (or restarts) measuring this folder's subfolders.
    func startFolderSizes() {
        stopFolderSizes()
        guard folderSizesEnabled, isActive, !isSearching, !isShowingTrash, !isShowingArchive, hasLoadedOnce else { refreshRows(oldCount: rows.count); return }
        let state = SizeState()
        sizeState = state
        let names = folderNames()
        let base = folder.path(percentEncoded: false)
        Task { [weak self] in
            let (realBase, options) = await Task.detached { () -> (String, ItemStatistics.Options) in
                let real = FolderTreeIO.realPath(base) ?? FolderTreeIO.normalizedPath(base)
                return (real, ItemStatistics.Options(skipDataless: true, skipping: Privacy.automaticSkips(browsing: real)))
            }.value
            guard let self, self.sizeState === state else { return }
            state.realBase = realBase
            state.options = options
            if state.worker == nil, !state.queue.isEmpty { self.runWorker(state) } // queued by a live change meanwhile
            // Known sizes at once (cache); the oldest of them decides how far back FSEvents replays.
            var oldest: UInt64?
            for name in names {
                if let entry = FolderSizeCache.shared.entry(realBase + "/" + name) {
                    state.sizes[name] = entry.totals.bytes
                    state.measuredAt[name] = entry.eventID
                    oldest = min(oldest ?? entry.eventID, entry.eventID)
                }
            }
            self.enqueue(names.filter { state.sizes[$0] == nil }, in: state)
            self.refreshRows(oldCount: self.rows.count)
            self.scheduleSizeResort(state)
            let watcher = TreeWatcher(rootPath: base, changes: { [weak self] changes in
                Task { @MainActor in self?.sizeChanges(changes, state: state) }
            }, rescan: { [weak self] path in
                Task { @MainActor in self?.sizeRescan(path, state: state) }
            })
            state.watcher = watcher
            watcher.start(latency: 0.3, since: oldest)
        }
    }

    func stopFolderSizes() {
        guard let state = sizeState else { return }
        state.cancel.cancel()
        state.walk?.cancel.cancel()
        state.worker?.cancel()
        state.resortTask?.cancel()
        state.watcher?.stop()
        sizeState = nil
    }

    /// The folder's items changed (live update, own operation, hidden files shown): measure new folders.
    func folderSizesModelChanged() {
        guard let state = sizeState else { return }
        let names = Set(folderNames())
        for gone in state.sizes.keys where !names.contains(gone) { state.sizes[gone] = nil }
        enqueue(names.filter { state.sizes[$0] == nil && !state.queued.contains($0) }.sorted(), in: state)
    }

    func folderSizeSettingChanged() {
        if folderSizesEnabled { startFolderSizes() } else { stopFolderSizes(); refreshRows(oldCount: rows.count) }
    }

    /// Subfolders and packages shown in this view (symlinks to folders aren't measured).
    private func folderNames() -> [String] {
        let hidden = settings.showHidden
        return contents.items.filter { $0.kind == .directory && (hidden || !$0.isHidden) }.map(\.name)
    }

    /// Adds names to the queue — visible rows first — and starts the worker if it's idle.
    private func enqueue(_ names: [String], in state: SizeState) {
        guard !names.isEmpty else { return }
        let wanted = Set(names)
        let visible = tableView.rows(in: tableView.visibleRect)
        var first: [String] = []
        if visible.length > 0 {
            for row in visible.location..<min(visible.location + visible.length, rows.count) where wanted.contains(rows[row].name) {
                first.append(rows[row].name)
            }
        }
        let firstSet = Set(first)
        for name in first + names.filter({ !firstSet.contains($0) }) where state.queued.insert(name).inserted {
            state.queue.append(name)
        }
        state.finished = nil
        if state.worker == nil, !state.realBase.isEmpty { runWorker(state) } // else started once the path is resolved
    }

    private func runWorker(_ state: SizeState) {
        let base = URL(filePath: state.realBase, directoryHint: .isDirectory) // the skip list uses real paths
        let watchdog = Self.startWatchdog(state)
        state.worker = Task { [weak self] in
            defer { watchdog.cancel() }
            while let self, self.sizeState === state, !state.cancel.isCancelled, !state.queue.isEmpty {
                let name = state.queue.removeFirst()
                state.queued.remove(name)
                let url = base.appending(path: name, directoryHint: .isDirectory)
                if state.options.skipping.contains(FolderTreeIO.normalizedPath(url.path(percentEncoded: false))) {
                    state.protected.insert(name) // measuring it could raise a privacy prompt
                    self.refreshSize(of: name)
                    continue
                }
                guard let (totals, since) = await Self.measure(url, state: state) else {
                    guard self.sizeState === state, !state.cancel.isCancelled else { break }
                    state.protected.insert(name) // stuck (a prompt, a hung volume): given up, no size
                    self.refreshSize(of: name)
                    continue
                }
                guard self.sizeState === state else { break }
                FolderSizeCache.shared.store(.init(totals: totals, eventID: since), for: state.realBase + "/" + name)
                state.sizes[name] = totals.bytes
                state.protected.remove(name)
                state.measuredAt[name] = since
                state.measured += 1
                self.refreshSize(of: name)
                self.scheduleSizeResort(state)
            }
            guard let self, self.sizeState === state else { return }
            state.worker = nil
            if state.queue.isEmpty, !state.realBase.isEmpty {
                state.finished = .now
                self.updateStatusBar()
            }
        }
    }

    /// One folder's walk in progress (the watchdog's view of it).
    final class Walk {
        let cancel = CancellationFlag()
        let counter = ProgressCounter()
        let once = ResumeOnce<(ItemStatistics.Totals, UInt64)?>()
        let queue: DispatchQueue
        var lastValue = -1
        var lastChange = ContinuousClock.now
        init(queue: DispatchQueue) { self.queue = queue }
    }

    /// Measures one folder on the size queue; nil when cancelled or given up by the watchdog.
    private static func measure(_ url: URL, state: SizeState) async -> (ItemStatistics.Totals, UInt64)? {
        let walk = Walk(queue: FolderSizeQueue.current)
        var configured = state.options
        configured.counter = walk.counter
        let options = configured
        let cancel = walk.cancel, once = walk.once
        let stall = FolderSizeQueue.testStall == url.lastPathComponent
        state.walk = walk
        defer { if state.walk === walk { state.walk = nil } }
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            walk.queue.async {
                let since = FolderWatcher.currentEventID // before measuring: a change during it invalidates
                if stall { Thread.sleep(forTimeInterval: 5) } // self-test: a walk blocked in a syscall
                let totals = ItemStatistics.measure([url], options: options, cancel: cancel)
                once.resume(cancel.isCancelled ? nil : (totals, since))
            }
        }
    }

    /// Gives up a walk that made no progress for `FolderSizeQueue.stallLimit` — blocked in a syscall (a privacy
    /// prompt waiting for an answer, a hung network volume). Its thread is abandoned (it stops once the call
    /// returns: its cancel flag is set) and later folders use a new queue, so one stuck folder never stalls the rest.
    private static func startWatchdog(_ state: SizeState) -> Task<Void, Never> {
        Task { @MainActor [weak state] in
            while !Task.isCancelled, let state {
                guard let walk = state.walk else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                let value = walk.counter.value
                if value != walk.lastValue {
                    walk.lastValue = value
                    walk.lastChange = .now
                } else if ContinuousClock.now - walk.lastChange > FolderSizeQueue.stallLimit {
                    walk.cancel.cancel()
                    if FolderSizeQueue.current === walk.queue { FolderSizeQueue.replace() }
                    walk.once.resume(nil)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// FSEvents (replayed since the oldest cached size, then live): a change inside a subfolder that's
    /// newer than its measurement invalidates it (and the cache's entries for its ancestors); it's measured
    /// again. Changes older than a measurement are already in it (the replay starts at the oldest one).
    private func sizeChanges(_ changes: [String: UInt64], state: SizeState) {
        guard sizeState === state, !state.realBase.isEmpty else { return }
        let dropped = FolderSizeCache.shared.invalidate(changedAt: changes)
        let prefix = state.realBase == "/" ? "/" : state.realBase + "/"
        var affected = Set<String>()
        for (path, id) in changes where path.hasPrefix(prefix) {
            guard let name = path.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).first.map(String.init) else { continue }
            // Shown sizes not from the cache (measured this visit) are compared by their own measurement.
            if dropped.contains(prefix + name) || state.measuredAt[name].map({ $0 < id }) ?? false { affected.insert(name) }
        }
        requeue(affected, in: state)
    }

    private func sizeRescan(_ path: String, state: SizeState) {
        guard sizeState === state else { return }
        FolderSizeCache.shared.invalidate(subtree: path)
        requeue(Set(state.sizes.keys), in: state)
    }

    private func requeue(_ names: Set<String>, in state: SizeState) {
        let shown = Set(folderNames())
        let stale = names.filter { shown.contains($0) && !state.queued.contains($0) }
        enqueue(Array(stale).sorted(), in: state) // old size stays shown until the new one arrives
    }

    private func refreshSize(of name: String) {
        guard let column = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == FileSort.Field.size.rawValue }) else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<min(visible.location + visible.length, rows.count) where rows[row].name == name {
            if let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? FileCellView {
                configure(cell, column: tableView.tableColumns[column], item: rows[row])
            }
        }
        if !tableView.selectedRowIndexes.isEmpty { updateStatusBar() }
    }

    /// Sorted by Size: re-order as sizes arrive, at most every 0.4 s.
    private func scheduleSizeResort(_ state: SizeState) {
        guard settings.sort.field == .size, state.resortTask == nil else { return }
        state.resortTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, self.sizeState === state else { return }
            state.resortTask = nil
            self.resort()
        }
    }

    /// The Size cell's text for a folder: its size, "…" while it's being counted, nothing when off.
    func folderSizeText(_ item: FileItem) -> String {
        guard let state = sizeState else { return "" }
        if let bytes = state.sizes[item.name] { return Formatters.size.string(fromByteCount: bytes) }
        if state.protected.contains(item.name) { return "" }
        return state.queued.contains(item.name) || state.worker != nil ? "…" : ""
    }
}

/// Folder sizes are measured here, one folder at a time (never on the listing queue: sizes must not
/// delay opening a folder). A walk stuck in a syscall gets its queue replaced (`measureWithWatchdog`).
@MainActor
enum FolderSizeQueue {
    private(set) static var current = DispatchQueue(label: "kansio.sizes", qos: .utility)
    static var stallLimit: Duration = .seconds(3)
    /// Self-test: the folder with this name blocks (as if waiting for a privacy prompt).
    static var testStall: String?
    /// Queues abandoned with a walk stuck on them (measurement / diagnostics).
    private(set) static var abandoned = 0
    static func replace() {
        abandoned += 1
        current = DispatchQueue(label: "kansio.sizes.\(abandoned)", qos: .utility)
    }
}

/// A continuation resumed by whichever comes first (the walk or the watchdog); later resumes are ignored.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var early: [T] = [] // resumed before the continuation was set
    private var finished = false

    func set(_ c: CheckedContinuation<T, Never>) {
        lock.lock()
        if let value = early.first { lock.unlock(); c.resume(returning: value); return }
        continuation = c
        lock.unlock()
    }

    func resume(_ value: T) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        if let c = continuation {
            continuation = nil
            lock.unlock()
            c.resume(returning: value)
        } else {
            early = [value]
            lock.unlock()
        }
    }
}
