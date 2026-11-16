import AppKit
import Darwin
import FileSystemKit

/// Measures main-thread run loop iterations: from waking up to going back to sleep,
/// *including* AppKit layout/drawing and the Core Animation commit (which run as
/// before-waiting observers). Anything over 16 ms drops a frame at 60 Hz.
///
/// Two observers bracket each iteration: one runs first after waking (lowest order),
/// one runs last before sleeping (highest order, after CA's commit observer).
/// Measurement modes install a hook; app code annotates expensive main-thread steps with it.
@MainActor
enum Trace {
    static var note: ((String) -> Void)?
    /// Runs `body`, noting how long it took (only while a measurement listens).
    static func time<T>(_ label: String, _ body: () -> T) -> T {
        guard let note else { return body() }
        let start = ContinuousClock.now
        defer { note("\(label) \(ms(ContinuousClock.now - start)) ms") }
        return body()
    }
}

@MainActor
final class HitchMonitor {
    private(set) var maxBusy: Duration = .zero
    private(set) var hitchCount = 0
    private var wokeAt: ContinuousClock.Instant?
    private var observers: [CFRunLoopObserver] = []
    private var atIterationEnd: [@MainActor (ContinuousClock.Instant) -> Void] = []
    private var notes: [String] = []
    private let trace = ProcessInfo.processInfo.environment["KANSIO_TRACE"] != nil
    /// Hitch timestamps in traces are relative to this.
    var traceOrigin = ContinuousClock.now

    func start() {
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.wokeAt = .now; self?.wakeups += 1 }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.iterationEnded() }
        }
        for observer in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    func reset() { maxBusy = .zero; hitchCount = 0 }
    /// Main run-loop wake-ups (idle measurement).
    var wakeups = 0

    /// Runs `body` with the time at which the current iteration finished (rows drawn and committed).
    func whenIterationEnds(_ body: @escaping @MainActor (ContinuousClock.Instant) -> Void) {
        atIterationEnd.append(body)
    }

    /// Labels the current iteration in hitch traces (KANSIO_TRACE=1).
    func note(_ text: String) { if trace { notes.append(text) } }

    private func iterationEnded() {
        let now = ContinuousClock.now
        if let wokeAt {
            let busy = now - wokeAt
            maxBusy = max(maxBusy, busy)
            if busy > .milliseconds(16) {
                hitchCount += 1
                if trace { print("hitch: \(ms(busy)) ms [\(notes.joined(separator: ", "))] at \(ms(now - traceOrigin)) ms") }
            }
        }
        wokeAt = nil
        notes.removeAll()
        let pending = atIterationEnd
        atIterationEnd.removeAll()
        for body in pending { body(now) }
    }
}

/// Runs a scripted measurement in the real app, prints results to stdout, then quits.
///
///   Kansio --measure-launch            process start → home rows drawn / fully listed
///   Kansio --measure-open <folder>     home → folder, 7×: first rows drawn / full list drawn
@MainActor
final class MeasurementRunner {
    enum Mode {
        case launch
        case open(URL, repeats: Int)
        /// Copy a fixtures folder to a scratch folder next to it (cloning off), measuring UI responsiveness.
        case copy(URL)
        /// Show an empty scratch folder while "another app" creates and then deletes 1,000 files in it.
        case live(URL)
        /// Select all / change the selection in a big folder and time the status bar updates.
        case status(URL)
        /// Render the visible part of the list to a PNG once the folder is listed, then quit.
        case snapshot(URL, output: URL)
        /// Scroll through `URL` at a constant speed, one step per display frame, and report
        /// late frames (a frame is "dropped" when the next callback comes > 1.5 frames later).
        case scroll(URL, pointsPerSecond: CGFloat, duration: Duration)
        /// Navigation-pane tree (P1-1): deep reveal, expanding wide-10k, scrolling it with subfolder
        /// checks, a 1,000-folder live burst, and a 10,000-file copy under a watched root.
        case tree(URL)
        /// Tabs (P1-3): open 20 tabs, switch through them (cost, no re-lists), then idle CPU.
        case tabs(URL)
        /// Drag and drop (P1-4) of every item in flat-10k: the parts Kansio does on the main thread.
        case drag(URL)
        /// Search (P1-5): keystrokes in flat-100k, a search of the whole fixtures tree, cancelling one.
        case search(URL)
        /// Folder sizes (P1-6): the fixtures root (flat-100k, wide-10k …) and wide-10k's 10,000 subfolders
        /// sorted by size; coming back (cache); cancelling by navigating away.
        case sizes(URL)
    }

    private let mode: Mode
    private let fileList: FileListViewController
    private let sidebar: SidebarViewController
    /// Where `--measure-open` returns between runs (KANSIO_MEASURE_HOME overrides, e.g. to start from a full folder).
    private let home = ProcessInfo.processInfo.environment["KANSIO_MEASURE_HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) } ?? FileManager.default.homeDirectoryForCurrentUser
    private let hitches = HitchMonitor()
    private var firstRows: [Duration] = []
    private var complete: [Duration] = []
    private var maxApply: Duration = .zero
    private var maxHitch: Duration = .zero
    private var hitchCount = 0
    private var runs = 0
    private var inTarget = false
    private var sawFirstForGeneration = -1

    init(mode: Mode, window: MainWindowController) {
        self.mode = mode
        fileList = window.fileList
        sidebar = window.sidebar
        hitches.start()
        sidebar.traceNote = { [weak hitches] note in hitches?.note(note) }
        Trace.note = { [weak hitches] note in hitches?.note(note) }
        fileList.onDisplay = { [weak self] event in self?.handle(event) }
        // The startup folder may already be applied (StartupPrefetch) before we attached.
        if let event = fileList.lastDisplayEvent { handle(event) }
    }

    private var scrollDriver: ScrollDriver?
    private var snapshotTabsOpened = false
    private var copyStarted = false

    /// Status bar responsiveness: Select All (big selections are summed off-main) and 20 single
    /// selection changes; reports time until the final text and the worst main-thread iteration.
    private func runStatusMeasurement() {
        let list = fileList
        let table = list.tableForTesting
        let label = list.statusBar.selectionLabel
        hitches.reset()
        Task { @MainActor in
            let start = ContinuousClock.now
            table.selectAll(nil)
            let shownAt = ContinuousClock.now // synchronous: count + "Calculating…" (or the size) already set
            while label.stringValue.contains("Calculating") { try? await Task.sleep(for: .milliseconds(1)) }
            let finalAt = ContinuousClock.now
            print("select_all rows=\(table.numberOfRows) status_text=\"\(label.stringValue)\" shown_ms=\(ms(shownAt - start)) size_ms=\(ms(finalAt - start))")
            var worst: Duration = .zero
            for i in 0..<20 {
                let t = ContinuousClock.now
                table.selectRowIndexes([i * 997 % table.numberOfRows], byExtendingSelection: false)
                worst = max(worst, ContinuousClock.now - t)
                try? await Task.sleep(for: .milliseconds(20))
            }
            print("single_selection_update_worst_ms=\(ms(worst)) status_text=\"\(label.stringValue)\" max_main_thread_busy_ms=\(ms(self.hitches.maxBusy)) hitches_over_16ms=\(self.hitches.hitchCount)")
            self.finish(nil)
        }
    }

    /// Another process creates 1,000 files in the folder on screen, then deletes them; reports how
    /// fast the list followed, how it did it (incremental batches vs re-lists) and main-thread hitches.
    private func runLiveMeasurement(_ scratch: URL) {
        guard scratch.path(percentEncoded: false).contains("/kansio-fixtures/") else { return finish("refusing: not in the fixtures") }
        hitches.reset()
        let dir = scratch.path(percentEncoded: false)
        let list = fileList
        Task { @MainActor in
            @MainActor func waitFor(_ count: Int) async -> Duration? {
                let start = ContinuousClock.now
                while list.state.itemCount != count {
                    if ContinuousClock.now - start > .seconds(10) { return nil }
                    try? await Task.sleep(for: .milliseconds(2))
                }
                return ContinuousClock.now - start
            }
            if ProcessInfo.processInfo.environment["KANSIO_LIVE_WARMUP"] != nil {
                FileManager.default.createFile(atPath: "\(dir)/warmup.txt", contents: nil)
                _ = await waitFor(1)
                unlink("\(dir)/warmup.txt")
                _ = await waitFor(0)
                self.hitches.reset()
            }
            let createStart = ContinuousClock.now
            Task.detached { for i in 0..<1000 { FileManager.default.createFile(atPath: "\(dir)/live-\(i).txt", contents: Data("x".utf8)) } }
            let created = await waitFor(1000).map { _ in ContinuousClock.now - createStart }
            let batchesAfterCreate = list.liveBatchesApplied
            let deleteStart = ContinuousClock.now
            Task.detached { for i in 0..<1000 { unlink("\(dir)/live-\(i).txt") } }
            let deleted = await waitFor(0).map { _ in ContinuousClock.now - deleteStart }
            print("create_1000_reflected_ms=\(created.map(ms) ?? "timeout") delete_1000_reflected_ms=\(deleted.map(ms) ?? "timeout")")
            print("live_batches=\(batchesAfterCreate)+\(list.liveBatchesApplied - batchesAfterCreate) relists=\(list.liveRelists) max_main_thread_busy_ms=\(ms(self.hitches.maxBusy)) hitches_over_16ms=\(self.hitches.hitchCount)")
            try? FileManager.default.removeItem(at: scratch)
            self.finish(created == nil || deleted == nil ? "live update didn't converge" : nil)
        }
    }

    /// Copies `source` (must be inside the fixtures) to a scratch folder and reports how the UI held up.
    private func runCopyMeasurement(_ source: URL) {
        let sourcePath = source.standardizedFileURL.path(percentEncoded: false)
        guard sourcePath.contains("/kansio-fixtures/") else { return finish("refusing: --measure-copy only works on fixtures") }
        let scratch = source.deletingLastPathComponent().appending(path: "scratch-measure-copy-\(getpid())", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let center = OperationCenter.shared
        center.traceNote = { [weak self] note in self?.hitches.note(note) }
        center.allowClone = false // measure the real copy path, not an instant clone
        hitches.reset()
        let start = ContinuousClock.now
        hitches.traceOrigin = start
        var panelSeen = false
        let trace = ProcessInfo.processInfo.environment["KANSIO_TRACE"] != nil
        let watch = Task { @MainActor in
            while !Task.isCancelled {
                if center.isPanelVisible && !panelSeen {
                    panelSeen = true
                    if trace { print("panel visible at \(ms(ContinuousClock.now - start)) ms") }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        center.start(.copy, sources: [source], destination: scratch, trasher: SystemTrasher(),
                     prompter: ConflictPrompter(window: fileList.view.window)) { [weak self] result in
            guard let self else { return }
            watch.cancel()
            let elapsed = ContinuousClock.now - start
            print("copy_ms=\(ms(elapsed)) items=\(result.progress.completedItems)/\(result.progress.totalItems) bytes=\(result.progress.completedBytes) errors=\(result.errors.count)")
            print("panel_shown=\(panelSeen) progress_updates=\(center.progressUpdates) max_main_thread_busy_ms=\(ms(self.hitches.maxBusy)) hitches_over_16ms=\(self.hitches.hitchCount)")
            try? FileManager.default.removeItem(at: scratch) // our own scratch copy, inside the fixtures
            self.finish(nil)
        }
    }

    private func handle(_ event: FileListViewController.DisplayEvent) {
        if case .launch = mode, sawFirstForGeneration == -1 { LaunchTrace.mark("first rows applied (\(ms(event.mainThreadApply)) ms)") }
        hitches.note("apply \(event.rowCount) rows: \(ms(event.mainThreadApply)) ms")
        let isFirst = sawFirstForGeneration != event.generation
        sawFirstForGeneration = event.generation
        hitches.whenIterationEnds { [weak self] drawnAt in self?.drawn(event, isFirst: isFirst, at: drawnAt) }
    }

    private func drawn(_ event: FileListViewController.DisplayEvent, isFirst: Bool, at drawnAt: ContinuousClock.Instant) {
        switch mode {
        case .status:
            guard event.isComplete, !copyStarted else { return }
            copyStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { self.runStatusMeasurement() }
            }

        case .live(let scratch):
            guard event.isComplete, !copyStarted else { return }
            copyStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { self.runLiveMeasurement(scratch) }
            }

        case .copy(let source):
            guard event.isComplete, !copyStarted else { return }
            copyStarted = true
            // Start after launch-time work has settled (as the scroll benchmark does), so the
            // numbers describe the copy, not app start-up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { self.runCopyMeasurement(source) }
            }

        case .snapshot(_, let output):
            guard event.isComplete else { return }
            if let extra = ProcessInfo.processInfo.environment["KANSIO_SNAPSHOT_TABS"], !snapshotTabsOpened,
               let controller = fileList.view.window?.windowController as? MainWindowController {
                snapshotTabsOpened = true
                for path in extra.split(separator: ":") { controller.addTab(at: URL(filePath: String(path), directoryHint: .isDirectory), background: true) }
            }
            if let n = ProcessInfo.processInfo.environment["KANSIO_SNAPSHOT_SELECT"].flatMap(Int.init) {
                fileList.selectFirstRowsForTesting(n)
                if let cell = fileList.firstNameCellForTesting {
                    print("accessibility: role=\(cell.accessibilityRole()?.rawValue ?? "-") value=\(cell.accessibilityValue() ?? "-")")
                }
            }
            if let text = ProcessInfo.processInfo.environment["KANSIO_SNAPSHOT_EDIT"], let window = fileList.view.window,
               let controller = window.windowController as? MainWindowController {
                controller.addressBar.beginEditing()
                controller.addressBar.field.stringValue = text
                controller.addressBar.commit(text)
            }
            // Give per-file icons (loaded off-main) a moment to arrive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                MainActor.assumeIsolated {
                    do {
                        guard let window = self.fileList.view.window else { return self.finish("no window") }
                        if ProcessInfo.processInfo.environment["KANSIO_TRACE"] != nil, let controller = window.windowController as? MainWindowController {
                            let strip = controller.tabStrip
                            print("tabstrip window=\(strip.window != nil) frame=\(strip.convert(strip.bounds, to: nil)) superview=\(String(describing: strip.superview.map { Swift.type(of: $0) })) toolbarVisible=\(window.toolbar?.isVisible ?? false) items=\(window.toolbar?.items.count ?? -1) tabs=\(strip.tabs.map(\.title)) items=\(strip.itemViews.map { "\($0.frame) hidden=\($0.isHidden) layer=\($0.layer != nil)" }) close=\(window.standardWindowButton(.closeButton).map { $0.convert($0.bounds, to: nil) } ?? .zero)")
                        }
                        try WindowSnapshot.render(window, to: output)
                        if let strip = (window.windowController as? MainWindowController)?.tabStrip, strip.window != nil {
                            try? WindowSnapshot.renderPlain(strip, to: output.deletingPathExtension().appendingPathExtension("tabs.png"))
                        }
                        let state = self.fileList.state
                        print("snapshot=\(output.path(percentEncoded: false)) rows=\(event.rowCount) status=\"\(state.summary)\" error=\"\(state.error?.description ?? "")\"")
                        self.finish(nil)
                    } catch {
                        self.finish("\(error)")
                    }
                }
            }

        case .scroll(_, let speed, let duration):
            guard event.isComplete, scrollDriver == nil else { return }
            hitches.reset()
            let driver = ScrollDriver(view: fileList.view, speed: speed, duration: duration) { [weak self] step in
                self?.fileList.scrollForMeasurement(by: step)
            } completion: { [weak self] intervals in
                self?.reportScroll(intervals)
            }
            scrollDriver = driver
            // Start after launch-time work (window activation, menus, input services) has settled,
            // so the numbers describe scrolling, not app startup.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    self.hitches.reset()
                    driver.start()
                }
            }

        case .search(let fixtures):
            guard event.isComplete, !copyStarted else { return }
            copyStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { self.runSearchMeasurement(fixtures) }
            }

        case .drag(let fixtures):
            guard event.isComplete, !copyStarted else { return }
            copyStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { self.runDragMeasurement(fixtures) }
            }

        case .tabs(let fixtures):
            guard event.isComplete, !copyStarted else { return }
            copyStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { self.runTabsMeasurement(fixtures) }
            }

        case .sizes(let fixtures):
            guard event.isComplete, !copyStarted else { return }
            copyStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { self.runSizesMeasurement(fixtures) }
            }

        case .tree(let fixtures):
            guard event.isComplete, !copyStarted else { return }
            copyStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { self.runTreeMeasurement(fixtures) }
            }

        case .launch:
            guard let start = processStartTime() else { return finish("could not read process start time") }
            // Convert "drawn" to wall-clock to compare with the kernel's process start time.
            let sinceLaunch = Duration.seconds(Date().timeIntervalSince(start)) - (ContinuousClock.now - drawnAt)
            if isFirst { LaunchTrace.mark("first rows drawn"); print("launch_to_first_rows_ms=\(ms(sinceLaunch)) rows=\(event.rowCount)") }
            if event.isComplete {
                print("launch_to_complete_ms=\(ms(sinceLaunch)) rows=\(event.rowCount) max_main_thread_busy_ms=\(ms(hitches.maxBusy))")
                finish(nil)
            }

        case .open(let target, let repeats):
            guard inTarget else {
                guard event.isComplete else { return }
                // Home is loaded; go to the target. The first time, wait for launch to settle
                // (the window's first frame would otherwise be counted as a navigation hitch).
                inTarget = true
                let delay: Double = runs == 0 ? 1.0 : 0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated {
                        self.hitches.reset()
                        self.fileList.navigate(to: target)
                    }
                }
                return
            }
            let elapsed = drawnAt - event.navigationStart
            maxApply = max(maxApply, event.mainThreadApply)
            if isFirst { firstRows.append(elapsed) }
            guard event.isComplete else { return }
            complete.append(elapsed)
            maxHitch = max(maxHitch, hitches.maxBusy)
            hitchCount += hitches.hitchCount
            runs += 1
            inTarget = false
            if runs == repeats { return report(target) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.fileList.navigate(to: self.home) } }
        }
    }

    private func reportScroll(_ intervals: [Double]) {
        guard intervals.count > 10 else { return finish("too few frames") }
        let sorted = intervals.sorted()
        let frame = sorted[sorted.count / 2] // nominal frame interval (8.3 ms at 120 Hz, 16.7 at 60 Hz)
        let dropped = intervals.filter { $0 > frame * 1.5 }.count
        func f(_ v: Double) -> String { String(format: "%.2f", v * 1000) }
        if ProcessInfo.processInfo.environment["KANSIO_TRACE"] != nil {
            print("dropped frames at:", intervals.enumerated().filter { $0.element > frame * 1.5 }.map { "#\($0.offset) \(f($0.element)) ms" })
        }
        print("scroll_frames=\(intervals.count) nominal_frame_ms=\(f(frame)) p99_ms=\(f(sorted[sorted.count * 99 / 100])) max_ms=\(f(sorted.last!)) dropped=\(dropped) (\(String(format: "%.2f", Double(dropped) * 100 / Double(intervals.count)))%) max_main_thread_busy_ms=\(ms(hitches.maxBusy))")
        finish(nil)
    }

    private func report(_ target: URL) {
        // The first run includes cold caches (icons, formatters, LaunchServices).
        func median(_ values: [Duration]) -> Duration { values.sorted()[values.count / 2] }
        print("folder=\(target.path(percentEncoded: false)) runs=\(runs) rows=\(fileList.state.itemCount)")
        print("first_rows_ms median=\(ms(median(firstRows))) first_run=\(ms(firstRows[0])) all=\(firstRows.map(ms))")
        print("complete_ms   median=\(ms(median(complete))) first_run=\(ms(complete[0])) all=\(complete.map(ms))")
        print("max_main_thread_apply_ms=\(ms(maxApply)) max_main_thread_busy_ms=\(ms(maxHitch)) hitches_over_16ms=\(hitchCount)")
        finish(nil)
    }

    // MARK: Search (P1-5)

    private func runSizesMeasurement(_ fixtures: URL) {
        let list = fileList
        let settings = ViewSettings.shared
        Task { @MainActor in
            @MainActor func wait(_ limit: Duration = .seconds(120), _ condition: () -> Bool) async -> Bool {
                let start = ContinuousClock.now
                while !condition() {
                    if ContinuousClock.now - start > limit { return false }
                    try? await Task.sleep(for: .milliseconds(1))
                }
                return true
            }
            @MainActor func open(_ url: URL) async -> ContinuousClock.Instant {
                let start = ContinuousClock.now
                list.navigate(to: url)
                _ = await wait { list.hasLoadedOnce && !list.state.isLoading && list.folder.standardizedFileURL.path == url.standardizedFileURL.path }
                return start
            }
            @MainActor func allSizes() async -> Duration? {
                let start = ContinuousClock.now
                guard await wait(.seconds(120), { list.sizeState != nil && list.pendingFolderSizes == 0 && list.folderSizesDuration != nil }) else { return nil }
                return ContinuousClock.now - start
            }
            let away = fixtures.appending(path: "flat-1k", directoryHint: .isDirectory)
            let wide = fixtures.appending(path: "wide-10k", directoryHint: .isDirectory)
            FolderSizeCache.shared.removeAll()
            settings.sort = FileSort(field: .name, ascending: true)

            // 1. The fixtures root: 11 folders, ≈ 125,000 items in all.
            _ = await open(away)
            self.hitches.reset()
            let rootStart = await open(fixtures)
            let rootTime = await allSizes()
            print("sizes_root: folders=\(list.folderSizes.count) measured=\(list.foldersMeasured) all_sizes_ms=\(rootTime.map(ms) ?? "timeout") (from navigation: \(ms(ContinuousClock.now - rootStart))) max_main_thread_busy_ms=\(ms(self.hitches.maxBusy)) hitches_over_16ms=\(self.hitches.hitchCount)")

            // 2. Away and back: every size from the cache, none measured again.
            let folders = list.folderSizes.count
            _ = await open(away)
            self.hitches.reset()
            let backStart = await open(fixtures)
            _ = await wait(.seconds(5)) { list.folderSizes.count == folders && list.sizeState?.realBase.isEmpty == false }
            let back = ContinuousClock.now - backStart
            try? await Task.sleep(for: .milliseconds(800)) // FSEvents replay since the oldest cached size
            print("sizes_back: shown_ms=\(ms(back)) from_cache=\(list.folderSizes.count) measured_again=\(list.foldersMeasured) max_main_thread_busy_ms=\(ms(self.hitches.maxBusy))")

            // 3. 10,000 subfolders sorted by size: re-sorted as sizes arrive.
            settings.sort = FileSort(field: .size, ascending: false)
            self.hitches.reset()
            _ = await open(wide)
            let wideTime = await allSizes()
            print("sizes_wide_10k_sorted_by_size: measured=\(list.foldersMeasured) all_sizes_ms=\(wideTime.map(ms) ?? "timeout") max_main_thread_busy_ms=\(ms(self.hitches.maxBusy)) hitches_over_16ms=\(self.hitches.hitchCount)")
            settings.sort = FileSort(field: .name, ascending: true)

            // 4. Cancel: navigate away while flat-100k is being measured; the size queue must go idle at once.
            FolderSizeCache.shared.removeAll()
            _ = await open(fixtures)
            _ = await wait(.seconds(5)) { list.folderSizes["flat-10k"] != nil } // flat-100k is next (visible order)
            try? await Task.sleep(for: .milliseconds(5))
            let cancelAt = ContinuousClock.now
            _ = await open(away)
            let idle: Duration = await withCheckedContinuation { c in FolderSizeQueue.queue.async { c.resume(returning: ContinuousClock.now - cancelAt) } }
            print("sizes_cancel: size_queue_idle_after_ms=\(ms(idle)) (navigation included)")
            self.finish(nil)
        }
    }

    private func runSearchMeasurement(_ fixtures: URL) {
        let list = fileList
        Task { @MainActor in
            @MainActor func wait(_ limit: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
                let start = ContinuousClock.now
                while !condition() {
                    if ContinuousClock.now - start > limit { return false }
                    try? await Task.sleep(for: .milliseconds(1))
                }
                return true
            }
            // 1. Keystrokes in 100,000 items. ⌘F prepares the folded-name index (as when the field gets focus);
            //    typing starts 200 ms later.
            if ProcessInfo.processInfo.environment["KANSIO_SEARCH_COLD"] == nil { list.prepareSearchIndex() }
            try? await Task.sleep(for: .milliseconds(200))
            var times: [String] = []
            var worst: Duration = .zero
            self.hitches.reset()
            for query in ["r", "re", "rep", "repo", "repor", "report", "report 1", "report 12"] {
                let before = list.searchResultsVersion
                let start = ContinuousClock.now
                list.setSearch(query)
                _ = await wait { list.searchResultsVersion > before }
                let elapsed = ContinuousClock.now - start
                worst = max(worst, elapsed)
                times.append("\(query)=\(ms(elapsed))(\(list.state.itemCount))")
                try? await Task.sleep(for: .milliseconds(30)) // typing speed; the subfolder walk starts only after a pause
            }
            try? await Task.sleep(for: .milliseconds(50))
            print("search_keystrokes_100k: \(times.joined(separator: " "))")
            print("search_keystroke_ms max=\(ms(worst)) max_main_thread_busy_ms=\(ms(self.hitches.maxBusy)) hitches_over_16ms=\(self.hitches.hitchCount)")
            list.endSearch()

            // 2. The whole fixtures tree (≈ 112,000 items in ~3,500 folders).
            list.navigate(to: fixtures)
            _ = await wait { list.hasLoadedOnce && !list.state.isLoading }
            self.hitches.reset()
            let start = ContinuousClock.now
            list.setSearch("level-5")
            var firstDeep: Duration?
            _ = await wait {
                if firstDeep == nil, list.displayedNames.contains(where: { $0.contains("/") }) { firstDeep = ContinuousClock.now - start }
                return list.searchIsComplete
            }
            let total = ContinuousClock.now - start
            try? await Task.sleep(for: .milliseconds(50))
            print("search_tree: query=level-5 first_subfolder_result_ms=\(firstDeep.map(ms) ?? "-") complete_ms=\(ms(total)) found=\(list.state.itemCount) folders=\(list.search?.folders ?? 0) max_main_thread_busy_ms=\(ms(self.hitches.maxBusy)) hitches_over_16ms=\(self.hitches.hitchCount)")
            list.endSearch()

            // 3. Cancel: a broad search ended after 100 ms stops walking.
            let typedAt = ContinuousClock.now
            list.setSearch("e")
            try? await Task.sleep(for: .milliseconds(350)) // 250 ms pause + 100 ms of walking
            let state = list.search
            let cancelAt = ContinuousClock.now
            list.endSearch()
            try? await Task.sleep(for: .milliseconds(300))
            print("search_cancel: ended_after_ms=\(ms(cancelAt - typedAt)) walk_stopped=\(state?.walkCancel?.isCancelled ?? false) folders_walked=\(state?.folders ?? -1) (of ~3,500) rows_restored=\(list.state.itemCount)")
            self.finish(nil)
        }
    }

    // MARK: Drag and drop (P1-4)

    private func runDragMeasurement(_ fixtures: URL) {
        let list = fileList
        let table = list.tableForTesting
        let scratch = fixtures.appending(path: "scratch-drag-\(getpid())", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Task { @MainActor in
            table.selectAll(nil)
            let rows = table.selectedRowIndexes
            // Drag start: one pasteboard writer per row, written to the drag pasteboard (what AppKit does).
            try? await Task.sleep(for: .milliseconds(1))
            var start = ContinuousClock.now
            let writers = rows.compactMap { list.tableView(table, pasteboardWriterForRow: $0) }
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.kansio.measure.drag"))
            pasteboard.clearContents()
            pasteboard.writeObjects(writers)
            let startCost = ContinuousClock.now - start
            start = ContinuousClock.now
            var offset = NSPoint.zero
            let image = table.dragImageForRows(with: rows, tableColumns: [table.tableColumns[0]],
                                               event: NSEvent(), offset: &offset)
            let imageCost = ContinuousClock.now - start
            // Over a drop target: the first validation reads the URLs; later ones (every mouse move) use the cache.
            let other = WindowManager.shared.make(at: scratch)
            other.showWindow(nil)
            _ = await { () async -> Bool in
                let deadline = ContinuousClock.now + .seconds(5)
                while !other.fileList.hasLoadedOnce && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
                return true
            }()
            let target = other.fileList
            // A drag from another app (the pasteboard is read once); then one from Kansio's own list (registered URLs).
            let info = MeasureDrag(pasteboard: pasteboard)
            let localInfo = MeasureDrag(pasteboard: pasteboard, sequence: 4343)
            FileDrop.beginLocalDrag(folder: list.folder, names: list.selectedNames, sequence: 4343)
            var t0 = ContinuousClock.now
            _ = target.tableView(target.tableForTesting, validateDrop: localInfo, proposedRow: 0, proposedDropOperation: .above)
            let localValidate = ContinuousClock.now - t0
            FileDrop.endLocalDrag()
            t0 = .now
            start = ContinuousClock.now
            let firstOp = target.tableView(target.tableForTesting, validateDrop: info, proposedRow: 0, proposedDropOperation: .above)
            let firstValidate = ContinuousClock.now - start
            var later: Duration = .zero
            for _ in 0..<60 { // one per mouse move, each in its own run-loop turn
                let t = ContinuousClock.now
                _ = target.tableView(target.tableForTesting, validateDrop: info, proposedRow: 0, proposedDropOperation: .above)
                later += ContinuousClock.now - t
                try? await Task.sleep(for: .milliseconds(1))
            }
            let laterValidate = later / 60
            // The drop itself: until the copy engine has it (then it runs off-main) — cancelled right away.
            self.hitches.reset()
            start = ContinuousClock.now
            let accepted = target.tableView(target.tableForTesting, acceptDrop: info, row: -1, dropOperation: .above)
            let acceptCost = ContinuousClock.now - start
            try? await Task.sleep(for: .milliseconds(150)) // the off-main check hands the drop to the engine
            OperationCenter.shared.cancelAll()
            try? await Task.sleep(for: .milliseconds(200))
            print("drag_10k: items=\(writers.count) start_ms=\(ms(startCost)) drag_image_ms=\(ms(imageCost)) image=\(Int(image.size.width))x\(Int(image.size.height))")
            print("drop_10k_from_kansio: first_validate_ms=\(ms(localValidate))")
            print("drop_10k_from_another_app: operation=\(firstOp == .move ? "move" : firstOp == .copy ? "copy" : "\(firstOp.rawValue)") first_validate_ms=\(ms(firstValidate)) later_validate_ms=\(ms(laterValidate)) accept_ms=\(ms(acceptCost)) accepted=\(accepted) max_main_thread_busy_ms=\(ms(self.hitches.maxBusy))")
            // Undo whatever moved before the cancel took effect, then clean up the scratch folder.
            FileUndo.shared.manager.undo()
            try? await Task.sleep(for: .milliseconds(500))
            try? FileManager.default.removeItem(at: scratch)
            self.finish(nil)
        }
    }

    // MARK: Tabs (P1-3)

    private func runTabsMeasurement(_ fixtures: URL) {
        guard let first = fileList.view.window, let firstController = first.windowController as? MainWindowController else { return finish("no window") }
        var folders = ["flat-1k", "flat-10k", "deep", "unicode", "symlinks", "hidden", "packages", "long-names", "empty", "wide-10k"]
            .map { fixtures.appending(path: $0, directoryHint: .isDirectory) }
        var deep = fixtures.appending(path: "deep", directoryHint: .isDirectory)
        for i in 1...9 { deep.append(path: String(format: "level-%02d", i), directoryHint: .isDirectory); folders.append(deep) }
        Task { @MainActor in
            @MainActor func wait(_ limit: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
                let start = ContinuousClock.now
                while !condition() {
                    if ContinuousClock.now - start > limit { return false }
                    try? await Task.sleep(for: .milliseconds(1))
                }
                return true
            }
            // 19 more tabs (20 with the first), each shown once so it has listed its folder.
            var tabs = [firstController.fileList]
            let count = ProcessInfo.processInfo.environment["KANSIO_TABS"].flatMap(Int.init) ?? 20
            for folder in folders.prefix(max(0, count - 1)) {
                let tab = firstController.addTab(at: folder)
                tabs.append(tab)
                _ = await wait { tab.hasLoadedOnce && !tab.state.isLoading }
            }
            try? await Task.sleep(for: .seconds(1))
            let listingsBefore = tabs.map(\.listingsStarted).reduce(0, +)

            // Switch through every tab twice.
            var switches: [Duration] = []
            self.hitches.reset()
            for _ in 0..<2 {
                for (index, tab) in tabs.enumerated() {
                    let start = ContinuousClock.now
                    self.hitches.note("switch to \(tab.folder.lastPathComponent) (\(tab.state.itemCount) rows)")
                    firstController.selectTab(at: index)
                    try? await Task.sleep(for: .milliseconds(1)) // the frame that shows it
                    switches.append(ContinuousClock.now - start)
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
            let relists = tabs.map(\.listingsStarted).reduce(0, +) - listingsBefore
            let sorted = switches.sorted()
            let activeTabs = tabs.filter(\.isActive).count
            let watchers = tabs.filter(\.isWatching).count
            print("pause_resume_ms_per_switch=\(ms(MainWindowController.activityTime / max(1, MainWindowController.activityUpdates))) (Kansio's own work in a switch)")
            print("tabs=\(tabs.count) switches=\(switches.count) switch_ms median=\(ms(sorted[sorted.count / 2])) max=\(ms(sorted.last!)) relists=\(relists) active_tabs=\(activeTabs) list_watchers=\(watchers) max_main_thread_busy_ms=\(ms(self.hitches.maxBusy)) hitches_over_16ms=\(self.hitches.hitchCount)")

            // Idle: CPU time of the whole process over 5 s with 20 tabs open.
            // After 40 rapid switches AppKit/the window server settle for several seconds; measure after that.
            try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["KANSIO_IDLE_WAIT"] ?? "") ?? 10))
            func cpu() -> Double {
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
            }
            let cpuStart = cpu()
            let wallStart = ContinuousClock.now
            let wakeupsStart = self.hitches.wakeups
            let activityStart = MainWindowController.activityUpdates
            try? await Task.sleep(for: .seconds(5))
            let cpuMs = cpu() - cpuStart
            var threads: mach_msg_type_number_t = 0
            var list: thread_act_array_t?
            task_threads(mach_task_self_, &list, &threads)
            print("idle_detail: main_wakeups=\(self.hitches.wakeups - wakeupsStart) activity_updates=\(MainWindowController.activityUpdates - activityStart) threads=\(threads)")
            let wall = ContinuousClock.now - wallStart
            print("idle_20_tabs: cpu_ms=\(String(format: "%.1f", cpuMs)) over_ms=\(ms(wall)) cpu_percent=\(String(format: "%.3f", cpuMs / (Double(wall.components.seconds) * 1000 + Double(wall.components.attoseconds) / 1e15) * 100))")
            self.finish(nil)
        }
    }

    // MARK: Navigation-pane tree (P1-1)

    private func runTreeMeasurement(_ fixtures: URL) {
        guard fixtures.path(percentEncoded: false).contains("kansio-fixtures") else { return finish("refusing: not the fixtures") }
        let sidebar = self.sidebar, outline = sidebar.outlineView, list = fileList, tree = sidebar.tree
        func norm(_ url: URL) -> String { FolderTreeIO.normalizedPath(url.standardizedFileURL.path(percentEncoded: false)) }
        func node(_ url: URL) -> TreeNode? {
            guard let (root, names) = tree.revealTarget(for: url) else { return nil }
            var node = root
            for name in names {
                guard let child = node.allChildren?.first(where: { $0.name == name }) else { return nil }
                node = child
            }
            return node
        }
        Task { @MainActor in
            @MainActor func wait(_ limit: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
                let start = ContinuousClock.now
                while !condition() {
                    if ContinuousClock.now - start > limit { return false }
                    try? await Task.sleep(for: .milliseconds(1))
                }
                return true
            }
            @MainActor func navigateAndReveal(_ url: URL) async -> (list: ContinuousClock.Instant?, reveal: ContinuousClock.Instant?, start: ContinuousClock.Instant) {
                var revealed: ContinuousClock.Instant?
                sidebar.onRevealFinished = { revealedURL, reached in if reached, norm(revealedURL) == norm(url) { revealed = .now } }
                let start = ContinuousClock.now
                list.navigate(to: url)
                var listed: ContinuousClock.Instant?
                _ = await wait { if norm(list.folder) == norm(url), let e = list.lastDisplayEvent, e.isComplete, e.generation == list.currentGeneration { listed = listed ?? .now }; return listed != nil && revealed != nil }
                sidebar.onRevealFinished = nil
                return (listed, revealed, start)
            }
            _ = await wait(.seconds(5)) { sidebar.selectedNode.map { norm($0.url) } == norm(fixtures) }

            // 1. Reveal 10 levels deep (cold: nothing listed below the fixtures yet; then warm).
            var deep = fixtures.appending(path: "deep", directoryHint: .isDirectory)
            for i in 1...10 { deep.append(path: String(format: "level-%02d", i), directoryHint: .isDirectory) }
            for label in ["cold", "warm", "warm"] {
                self.hitches.reset()
                let r = await navigateAndReveal(deep)
                guard let listed = r.list, let revealed = r.reveal else { return self.finish("reveal didn't finish") }
                try? await Task.sleep(for: .milliseconds(50)) // the frame that finished it counts too
                let after = revealed > listed ? revealed - listed : .zero
                print("tree_reveal_deep_\(label): after_list_ms=\(ms(after)) from_navigation_ms=\(ms(revealed - r.start)) max_main_thread_busy_ms=\(ms(self.hitches.maxBusy)) hitches_over_16ms=\(self.hitches.hitchCount)")
                _ = await navigateAndReveal(fixtures)
                try? await Task.sleep(for: .milliseconds(300))
            }

            // 2. Expand a node with 10,000 subfolders (by hand).
            guard let wide = node(fixtures.appending(path: "wide-10k")) else { return self.finish("wide-10k not in the tree (run Tools/make-fixtures.sh)") }
            if let fixturesNode = node(fixtures), !outline.isItemExpanded(fixturesNode) { outline.expandItem(fixturesNode) }
            outline.scrollRowToVisible(outline.row(forItem: wide))
            _ = await wait(.seconds(5)) { outline.isExpandable(wide) } // its triangle (background check) is in
            try? await Task.sleep(for: .milliseconds(300))
            self.hitches.reset()
            let expandStart = ContinuousClock.now
            outline.expandItem(wide)
            var firstVisible: Duration?
            _ = await wait {
                if firstVisible == nil, let first = wide.children.first, outline.row(forItem: first) >= 0 { firstVisible = ContinuousClock.now - expandStart }
                return outline.numberOfChildren(ofItem: wide) == 10_000
            }
            let expandAll = ContinuousClock.now - expandStart
            try? await Task.sleep(for: .milliseconds(50))
            print("tree_expand_10k: first_children_ms=\(firstVisible.map(ms) ?? "-") complete_ms=\(ms(expandAll)) max_main_thread_busy_ms=\(ms(self.hitches.maxBusy)) hitches_over_16ms=\(self.hitches.hitchCount)")

            // 3. Scroll through it while rows on screen are checked for subfolders.
            if let row = Optional(outline.row(forItem: wide)), row >= 0 { outline.scrollRowToVisible(row) }
            try? await Task.sleep(for: .milliseconds(300))
            self.hitches.reset()
            self.hitches.traceOrigin = .now
            // The first iteration creates the display link (harness cost, not scrolling): count from the next one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { self.hitches.reset() } }
            let intervals: [Double] = await withCheckedContinuation { continuation in
                let driver = ScrollDriver(view: outline, speed: 3000, duration: .seconds(3)) { step in
                    guard let scroll = outline.enclosingScrollView else { return }
                    let clip = scroll.contentView
                    let y = min(clip.bounds.origin.y + step, max(0, outline.frame.height - clip.bounds.height))
                    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                    scroll.reflectScrolledClipView(clip)
                } completion: { intervals in continuation.resume(returning: intervals) }
                self.scrollDriver = driver
                driver.start()
            }
            if ProcessInfo.processInfo.environment["KANSIO_TRACE"] != nil { print("scroll ended at \(ms(.now - self.hitches.traceOrigin)) ms") }
            let checked = wide.children.filter { $0.hasSubfolders != nil }.count
            let frame = intervals.sorted()[intervals.count / 2]
            let late = intervals.filter { $0 > frame * 1.5 }.count
            print("tree_scroll_10k: frames=\(intervals.count) frame_ms=\(String(format: "%.2f", frame * 1000)) dropped=\(late) checked_rows=\(checked) max_main_thread_busy_ms=\(ms(self.hitches.maxBusy)) hitches_over_16ms=\(self.hitches.hitchCount)")
            try? await Task.sleep(for: .milliseconds(300))
            self.hitches.reset()
            outline.scrollRowToVisible(outline.row(forItem: wide)) // jump back 10,000 rows (a screenful of new rows)
            try? await Task.sleep(for: .milliseconds(100))
            print("tree_jump_scroll: max_main_thread_busy_ms=\(ms(self.hitches.maxBusy)) hitches_over_16ms=\(self.hitches.hitchCount)")
            try? await Task.sleep(for: .milliseconds(300))
            self.hitches.reset()
            let collapseStart = ContinuousClock.now
            outline.collapseItem(wide)
            _ = await wait { !outline.isItemExpanded(wide) }
            let collapseTime = ContinuousClock.now - collapseStart
            try? await Task.sleep(for: .milliseconds(200))
            print("tree_collapse_10k: collapsed_ms=\(ms(collapseTime)) max_main_thread_busy_ms=\(ms(self.hitches.maxBusy)) hitches_over_16ms=\(self.hitches.hitchCount)")

            // 4. Another process creates and then deletes 1,000 folders in an expanded node.
            let scratch = fixtures.appending(path: "scratch-tree-live-\(getpid())", directoryHint: .isDirectory)
            // One subfolder to begin with: an empty folder has no triangle and can't be expanded.
            try? FileManager.default.createDirectory(at: scratch.appending(path: "seed"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            if let fixturesNode = node(fixtures), !outline.isItemExpanded(fixturesNode) { outline.expandItem(fixturesNode) } // its rows get checked
            guard await wait(.seconds(5), { node(scratch) != nil }), let scratchNode = node(scratch) else { return self.finish("scratch folder didn't appear in the tree") }
            outline.scrollRowToVisible(outline.row(forItem: scratchNode))
            _ = await wait(.seconds(5)) { scratchNode.hasSubfolders == true || outline.isExpandable(scratchNode) }
            outline.expandItem(scratchNode)
            _ = await wait { scratchNode.isListed }
            try? await Task.sleep(for: .milliseconds(300))
            self.hitches.reset()
            let dir = scratch.path(percentEncoded: false)
            let createStart = ContinuousClock.now
            Task.detached { for i in 0..<1000 { mkdir("\(dir)/live-\(i)", 0o755) } }
            let created = await wait { scratchNode.children.count == 1001 }
            let createTime = ContinuousClock.now - createStart
            let deleteStart = ContinuousClock.now
            Task.detached { for i in 0..<1000 { rmdir("\(dir)/live-\(i)") } }
            let deleted = await wait { scratchNode.children.count == 1 }
            let deleteTime = ContinuousClock.now - deleteStart
            try? await Task.sleep(for: .milliseconds(50))
            print("tree_live_1000: create_reflected_ms=\(created ? ms(createTime) : "timeout") delete_reflected_ms=\(deleted ? ms(deleteTime) : "timeout") expanded=\(outline.isItemExpanded(scratchNode)) max_main_thread_busy_ms=\(ms(self.hitches.maxBusy)) hitches_over_16ms=\(self.hitches.hitchCount)")

            // 5. A 10,000-file copy elsewhere while the "/" stream runs (filtering happens off-main).
            let copyTarget = fixtures.appending(path: "scratch-tree-copy-\(getpid())", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: copyTarget) }
            let batchesBefore = sidebar.watcherBatches
            sidebar.resetWatcherStatistics()
            self.hitches.reset()
            let copyStart = ContinuousClock.now
            let process = Process()
            process.executableURL = URL(filePath: "/bin/cp")
            process.arguments = ["-R", fixtures.appending(path: "flat-10k").path(percentEncoded: false), copyTarget.path(percentEncoded: false)]
            try? process.run()
            _ = await wait(.seconds(120)) { !process.isRunning }
            let copyTime = ContinuousClock.now - copyStart
            try? await Task.sleep(for: .seconds(1)) // trailing events
            let batches = sidebar.watcherBatches - batchesBefore
            print("tree_copy_10k_elsewhere: copy_ms=\(ms(copyTime)) watcher_batches_on_main=\(batches) longest_batch_ms=\(ms(sidebar.longestWatcherBatch)) max_main_thread_busy_ms=\(ms(self.hitches.maxBusy)) hitches_over_16ms=\(self.hitches.hitchCount)")
            self.finish(nil)
        }
    }

    private func finish(_ error: String?) {
        if let error { print("error: \(error)") }
        fflush(stdout)
        exit(error == nil ? 0 : 1)
    }
}

private func ms(_ d: Duration) -> String {
    let c = d.components
    return String(format: "%.1f", Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
}

/// When the kernel started this process (includes dyld and framework loading).
func processStartTime() -> Date? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
    let tv = info.kp_proc.p_un.__p_starttime
    return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
}

/// Drives a constant-speed scroll from a display link (one step per screen refresh) and
/// records the interval between callbacks. A busy main thread shows up as late callbacks.
@MainActor
final class ScrollDriver: NSObject {
    private let view: NSView
    private let speed: CGFloat
    private let duration: Duration
    private let step: (CGFloat) -> Void
    private let completion: ([Double]) -> Void
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var started = ContinuousClock.now
    private var intervals: [Double] = []

    init(view: NSView, speed: CGFloat, duration: Duration, step: @escaping (CGFloat) -> Void, completion: @escaping ([Double]) -> Void) {
        self.view = view
        self.speed = speed
        self.duration = duration
        self.step = step
        self.completion = completion
    }

    func start() {
        started = .now
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if let last {
            let dt = link.timestamp - last
            intervals.append(dt)
            step(speed * CGFloat(dt))
        }
        last = link.timestamp
        if ContinuousClock.now - started >= duration {
            link.invalidate()
            self.link = nil
            completion(intervals)
        }
    }
}

/// Renders a window's tables (header + visible row views, at their on-screen positions) into
/// a PNG (2x) — a screenshot substitute that needs no Screen Recording permission.
/// `cacheDisplay` on the window or a scroll view can't capture NSTableView rows, but it can
/// capture each row view. Title bar, toolbar and vibrancy aren't rendered.
@MainActor
enum WindowSnapshot {
    static func render(_ window: NSWindow, to url: URL) throws {
        guard let content = window.contentView else { return }
        let size = content.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        // The window frame (title bar, traffic lights) as far as it caches; the tab strip is drawn on its own below.
        if ProcessInfo.processInfo.environment["KANSIO_SNAPSHOT_FRAME"] != nil, let frameView = content.superview { draw(frameView) }
        for table in tables(in: content) {
            guard let scroll = table.enclosingScrollView else { continue }
            let clip = scroll.convert(scroll.bounds, to: nil)
            (table.style == .sourceList ? NSColor.underPageBackgroundColor : NSColor.textBackgroundColor).setFill()
            clip.fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: clip).addClip()
            let visible = table.rows(in: table.visibleRect)
            for row in visible.location..<(visible.location + visible.length) {
                guard let rowView = table.rowView(atRow: row, makeIfNecessary: false) else { continue }
                draw(rowView)
            }
            if let header = table.headerView { draw(header) }
            NSGraphicsContext.restoreGraphicsState()
        }
        // Titlebar accessories (the address bar), the tab strip and the status bar: render them as they are.
        for accessory in window.titlebarAccessoryViewControllers { draw(accessory.view) }
        if let strip = (window.windowController as? MainWindowController)?.tabStrip, strip.window != nil { draw(strip) }
        for bar in views(of: StatusBarView.self, in: content) where !bar.isHidden { draw(bar) }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// A plain view hierarchy (no tables) over the window background.
    static func renderPlain(_ content: NSView, to url: URL) throws {
        let size = content.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size // before creating the context, so it draws at 2x
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        if let cached = content.bitmapImageRepForCachingDisplay(in: content.bounds) { // at the image's origin
            content.cacheDisplay(in: content.bounds, to: cached)
            let image = NSImage(size: content.bounds.size)
            image.addRepresentation(cached)
            image.draw(in: NSRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func draw(_ view: NSView) {
        guard let r = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: r)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(r)
        image.draw(in: view.convert(view.bounds, to: nil))
    }

    private static func views<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        if let match = view as? T { return [match] }
        return view.subviews.flatMap { views(of: type, in: $0) }
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap { tables(in: $0) }
    }
}

/// The drag info a drop target sees while 10,000 files from another window are dragged over it.
@MainActor
final class MeasureDrag: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSequenceNumber: Int
    init(pasteboard: NSPasteboard, sequence: Int = 4242) { draggingPasteboard = pasteboard; draggingSequenceNumber = sequence }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy } // copy: undoable by trashing, never touches the fixtures
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
