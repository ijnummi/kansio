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
    private var pendingSelection: [String] = []
    private var contents = FolderContents.empty
    private var rows: [FileItem] = []
    private var isLoading = false
    /// True once the current navigation has shown its first batch.
    private var hasFirstUpdate = false
    private var loadError: FileSystemError?

    /// Incremented per navigation; results from older navigations are dropped.
    private var generation = 0
    /// Incremented whenever `contents` changes; stale re-sorts are dropped.
    private var contentsVersion = 0
    private var navigationStart = ContinuousClock.now
    private var loadTask: Task<Void, Never>?
    private var sortTask: Task<Void, Never>?
    private var spinnerTask: Task<Void, Never>?

    private let loader = DirectoryLoader()
    private let settings = ViewSettings.shared
    private let scrollView = NSScrollView()
    private let tableView = FileTableView()
    private let overlay = NSTextField(labelWithString: "")
    private let banner = NSTextField(labelWithString: "")
    private var bannerTask: Task<Void, Never>?
    private let spinner = NSProgressIndicator()
    private let iconLoader = FileIconLoader()
    /// `folder.path` with a trailing slash: prefix for building child paths without URL work per cell.
    private var folderPrefix = "/"
    private var iconPrunePending = false
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
    func showMessage(_ text: String) {
        bannerTask?.cancel()
        banner.stringValue = text
        banner.isHidden = false
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
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
    private func applyPendingSelection(final: Bool) {
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

    private func setRows(_ newRows: [FileItem], scrollToTop: Bool, isComplete: Bool) {
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

    private func notifyState() { onStateChange?(state) }

    /// Re-orders the current contents off the main thread (cheap: name ranks are cached).
    private func resort() {
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

    private func openSelection() {
        let selected = tableView.selectedRowIndexes
        if selected.count == 1, let i = selected.first { open(rows[i]); return }
        for i in selected where !rows[i].isFolder { open(rows[i]) } // Explorer: Enter on many files opens each
    }

    private func open(_ item: FileItem) {
        let url = folder.appending(path: item.name, directoryHint: item.kind == .directory ? .isDirectory : .notDirectory)
        switch item.kind {
        case .directory where item.isFolder:
            navigate(to: url)
        case .symlink where item.flags.contains(.linkToFolder):
            // Explorer-style: stay on the link's own path (Up returns to where the link lives).
            navigate(to: folder.appending(path: item.name, directoryHint: .isDirectory))
        case .symlink where item.flags.contains(.brokenLink):
            showMessage("“\(Self.displayName(item.name))” points to an item that doesn’t exist.")
        case .symlink where !item.flags.contains(.linkToPackage):
            // Not classified yet (resolution still running): resolve off-main, it can hang on a dead mount.
            Task.detached { [weak self] in
                let flags = SymlinkResolver.classify(url.path(percentEncoded: false))
                await self?.openLink(named: item.name, at: url, flags: flags)
            }
        default:
            NSWorkspace.shared.open(url)
        }
    }

    private func openLink(named name: String, at url: URL, flags: FileItem.Flags) {
        if flags.contains(.linkToFolder) {
            navigate(to: folder.appending(path: name, directoryHint: .isDirectory))
        } else if flags.contains(.brokenLink) {
            showMessage("“\(Self.displayName(name))” points to an item that doesn’t exist.")
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < rows.count else { return nil }
        let cell: NSTableCellView
        switch FileSort.Field(rawValue: tableColumn.identifier.rawValue) {
        case .name:
            cell = tableView.makeView(withIdentifier: NameCellView.identifier, owner: nil) as? NameCellView ?? NameCellView(frame: .zero)
        case .dateModified:
            cell = tableView.makeView(withIdentifier: TextCellView.dateIdentifier, owner: nil) as? TextCellView
                ?? TextCellView(identifier: TextCellView.dateIdentifier, alignment: .left)
        case .size:
            cell = tableView.makeView(withIdentifier: TextCellView.sizeIdentifier, owner: nil) as? TextCellView
                ?? TextCellView(identifier: TextCellView.sizeIdentifier, alignment: .right)
        case .kind:
            cell = tableView.makeView(withIdentifier: TextCellView.kindIdentifier, owner: nil) as? TextCellView
                ?? TextCellView(identifier: TextCellView.kindIdentifier, alignment: .left)
        default:
            return nil
        }
        configure(cell, column: tableColumn, item: rows[row])
        return cell
    }

    /// Fills a cell. Only sets values that changed, so unchanged cells don't redraw.
    private func configure(_ cell: NSTableCellView, column: NSTableColumn, item: FileItem) {
        switch FileSort.Field(rawValue: column.identifier.rawValue) {
        case .name:
            setIfChanged(cell.textField, Self.displayName(item.name))
            let image = FileIconLoader.needsPerFileIcon(item)
                ? iconLoader.icon(forPath: folderPrefix + item.name, item: item) ?? IconCache.shared.icon(for: item)
                : IconCache.shared.icon(for: item)
            if cell.imageView?.image !== image { cell.imageView?.image = image }
            let alpha: CGFloat = item.isHidden ? 0.5 : 1
            if cell.imageView?.alphaValue != alpha { cell.imageView?.alphaValue = alpha }
        case .dateModified:
            setIfChanged(cell.textField, Formatters.date.string(from: item.modificationDate))
        case .size:
            setIfChanged(cell.textField, item.kind == .file ? Formatters.size.string(fromByteCount: item.size) : "")
        case .kind:
            setIfChanged(cell.textField, FileKind.description(for: item))
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
            if let cell = tableView.view(atColumn: nameColumn, row: row, makeIfNecessary: false) as? NSTableCellView {
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
            if let cell = tableView.view(atColumn: nameColumn, row: row, makeIfNecessary: false) as? NSTableCellView {
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
    private func releaseOffMain(_ values: any Sendable...) {
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

    private func setIfChanged(_ field: NSTextField?, _ value: String) {
        if let field, field.stringValue != value { field.stringValue = value }
    }

    /// Applies a new `rows` array without `reloadData()`.
    ///
    /// `reloadData()` discards every row view and re-adds every cell to the view tree,
    /// which (measured with `sample`) is most of the cost of a page update. Instead, tell
    /// the table only that the count changed, and reconfigure the cells already on screen.
    private func refreshRows(oldCount: Int) {
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
                if let cell = tableView.view(atColumn: c, row: row, makeIfNecessary: false) as? NSTableCellView {
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

    func tableViewSelectionDidChange(_ notification: Notification) { notifyState() }
}

/// Table subclass for Explorer keys that NSTableView doesn't handle itself.
@MainActor
final class FileTableView: NSTableView {
    var onOpen: (() -> Void)?
    var onGoUp: (() -> Void)?
    var onGoBack: (() -> Void)?
    var onGoForward: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        switch (event.keyCode, mods) {
        case (36, []), (76, []): onOpen?()        // Return / keypad Enter
        case (51, []): onGoUp?()                  // Backspace
        // Explorer's Alt+←/→/↑ (⌘[ ⌘] ⌘↑ come through the Go menu).
        case (123, [.option]): onGoBack?()
        case (124, [.option]): onGoForward?()
        case (126, [.option]): onGoUp?()
        default: super.keyDown(with: event)
        }
    }
}
