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
    static let rowHeight: CGFloat = 22

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
    let scrollView = NSScrollView()
    let tableView = FileTableView()
    private let overlay = NSTextField(labelWithString: "")
    private let banner = NSTextField(labelWithString: "")
    private var bannerTask: Task<Void, Never>?
    private let spinner = NSProgressIndicator()
    private let iconLoader = FileIconLoader()
    /// `folder.path` with a trailing slash: prefix for building child paths without URL work per cell.
    var folderPrefix = "/"
    private var iconPrunePending = false

    // M7 operations state (see FileListOperations.swift)
    /// Where Move to Trash sends items. KANSIO_TEST_TRASH=<dir> swaps in a test folder (self-test only).
    let trasher: any Trasher = ProcessInfo.processInfo.environment["KANSIO_TEST_TRASH"]
        .map { DirectoryTrasher(directory: URL(filePath: $0, directoryHint: .isDirectory)) } ?? SystemTrasher()
    /// The clipboard (the self-test swaps in a private pasteboard so it never touches yours).
    var pasteboard = NSPasteboard.general
    /// Items cut with ⌘X (shown dimmed while the clipboard still holds them).
    var cut: (folder: URL, names: Set<String>, changeCount: Int)?
    var renameSession: RenameSession?
    /// Copy/move operations in flight (⌘. stops them). M11 replaces the progress line with a panel.
    var runningOperations: [UUID: Task<Void, Never>] = [:]
    /// Asks about name conflicts (sheet on this window).
    lazy var conflictPrompter = ConflictPrompter(window: view.window)
    /// Opens files with apps (KANSIO_TEST_OPENER=1: record instead of launching, for the self-test).
    lazy var opener: any Opener = ProcessInfo.processInfo.environment["KANSIO_TEST_OPENER"] != nil ? RecordingOpener() : WorkspaceOpener()
    lazy var openWithMenu = OpenWithMenu(list: { [weak self] in self })
    private static let signposter = OSSignposter(subsystem: "dev.kansio.app", category: "UI")

    init(folder: URL) {
        self.folder = folder
        self.history = NavigationHistory(start: folder)
        super.init(nibName: nil, bundle: nil)
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
        tableView.rowHeight = Self.rowHeight
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
        tableView.onRename = { [weak self] in self?.renameSelection(nil) }
        tableView.onTrash = { [weak self] in self?.moveToTrash(nil) }
        tableView.onQuickLook = { [weak self] in self?.toggleQuickLook(nil) }

        addColumn(.name, title: "Name", width: 300, minWidth: 120, firstClickAscending: true)
        addColumn(.dateModified, title: "Date Modified", width: 150, minWidth: 80, firstClickAscending: false)
        addColumn(.kind, title: "Type", width: 150, minWidth: 60, firstClickAscending: true)
        addColumn(.size, title: "Size", width: 90, minWidth: 50, firstClickAscending: false, alignment: .right)
        tableView.autosaveName = "FileList.v2"    // column widths/order persist globally (bump when columns change)
        tableView.autosaveTableColumns = true
        tableView.sortDescriptors = [NSSortDescriptor(key: settings.sort.field.rawValue, ascending: settings.sort.ascending)]

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.frame = root.bounds
        scrollView.autoresizingMask = [.width, .height]
        root.addSubview(scrollView)

        overlay.alignment = .center
        overlay.textColor = .secondaryLabelColor
        overlay.frame = NSRect(x: 20, y: root.bounds.midY - 10, width: root.bounds.width - 40, height: 20)
        overlay.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        overlay.isHidden = true
        root.addSubview(overlay)

        // Transient inline messages ("link target is missing", …): never a modal alert.
        banner.alignment = .center
        banner.textColor = .labelColor
        banner.drawsBackground = true
        banner.backgroundColor = .controlBackgroundColor
        banner.isBezeled = false
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 6
        banner.frame = NSRect(x: 40, y: 12, width: root.bounds.width - 80, height: 22)
        banner.autoresizingMask = [.width, .maxYMargin]
        banner.isHidden = true
        root.addSubview(banner)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.frame = NSRect(x: root.bounds.midX - 16, y: root.bounds.midY - 16, width: 32, height: 32)
        spinner.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        root.addSubview(spinner)

        view = root
    }

    override func viewDidLoad() {
        LaunchTrace.mark("    file list loadView done")
        super.viewDidLoad()
        iconLoader.onLoaded = { [weak self] path in self?.iconArrived(forPath: path) }
        NotificationCenter.default.addObserver(forName: .typeIconsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisibleIcons() }
        }
        load(folder, select: [])
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

    private func addColumn(_ field: FileSort.Field, title: String, width: CGFloat, minWidth: CGFloat,
                           firstClickAscending: Bool, alignment: NSTextAlignment = .left) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(field.rawValue))
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.headerCell.alignment = alignment
        column.sortDescriptorPrototype = NSSortDescriptor(key: field.rawValue, ascending: firstClickAscending)
        tableView.addTableColumn(column)
    }

    // MARK: Navigation & loading

    // MARK: Navigation (history)

    /// Navigation generation of what's on screen (self-test: detects stale results).
    var currentGeneration: Int { generation }
    /// Names of all rows currently shown, in order (self-test).
    var displayedNames: [String] { rows.map(\.name) }
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
        pendingSelection = select
        loadTask?.cancel()
        sortTask?.cancel()
        spinnerTask?.cancel()
        generation += 1
        let gen = generation
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

    private func applyLoaded(_ update: ListingUpdate, ordered: [FileItem], sort: FileSort, hidden: Bool,
                             generation gen: Int, scrollToTop: Bool) {
        guard gen == generation else { return }
        releaseOffMain(contents)
        contents = update.contents
        contentsVersion += 1
        hasFirstUpdate = true
        isLoading = !update.isComplete
        if update.isComplete { spinnerTask?.cancel() }
        setRows(ordered, scrollToTop: scrollToTop, isComplete: update.isComplete)
        applyPendingSelection(final: update.isComplete)
        if sort != settings.sort || hidden != settings.showHidden { resort() }
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

    private func applyError(_ error: FileSystemError, generation gen: Int) {
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
        if let loadError {
            overlay.stringValue = loadError.description
        } else if rows.isEmpty && !isLoading {
            overlay.stringValue = contents.items.isEmpty ? "This folder is empty." : "Only hidden items (⇧⌘. to show)."
        } else {
            overlay.stringValue = ""
        }
        overlay.isHidden = overlay.stringValue.isEmpty
    }

    func notifyState() { onStateChange?(state) }

    /// Re-orders the current contents off the main thread (cheap: name ranks are cached).
    func resort() {
        sortTask?.cancel()
        let contents = self.contents
        let sort = settings.sort, hidden = settings.showHidden
        let version = contentsVersion
        sortTask = Task.detached(priority: .userInitiated) { [weak self] in
            let ordered = contents.ordered(by: sort, includeHidden: hidden)
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
        settings.showHidden.toggle()
        resort()
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
        case .dateModified: (identifier, style, alignment) = (FileCellView.dateIdentifier, .digits, .left)
        case .size: (identifier, style, alignment) = (FileCellView.sizeIdentifier, .digits, .right)
        case .kind: (identifier, style, alignment) = (FileCellView.kindIdentifier, .secondary, .left)
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
            cell.text = Self.displayName(item.name)
            let image = FileIconLoader.needsPerFileIcon(item)
                ? iconLoader.icon(forPath: folderPrefix + item.name, item: item) ?? IconCache.shared.icon(for: item)
                : IconCache.shared.icon(for: item)
            cell.icon = image
            let alpha: CGFloat = item.isHidden || isCut(item) ? 0.5 : 1
            cell.iconAlpha = alpha
        case .dateModified:
            cell.text = Formatters.date.string(from: item.modificationDate)
        case .size:
            cell.text = item.kind == .file ? Formatters.size.string(fromByteCount: item.size) : ""
        case .kind:
            cell.text = FileKind.description(for: item)
        default:
            break
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
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key, let field = FileSort.Field(rawValue: key) else { return }
        let sort = FileSort(field: field, ascending: descriptor.ascending)
        guard sort != settings.sort else { return }
        settings.sort = sort
        resort()
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        tableColumn?.identifier.rawValue == FileSort.Field.name.rawValue ? rows[row].name : nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        notifyState()
        quickLookSelectionChanged()
        // Warm the Open With menu for small selections (big ones are computed when the menu opens).
        if tableView.selectedRowIndexes.count <= 50 { OpenWithMenu.prefetch(openWithURLs) }
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
