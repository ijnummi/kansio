import AppKit
import FileSystemKit
import os

/// The details view: one NSTableView showing the current folder.
///
/// Threading model: everything here runs on the main actor, but it only *applies*
/// results. Listing, name ranking and ordering run in detached tasks; the main thread
/// receives a ready-to-display `[FileItem]` and refreshes only the visible rows in place
/// (see `refreshRows`), so updates cost O(visible rows) with no view churn.
@MainActor
final class FileListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    struct State {
        var folder: URL
        var itemCount: Int
        var selectedCount: Int
        var isLoading: Bool
        var error: FileSystemError?
        var canGoBack = false
        var canGoForward = false
        var canGoUp = false

        @MainActor var summary: String {
            if let error { return error.code == .permissionDenied ? "No permission" : "Unavailable" }
            if isLoading && itemCount == 0 { return "Loading…" }
            let items = "\(Formatters.count.string(from: NSNumber(value: itemCount)) ?? "\(itemCount)") \(itemCount == 1 ? "item" : "items")"
            let selection = selectedCount > 0 ? ", \(selectedCount) selected" : ""
            return items + selection + (isLoading ? " (loading…)" : "")
        }
    }

    /// Fired after rows are on screen; used by the measurement harness.
    struct DisplayEvent {
        let generation: Int
        let rowCount: Int
        let isComplete: Bool
        let navigationStart: ContinuousClock.Instant
        let mainThreadApply: Duration
    }

    var onStateChange: ((State) -> Void)?
    var onDisplay: ((DisplayEvent) -> Void)?
    /// The most recent display event (lets the measurement harness catch one that happened before it attached).
    private(set) var lastDisplayEvent: DisplayEvent?

    private(set) var folder: URL
    /// Back/Forward for this view (one per window/tab).
    private(set) var history: NavigationHistory
    /// Names to select once they appear in the listing (Back/Forward/Up restore the selection).
    var pendingSelection: [String] = []
    var contents = FolderContents.empty
    var rows: [FileItem] = []
    var isLoading = false
    /// True once the current navigation has shown its first batch.
    private var hasFirstUpdate = false
    /// The current folder has been fully listed at least once (live changes apply on top of that).
    var hasLoadedOnce: Bool { hasFirstUpdate && !isLoading }
    private var loadError: FileSystemError?

    /// Incremented per navigation; results from older navigations are dropped.
    var generation = 0
    /// Incremented whenever `contents` changes; stale re-sorts are dropped.
    var contentsVersion = 0
    private var navigationStart = ContinuousClock.now
    private var loadTask: Task<Void, Never>?
    private var sortTask: Task<Void, Never>?
    private var spinnerTask: Task<Void, Never>?

    private let loader = DirectoryLoader()
    let settings = ViewSettings.shared
    /// Set while the table is being made to match the settings (its notifications aren't user changes).
    var isApplyingColumns = false
    let columnMenuDelegate = ColumnMenuDelegate()
    let scrollView = NSScrollView()
    let tableView = FileTableView()
    private let overlay = NSTextField(labelWithString: "")
    /// Under an error: what to do about it, and the button that does it (P1-9).
    private let overlayDetail = NSTextField(wrappingLabelWithString: "")
    let overlayButton = NSButton(title: "", target: nil, action: nil)
    private let banner = NSTextField(labelWithString: "")
    private var bannerTask: Task<Void, Never>?
    private let spinner = NSProgressIndicator()
    private let iconLoader = FileIconLoader()
    /// `folder.path` with a trailing slash: prefix for building child paths without URL work per cell.
    var folderPrefix = "/"
    private var iconPrunePending = false

    // M7 operations state (see FileListOperations.swift)
    /// Where Move to Trash sends items (recorded in the trash history; network volumes handled — `TrashService`).
    /// KANSIO_TEST_TRASH=<dir> swaps in a test folder (self-test only).
    var trasher: any Trasher { TrashService.shared.trasher }
    /// The clipboard (the self-test swaps in a private pasteboard so it never touches yours).
    var pasteboard = NSPasteboard.general
    /// Items cut with ⌘X (shown dimmed while the clipboard still holds them).
    var cut: (folder: URL, names: Set<String>, changeCount: Int)?
    var renameSession: RenameSession?
    let statusBar = StatusBarView()
    /// The most recent Get Info window (self-test).
    weak var lastInfoWindow: InfoWindowController?
    /// Bumped on every status update; a slow (off-main) selection-size sum only lands if still current.
    var statusVersion = 0
    /// Live updates (FileListLive.swift).
    var watcher: FolderWatcher?
    var pendingLiveNames: Set<String> = []
    var pendingRescan = false
    var liveInFlight = false
    /// Counters for the live-update measurement.
    var liveBatchesApplied = 0
    var liveRelists = 0
    /// This window's copy/move operations in flight (⌘. stops them; OperationCenter runs them).
    var runningOperations: Set<UUID> = []
    /// Asks about name conflicts (sheet on this window).
    lazy var conflictPrompter = ConflictPrompter(window: view.window)
    /// Opens files with apps (KANSIO_TEST_OPENER=1: record instead of launching, for the self-test).
    lazy var opener: any Opener = ProcessInfo.processInfo.environment["KANSIO_TEST_OPENER"] != nil ? RecordingOpener() : WorkspaceOpener()
    lazy var openWithMenu = OpenWithMenu(list: { [weak self] in self })
    lazy var copyToMenu = CopyToMenu(kind: .copy, list: { [weak self] in self })
    lazy var moveToMenu = CopyToMenu(kind: .move, list: { [weak self] in self })
    private static let signposter = OSSignposter(subsystem: "dev.kansio.app", category: "UI")

    init(folder: URL, startsActive: Bool = true) {
        self.folder = folder
        self.history = NavigationHistory(start: folder)
        self.isActive = startsActive
        super.init(nibName: nil, bundle: nil)
    }

    // MARK: Background tabs (P1-3)

    /// False while the tab is in the background (another tab selected, minimized, app hidden):
    /// no watcher, no listing, no icon loading — only the model stays.
    private(set) var isActive: Bool
    private var searchStorage: AnyObject?
    private var trashStorage: AnyObject?
    var sizeState: SizeState?
    var preparedSearchIndex: SearchIndex?
    private var searchEndedStorage: (() -> Void)?
    /// The FSEvents id when the watcher stopped: on resume, what changed since then is replayed.
    private var pausedSince: UInt64?
    /// A listing was cut short (or never started: a tab opened in the background).
    private var reloadOnResume = false
    /// Folder listings started (self-test / measurement: switching tabs must not re-list).
    private(set) var listingsStarted = 0

    func setActive(_ active: Bool) {
        guard active != isActive, isViewLoaded else { isActive = active; return }
        isActive = active
        if !active {
            pausedSince = FolderWatcher.currentEventID // before stopping: nothing is missed
            watcher?.stop()
            watcher = nil
            if isShowingTrash { // the Trash is re-listed when the tab is shown again
                stopWatchingTrash()
                reloadOnResume = true
            }
            iconLoader.cancelAll()
            stopFolderSizes() // the cache keeps what's known; resuming replays FSEvents since then
            if isLoading {
                loadTask?.cancel()
                spinnerTask?.cancel()
                reloadOnResume = true
            }
        } else if reloadOnResume || !hasLoadedOnce {
            reloadOnResume = false
            pausedSince = nil
            load(folder, select: pendingSelection.isEmpty ? selectedNames : pendingSelection)
        } else {
            if !isSearching { startWatching(folder, generation: generation, since: pausedSince) }
            pausedSince = nil
            refreshRows(oldCount: rows.count) // icons cancelled while away are asked for again
            startFolderSizes()
        }
    }

    /// The tab was closed: stop everything it started.
    func shutdown() {
        isActive = false
        loadTask?.cancel()
        sortTask?.cancel()
        spinnerTask?.cancel()
        bannerTask?.cancel()
        watcher?.stop()
        watcher = nil
        stopWatchingTrash()
        trash?.relistTask?.cancel()
        iconLoader.cancelAll()
        stopFolderSizes()
        endRename(commit: false)
    }

    /// Whether the folder's watcher is running (self-test).
    var isWatching: Bool { watcher != nil }

    // MARK: Search (P1-5, FileListSearch.swift)
    var search: SearchState? {
        get { searchStorage as? SearchState }
        set { searchStorage = newValue }
    }
    // MARK: Trash view (P2-1, FileListTrash.swift)
    var trash: TrashState? {
        get { trashStorage as? TrashState }
        set { trashStorage = newValue }
    }
    /// The search ended (Esc, navigation): the search field clears.
    var onSearchEnded: (() -> Void)? {
        get { searchEndedStorage }
        set { searchEndedStorage = newValue }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var state: State {
        State(folder: folder, itemCount: rows.count, selectedCount: tableView.selectedRowIndexes.count,
              isLoading: isLoading, error: loadError, canGoBack: history.canGoBack,
              canGoForward: history.canGoForward, canGoUp: parentLocation(of: folder) != nil)
    }

    // MARK: View

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 620))

        tableView.style = .fullWidth
        tableView.rowHeight = ListMetrics.current.rowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = NSSize(width: 6, height: 0)
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsTypeSelect = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = []
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClickedRow(_:))
        tableView.onOpen = { [weak self] in self?.openSelection() }
        tableView.onGoUp = { [weak self] in self?.goUp() }
        tableView.onGoBack = { [weak self] in self?.goBack() }
        tableView.onGoForward = { [weak self] in self?.goForward() }
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        tableView.menu = contextMenu
        // Drag source and drop target (P1-4): Finder's rules (see FileDrop).
        tableView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        tableView.registerForDraggedTypes(FileDrop.draggedTypes)
        tableView.onRename = { [weak self] in self?.renameSelection(nil) }
        tableView.onTrash = { [weak self] in // Del; in the Trash (Explorer's Recycle Bin): delete immediately, after asking
            guard let self else { return }
            if self.isShowingTrash { self.deleteImmediately(nil) } else { self.moveToTrash(nil) }
        }
        tableView.onQuickLook = { [weak self] in self?.toggleQuickLook(nil) }
        tableView.onZoom = { direction in ViewSettings.shared.stepTextSize(direction) } // ⌘-scroll
        tableView.onRightDrag = { [weak self] down, drag in
            guard let self, self.renameSession == nil else { return }
            self.beginRightDrag(down: down, drag: drag)
        }

        setUpColumns() // global layout from ViewSettings (FileListColumns.swift)
        tableView.sortDescriptors = [NSSortDescriptor(key: settings.sort.field.rawValue, ascending: settings.sort.ascending)]

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        let barHeight = settings.showStatusBar ? StatusBarView.height : 0
        scrollView.frame = NSRect(x: 0, y: barHeight, width: root.bounds.width, height: root.bounds.height - barHeight)
        scrollView.autoresizingMask = [.width, .height]
        root.addSubview(scrollView)

        overlay.alignment = .center
        overlay.textColor = .secondaryLabelColor
        overlay.frame = NSRect(x: 20, y: root.bounds.midY - 10, width: root.bounds.width - 40, height: 20)
        overlay.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        overlay.isHidden = true
        root.addSubview(overlay)
        overlayDetail.alignment = .center
        overlayDetail.textColor = .secondaryLabelColor
        overlayDetail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        overlayDetail.frame = NSRect(x: 40, y: root.bounds.midY - 46, width: root.bounds.width - 80, height: 32)
        overlayDetail.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        overlayDetail.isHidden = true
        root.addSubview(overlayDetail)
        overlayButton.bezelStyle = .push
        overlayButton.target = self
        overlayButton.action = #selector(overlayButtonClicked)
        overlayButton.frame = NSRect(x: root.bounds.midX - 80, y: root.bounds.midY - 80, width: 160, height: 28)
        overlayButton.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        overlayButton.isHidden = true
        root.addSubview(overlayButton)

        // Transient inline messages ("link target is missing", …): never a modal alert.
        banner.alignment = .center
        banner.textColor = .labelColor
        banner.drawsBackground = true
        banner.backgroundColor = .controlBackgroundColor
        banner.isBezeled = false
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 6
        banner.frame = NSRect(x: 40, y: StatusBarView.height + 10, width: root.bounds.width - 80, height: 22)
        banner.autoresizingMask = [.width, .maxYMargin]
        banner.isHidden = true
        root.addSubview(banner)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.frame = NSRect(x: root.bounds.midX - 16, y: root.bounds.midY - 16, width: 32, height: 32)
        spinner.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        root.addSubview(spinner)

        statusBar.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: StatusBarView.height)
        statusBar.autoresizingMask = [.width, .maxYMargin]
        statusBar.isHidden = !settings.showStatusBar
        root.addSubview(statusBar)

        view = root
    }

    override func viewDidLoad() {
        LaunchTrace.mark("    file list loadView done")
        super.viewDidLoad()
        iconLoader.onLoaded = { [weak self] path in self?.iconArrived(forPath: path) }
        NotificationCenter.default.addObserver(forName: .typeIconsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisibleIcons() }
        }
        // Kansio changed files elsewhere (another window's operation, Undo/Redo): update what's shown here.
        NotificationCenter.default.addObserver(forName: .kansioFilesChanged, object: nil, queue: .main) { [weak self] note in
            let urls = note.userInfo?["urls"] as? [URL] ?? []
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, sender != ObjectIdentifier(self) else { return }
                self.refreshAffected(urls, select: sender == nil) // after Undo/Redo, select what came back
            }
        }
        if isActive {
            load(folder, select: [])
        } else {
            reloadOnResume = true // a tab opened in the background lists its folder when first shown
            notifyState()
        }
    }

    /// Moves keyboard focus to the file list.
    func focusList() { view.window?.makeFirstResponder(tableView) }

    /// Shows a short inline message at the bottom of the list (no modal alerts).
    /// `persistent`: stays until replaced (progress lines); otherwise hides after a few seconds.
    func showMessage(_ text: String, persistent: Bool = false) {
        bannerTask?.cancel()
        banner.stringValue = text
        banner.isHidden = false
        guard !persistent else { return }
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(text.count > 80 ? 7 : 4))
            guard !Task.isCancelled else { return }
            self?.banner.isHidden = true
        }
    }

    // MARK: Navigation & loading

    // MARK: Navigation (history)

    /// Navigation generation of what's on screen (self-test: detects stale results).
    var currentGeneration: Int { generation }
    /// Names of all rows currently shown, in order (self-test).
    var displayedNames: [String] { rows.map(\.name) }
    var displayedItems: [FileItem] { rows }
    /// Lowest alpha among visible row views (self-test: rows must never fade in).
    var minimumVisibleRowAlpha: CGFloat {
        let visible = tableView.rows(in: tableView.visibleRect)
        var minimum: CGFloat = 1
        for row in visible.location..<(visible.location + visible.length) {
            if let view = tableView.rowView(atRow: row, makeIfNecessary: false) { minimum = min(minimum, view.alphaValue) }
        }
        return minimum
    }

    /// Selects the first `n` rows and focuses the list (snapshot/self-test).
    func selectFirstRowsForTesting(_ n: Int) {
        focusList()
        tableView.selectRowIndexes(IndexSet(0..<min(n, rows.count)), byExtendingSelection: false)
    }

    /// The name cell of row 0, if on screen (self-test).
    var firstNameCellForTesting: FileCellView? {
        tableView.view(atColumn: 0, row: 0, makeIfNecessary: false) as? FileCellView
    }

    /// The inline message currently shown ("" if none) (self-test).
    var bannerText: String { banner.isHidden ? "" : banner.stringValue }

    /// The displayed item with this name (self-test).
    func displayedItem(named name: String) -> FileItem? { rows.first { $0.name == name } }

    /// The table, for synthesized key events (self-test).
    var tableForTesting: NSTableView { tableView }

    /// Names currently selected in the list.
    var selectedNames: [String] { tableView.selectedRowIndexes.map { rows[$0].name } }

    /// A user navigation to `url`: recorded in history (remembering the selection we leave behind).
    func navigate(to url: URL, select: [String] = []) {
        history.setCurrentSelection(selectedNames)
        guard history.visit(url, selection: select) else {
            // Already here: just refresh (Explorer re-lists on re-navigation, e.g. clicking the same sidebar item).
            load(url, select: select.isEmpty ? selectedNames : select)
            return
        }
        load(url, select: select)
    }

    func goBack(_ steps: Int = 1) {
        history.setCurrentSelection(selectedNames)
        let leaving = folder
        guard let entry = history.goBack(steps) else { NSSound.beep(); return }
        load(entry.url, select: Self.selectionOnReturn(to: entry, from: leaving))
    }

    func goForward(_ steps: Int = 1) {
        history.setCurrentSelection(selectedNames)
        let leaving = folder
        guard let entry = history.goForward(steps) else { NSSound.beep(); return }
        load(entry.url, select: Self.selectionOnReturn(to: entry, from: leaving))
    }

    /// What to select when arriving at `entry`: what was selected when we left it, or —
    /// if nothing was — the folder we're coming back out of, when it lives there (Explorer).
    private static func selectionOnReturn(to entry: NavigationHistory.Entry, from leaving: URL) -> [String] {
        if !entry.selection.isEmpty { return entry.selection }
        if let (parent, child) = parentLocation(of: leaving),
           parent.standardizedFileURL.path(percentEncoded: false) == entry.url.standardizedFileURL.path(percentEncoded: false)
            || parent.standardizedFileURL.path(percentEncoded: false) == entry.url.standardizedFileURL.path(percentEncoded: false) + "/" {
            return [child]
        }
        return []
    }

    /// Explorer: Up is a normal navigation (Back returns to the child) and selects the folder we came from.
    func goUp() {
        guard let (parent, child) = parentLocation(of: folder) else { NSSound.beep(); return }
        navigate(to: parent, select: [child])
    }

    /// Forgets history entries on a volume that disappeared.
    func forgetHistory(where isGone: (URL) -> Bool) {
        history.removeAll(where: isGone)
        notifyState()
    }

    /// Loads `url` into the view (no history change). Cancels all work for the previous folder.
    private func load(_ url: URL, select: [String]) {
        endRename(commit: false)
        stopFolderSizes()
        if let state = search { // navigating ends a search (no catch-up needed: the new folder is listed fresh)
            state.walkCancel?.cancel()
            state.task?.cancel()
            search = nil
            onSearchEnded?()
        }
        let showsTrash = TrashService.shared.isTrash(url)
        if !showsTrash { endTrash() }
        pendingSelection = select
        loadTask?.cancel()
        sortTask?.cancel()
        spinnerTask?.cancel()
        generation += 1
        let gen = generation
        listingsStarted += 1
        if showsTrash {
            watcher?.stop() // the Trash view watches every Trash folder itself
            watcher = nil
        } else if isActive {
            startWatching(url, generation: gen) // before listing starts, so nothing that changes meanwhile is missed
        } else {
            watcher?.stop()
            watcher = nil
            pausedSince = FolderWatcher.currentEventID // starts watching from here when shown
        }
        folder = url
        let path = url.path(percentEncoded: false)
        folderPrefix = path.hasSuffix("/") ? path : path + "/"
        iconLoader.cancelAll()
        isLoading = true
        hasFirstUpdate = false
        loadError = nil
        navigationStart = .now
        notifyState()

        // Keep showing the old folder until the first batch arrives (no blank flash);
        // show a spinner only if that takes noticeably long (slow volume).
        spinnerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, self.generation == gen, !self.hasFirstUpdate else { return }
            self.releaseOffMain(self.rows, self.contents)
            self.rows = []
            self.contents = .empty
            self.refreshRows(oldCount: self.tableView.numberOfRows)
            self.spinner.startAnimation(nil)
        }

        if showsTrash {
            loadTask = loadTrash(generation: gen)
            return
        }

        // Startup: the first folder was listed in parallel with AppKit's launch.
        if let pre = StartupPrefetch.take(for: url), pre.sort == settings.sort, pre.showHidden == settings.showHidden {
            applyLoaded(pre.update, ordered: pre.ordered, sort: pre.sort, hidden: pre.showHidden, generation: gen, scrollToTop: true)
            LaunchTrace.mark("    prefetched rows applied")
            return
        }

        let loader = self.loader
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            var first = true
            do {
                for try await update in loader.load(url) {
                    guard let self else { return }
                    // Read the current sort at each step, so a header click during loading is honoured.
                    let (sort, hidden) = await self.currentOrdering()
                    let ordered = update.contents.ordered(by: sort, includeHidden: hidden)
                    // Kinds for the first screenfuls, so the Type column doesn't hit LaunchServices on main.
                    FileKind.prewarm(ordered.prefix(300))
                    try Task.checkCancellation()
                    await self.applyLoaded(update, ordered: ordered, sort: sort, hidden: hidden,
                                           generation: gen, scrollToTop: first)
                    first = false
                }
            } catch is CancellationError {
            } catch {
                let fsError = error as? FileSystemError ?? FileSystemError(.other("\(error)"), path: url.path)
                await self?.applyError(fsError, generation: gen)
            }
        }
    }

    private func currentOrdering() -> (FileSort, Bool) { (settings.sort, settings.showHidden) }

    func applyLoaded(_ update: ListingUpdate, ordered: [FileItem], sort: FileSort, hidden: Bool,
                             generation gen: Int, scrollToTop: Bool) {
        guard gen == generation else { return }
        releaseOffMain(contents)
        contents = update.contents
        contentsVersion += 1
        hasFirstUpdate = true
        isLoading = !update.isComplete
        if update.isComplete {
            spinnerTask?.cancel()
            processLiveChanges() // changes that arrived while the folder was being listed
        }
        let startSizes = update.isComplete
        setRows(ordered, scrollToTop: scrollToTop, isComplete: update.isComplete)
        applyPendingSelection(final: update.isComplete)
        if sort != settings.sort || hidden != settings.showHidden { resort() }
        if startSizes { startFolderSizes() }
    }

    /// Selects (and reveals) remembered names once they're in the list.
    func applyPendingSelection(final: Bool) {
        guard !pendingSelection.isEmpty else { return }
        let wanted = Set(pendingSelection)
        var found = IndexSet()
        for (i, item) in rows.enumerated() where wanted.contains(item.name) { found.insert(i) }
        if !found.isEmpty {
            tableView.selectRowIndexes(found, byExtendingSelection: false)
            tableView.scrollRowToVisible(found.first!)
            notifyState()
        }
        if final || found.count == wanted.count { pendingSelection = [] }
    }

    func applyError(_ error: FileSystemError, generation gen: Int) {
        guard gen == generation else { return }
        spinnerTask?.cancel()
        hasFirstUpdate = true
        isLoading = false
        loadError = error
        releaseOffMain(contents)
        contents = .empty
        contentsVersion += 1
        setRows([], scrollToTop: true, isComplete: true)
    }

    func setRows(_ newRows: [FileItem], scrollToTop: Bool, isComplete: Bool) {
        let applyStart = ContinuousClock.now
        let state = Self.signposter.beginInterval("Apply rows", "\(newRows.count) rows")
        let selectedNames = scrollToTop ? [] : Set(tableView.selectedRowIndexes.map { rows[$0].name })

        let oldCount = rows.count
        releaseOffMain(rows)
        rows = newRows
        if scrollToTop { tableView.deselectAll(nil) }
        refreshRows(oldCount: oldCount)
        if !selectedNames.isEmpty {
            var restored = IndexSet()
            for (i, item) in rows.enumerated() where selectedNames.contains(item.name) { restored.insert(i) }
            tableView.selectRowIndexes(restored, byExtendingSelection: false)
        }
        if scrollToTop { tableView.scrollRowToVisible(0) }
        if !isLoading { spinner.stopAnimation(nil) }
        updateOverlay()
        notifyState()
        Self.signposter.endInterval("Apply rows", state)

        let event = DisplayEvent(generation: generation, rowCount: rows.count, isComplete: isComplete,
                                 navigationStart: navigationStart, mainThreadApply: .now - applyStart)
        lastDisplayEvent = event
        onDisplay?(event)
    }

    private func updateOverlay() {
        var detail = "", action = ""
        if let loadError {
            let name = folder.lastPathComponent.isEmpty ? folder.path(percentEncoded: false) : Self.displayName(folder.lastPathComponent)
            if loadError.isPrivacyDenied {
                overlay.stringValue = "macOS doesn’t allow Kansio to open “\(name)”."
                detail = "Allow it in System Settings ▸ Privacy & Security. Full Disk Access lets Kansio open every folder."
                action = "Grant Access…"
            } else if loadError.code == .permissionDenied {
                overlay.stringValue = "You don’t have permission to see the contents of “\(name)”."
                detail = "Its owner or an administrator can change who may read it. Get Info shows its owner and permissions."
                action = "Get Info"
            } else {
                overlay.stringValue = loadError.description
            }
        } else if rows.isEmpty && !isLoading, let trash {
            overlay.stringValue = !trash.filter.isEmpty ? "Nothing in the Trash matches “\(trash.filter)”."
                : contents.items.isEmpty ? "The Trash is empty." : "Only hidden items (⇧⌘. to show)."
        } else if rows.isEmpty && !isLoading {
            overlay.stringValue = contents.items.isEmpty ? "This folder is empty." : "Only hidden items (⇧⌘. to show)."
        } else {
            overlay.stringValue = ""
        }
        overlay.isHidden = overlay.stringValue.isEmpty
        overlayDetail.stringValue = detail
        overlayDetail.isHidden = detail.isEmpty
        overlayButton.title = action
        overlayButton.isHidden = action.isEmpty
    }

    /// "Grant Access…" (privacy) or "Get Info" (the folder's own permissions) under a load error.
    @objc func overlayButtonClicked() {
        guard let loadError else { return }
        if loadError.isPrivacyDenied {
            FullDiskAccessWindowController.shared.show()
        } else {
            lastInfoWindow = InfoWindowController.show(items: [], in: folder)
        }
    }

    var overlayViews: [NSView] { [overlay, overlayDetail, overlayButton] }
    var overlayTextForTesting: String { overlay.isHidden ? "" : overlay.stringValue }

    /// Self-test: show a load error as if the listing had failed with it.
    func showLoadErrorForTesting(_ error: FileSystemError) { applyError(error, generation: generation) }

    func notifyState() {
        onStateChange?(state)
        updateStatusBar()
    }

    /// Re-orders the current contents off the main thread (cheap: name ranks are cached).
    func resort() {
        if let trash {
            resortTrash(trash)
            return
        }
        if let state = search { // searching: re-order the results, not the folder
            let query = state.query
            state.query = ""
            setSearch(query)
            return
        }
        sortTask?.cancel()
        let contents = self.contents
        let sort = settings.sort, hidden = settings.showHidden
        let version = contentsVersion
        let sizes = folderSizes
        sortTask = Task.detached(priority: .userInitiated) { [weak self] in
            let ordered = contents.ordered(by: sort, includeHidden: hidden, folderSizes: sizes)
            FileKind.prewarm(ordered.prefix(300))
            guard !Task.isCancelled else { return }
            await self?.applySorted(ordered, version: version)
        }
    }

    private func applySorted(_ ordered: [FileItem], version: Int) {
        guard version == contentsVersion else { return } // a newer listing update will order itself
        setRows(ordered, scrollToTop: false, isComplete: !isLoading)
    }

    // MARK: Measurement hooks

    /// Scrolls the list down by `points`, wrapping to the top at the end (scroll benchmark).
    func scrollForMeasurement(by points: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(0, tableView.frame.height - clip.bounds.height)
        var y = clip.bounds.origin.y + points
        if y > maxY { y = -(tableView.headerView?.frame.height ?? 0) }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Actions

    func toggleHiddenFiles() {
        settings.showHidden.toggle() // → viewSettingChanged re-sorts
    }

    var showsHiddenFiles: Bool { settings.showHidden }

    @objc private func openClickedRow(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        open(rows[tableView.clickedRow])
    }

    // Opening (files, folders, links, aliases, Open With) lives in FileListOpening.swift.

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < rows.count else { return nil }
        let field = FileSort.Field(rawValue: tableColumn.identifier.rawValue)
        let (identifier, style, alignment): (NSUserInterfaceItemIdentifier, FileCellView.Style, NSTextAlignment)
        switch field {
        case .name: (identifier, style, alignment) = (FileCellView.nameIdentifier, .name, .left)
        case .dateModified, .dateCreated: (identifier, style, alignment) = (FileCellView.dateIdentifier, .digits, .left)
        case .size: (identifier, style, alignment) = (FileCellView.sizeIdentifier, .digits, .right)
        case .kind, .fileExtension: (identifier, style, alignment) = (FileCellView.kindIdentifier, .secondary, .left)
        case nil where tableColumn.identifier == Self.trashOriginalColumn:
            (identifier, style, alignment) = (FileCellView.kindIdentifier, .secondary, .left)
        case nil where tableColumn.identifier == Self.trashDeletedColumn:
            (identifier, style, alignment) = (FileCellView.dateIdentifier, .digits, .left)
        default: return nil
        }
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? FileCellView
            ?? FileCellView(identifier: identifier, style: style, alignment: alignment)
        configure(cell, column: tableColumn, item: rows[row])
        return cell
    }

    /// Fills a cell. Only sets values that changed, so unchanged cells don't redraw.
    func configure(_ cell: FileCellView, column: NSTableColumn, item: FileItem) {
        switch FileSort.Field(rawValue: column.identifier.rawValue) {
        case .name:
            // A search result from a subfolder: its name, and where it is ("sub/dir"). The Trash: just its name.
            if let entry = trashEntry(item) {
                cell.text = Self.displayName(entry.displayName)
                cell.detail = ""
            } else if let slash = item.name.lastIndex(of: "/") {
                cell.text = Self.displayName(String(item.name[item.name.index(after: slash)...]))
                cell.detail = String(item.name[..<slash])
            } else {
                cell.text = Self.displayName(item.name)
                cell.detail = ""
            }
            let image = FileIconLoader.needsPerFileIcon(item)
                ? iconLoader.icon(forPath: folderPrefix + item.name, item: item) ?? IconCache.shared.icon(for: item)
                : IconCache.shared.icon(for: item)
            cell.icon = image
            let alpha: CGFloat = item.isHidden || isCut(item) ? 0.5 : 1
            cell.iconAlpha = alpha
        case .dateModified:
            cell.text = Formatters.date.string(from: item.modificationDate)
        case .dateCreated:
            cell.text = Formatters.date.string(from: item.creationDate)
        case .size:
            cell.text = item.kind == .file ? Formatters.size.string(fromByteCount: item.size)
                : item.kind == .directory ? folderSizeText(item) : ""
        case .kind:
            cell.text = FileKind.description(for: item)
        case .fileExtension:
            cell.text = item.displayExtension
        default:
            if let text = trashColumnText(column.identifier, item: item) { cell.text = text }
        }
    }

    /// Type icons became available: re-configure the visible name cells (cheap; only changed images are set).
    private func refreshVisibleIcons() {
        guard let nameColumn = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == FileSort.Field.name.rawValue })
        else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        for row in visible.location..<min(visible.location + visible.length, rows.count) {
            if let cell = tableView.view(atColumn: nameColumn, row: row, makeIfNecessary: false) as? FileCellView {
                configure(cell, column: tableView.tableColumns[nameColumn], item: rows[row])
            }
        }
    }

    /// A per-file icon finished loading: refresh that row if it's still on screen.
    private func iconArrived(forPath path: String) {
        guard path.hasPrefix(folderPrefix), let nameColumn = tableView.tableColumns.firstIndex(where: {
            $0.identifier.rawValue == FileSort.Field.name.rawValue
        }) else { return }
        let name = String(path.dropFirst(folderPrefix.count))
        let visible = tableView.rows(in: tableView.visibleRect)
        for row in visible.location..<min(visible.location + visible.length, rows.count) where rows[row].name == name {
            if let cell = tableView.view(atColumn: nameColumn, row: row, makeIfNecessary: false) as? FileCellView {
                configure(cell, column: tableView.tableColumns[nameColumn], item: rows[row])
            }
        }
    }

    /// Rows scrolled away: cancel icon loads that are no longer visible (coalesced per run-loop turn).
    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        guard !iconPrunePending else { return }
        iconPrunePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.iconPrunePending = false
                let visible = self.tableView.rows(in: self.tableView.visibleRect)
                var paths = Set<String>()
                for row in visible.location..<min(visible.location + visible.length, self.rows.count)
                where FileIconLoader.needsPerFileIcon(self.rows[row]) {
                    paths.insert(self.folderPrefix + self.rows[row].name)
                }
                self.iconLoader.retainOnly(paths)
            }
        }
    }

    /// Dropping the last reference to a 100k-item array frees 100k strings — ~10 ms on the
    /// main thread. Hand the old value to a background queue so it's freed there instead.
    /// (Delayed so the main thread has certainly dropped its own references by then and the
    /// background block holds the last one.)
    func releaseOffMain(_ values: any Sendable...) {
        let box = values
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) { withExtendedLifetime(box) {} }
    }

    /// Names may legally contain newlines/tabs/other control characters; a single-line
    /// label would cut them off or hide them. Show them as visible Control Pictures (display only).
    static func displayName(_ name: String) -> String {
        guard name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return name }
        return String(String.UnicodeScalarView(name.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0..<0x20: Unicode.Scalar(0x2400 + scalar.value)!  // ␀…␟
            case 0x7F: "\u{2421}"                                   // ␡
            default: scalar
            }
        }))
    }

    /// Applies a new `rows` array without `reloadData()`.
    ///
    /// `reloadData()` discards every row view and re-adds every cell to the view tree,
    /// which (measured with `sample`) is most of the cost of a page update. Instead, tell
    /// the table only that the count changed, and reconfigure the cells already on screen.
    func refreshRows(oldCount: Int) {
        // noteNumberOfRowsChanged() is O(1)-ish for growth (insertRows walks every inserted
        // row: ~4 ms for 23k), but by default it fades new rows in from alpha 0 (~0.3 s). Inside a
        // zero-duration animation context there's no fade (verified by the self-test). Shrinking
        // still costs ~8 ms for 100k → 25: AppKit visits every removed row internally.
        if rows.count != oldCount {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                tableView.noteNumberOfRowsChanged()
            }
        }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        let columns = tableView.tableColumns
        for row in visible.location..<min(visible.location + visible.length, rows.count) {
            let item = rows[row]
            for (c, column) in columns.enumerated() {
                if let cell = tableView.view(atColumn: c, row: row, makeIfNecessary: false) as? FileCellView {
                    configure(cell, column: column, item: item)
                }
            }
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first else { return }
        if trashSortChanged(descriptor) { return } // the Trash's own columns sort only the Trash
        guard let key = descriptor.key, let field = FileSort.Field(rawValue: key) else { return }
        settings.sort = FileSort(field: field, ascending: descriptor.ascending) // → viewSettingChanged re-sorts
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row < rows.count, renameSession == nil else { return nil }
        // Eager file URLs. (Lazily provided items make drag start cheap but cost a pasteboard round trip per item
        // when read — 10k items took 44 s to read. Drop targets in Kansio use the URLs registered below instead.)
        return url(of: rows[row]) as NSURL
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        FileDrop.beginLocalDrag(folder: isShowingTrash ? URL(filePath: "/") : folder, names: rowIndexes.compactMap { $0 < rows.count ? rows[$0].name : nil },
                                sequence: session.draggingSequenceNumber)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        FileDrop.endLocalDrag()
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        tableColumn?.identifier.rawValue == FileSort.Field.name.rawValue ? rows[row].name : nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        notifyState()
        quickLookSelectionChanged()
        // Warm the Open With menu for small selections (big ones are computed when the menu opens).
        if tableView.selectedRowIndexes.count <= 50 { OpenWithMenu.prefetch(openWithURLs) }
        // P2-3: look inside a selected archive now, so its context menu knows whether to offer "Extract as".
        if tableView.selectedRowIndexes.count == 1, let row = tableView.selectedRowIndexes.first, row < rows.count,
           !rows[row].isFolder, !isShowingTrash, ArchiveNames.isArchive(rows[row].name) {
            let item = rows[row]
            ArchiveService.shared.prefetch(url(of: item), size: item.size, modified: item.modificationDate)
        }
    }
}

/// Table subclass for Explorer keys that NSTableView doesn't handle itself.
@MainActor
final class FileTableView: NSTableView {
    var onOpen: (() -> Void)?
    var onGoUp: (() -> Void)?
    var onGoBack: (() -> Void)?
    var onGoForward: (() -> Void)?

    var onRename: (() -> Void)?
    var onTrash: (() -> Void)?
    var onQuickLook: (() -> Void)?
    /// ⌘-scroll: +1 bigger, −1 smaller (Explorer's Ctrl+wheel).
    var onZoom: ((Int) -> Void)?
    /// A right-button drag started on a row (the press, the first drag event past the threshold).
    var onRightDrag: ((_ down: NSEvent, _ drag: NSEvent) -> Void)?
    private var zoomScroll: CGFloat = 0
    /// When the last type-to-select letter was typed: a Space right after continues the search.
    private var lastTypeSelect: TimeInterval = 0

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        switch (event.keyCode, mods) {
        case (36, []), (76, []): onOpen?()        // Return / keypad Enter
        case (51, []): onGoUp?()                  // Backspace
        // Explorer's Alt+←/→/↑ (⌘[ ⌘] ⌘↑ come through the Go menu).
        case (123, [.option]): onGoBack?()
        case (124, [.option]): onGoForward?()
        case (126, [.option]): onGoUp?()
        case (120, []): onRename?()               // F2
        case (117, []): onTrash?()                // Forward Delete (Explorer's Del)
        case (49, []) where lastTypeSelect == 0 || event.timestamp - lastTypeSelect > 1.0:
            onQuickLook?()                        // Space (unless continuing a type-to-select)
        case (115, _), (119, _), (116, _), (121, _):
            moveSelection(keyCode: event.keyCode, extend: mods.contains(.shift))
        default:
            if let chars = event.charactersIgnoringModifiers, mods.isSubset(of: [.shift]),
               chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
                lastTypeSelect = event.timestamp
            }
            super.keyDown(with: event)
        }
    }

    /// A right-button press on a row: moved → a right-button drag (P3-2); released without moving → the context menu
    /// (shown on release, like Explorer).
    override func rightMouseDown(with event: NSEvent) {
        guard let onRightDrag, let window, row(at: convert(event.locationInWindow, from: nil)) >= 0 else {
            super.rightMouseDown(with: event)
            return
        }
        if let drag = RightDrag.waitForDrag(in: window, from: event) { onRightDrag(event, drag) } else { super.rightMouseDown(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let onZoom else {
            zoomScroll = 0
            super.scrollWheel(with: event)
            return
        }
        // A wheel notch is one step; a trackpad's small precise deltas add up (every 40 pt is one step).
        if event.phase == .began { zoomScroll = 0 }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY.sign == .minus ? -40 : 40
        guard delta != 0 else { return }
        zoomScroll += delta
        while abs(zoomScroll) >= 40 {
            let step: CGFloat = zoomScroll > 0 ? 40 : -40
            zoomScroll -= step
            onZoom(step > 0 ? 1 : -1)
        }
    }

    /// Home/End/Page Up/Page Down move the selection (Explorer); NSTableView would only scroll.
    private func moveSelection(keyCode: UInt16, extend: Bool) {
        guard numberOfRows > 0 else { return }
        let page = max(1, Int(visibleRect.height / rowHeight) - 1)
        let current = selectedRowIndexes.isEmpty ? 0 : (selectedRow >= 0 ? selectedRow : selectedRowIndexes.last!)
        let target: Int = switch keyCode {
        case 115: 0
        case 119: numberOfRows - 1
        case 116: max(0, current - page)
        default: min(numberOfRows - 1, current + page)
        }
        if extend, let anchor = selectedRowIndexes.first {
            let range = min(anchor, target)...max(anchor, target)
            selectRowIndexes(IndexSet(integersIn: range), byExtendingSelection: false)
        } else {
            selectRowIndexes([target], byExtendingSelection: false)
        }
        scrollRowToVisible(target)
    }
}
