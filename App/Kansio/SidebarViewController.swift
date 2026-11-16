import AppKit
import FileSystemKit

/// A Favorites entry (a pinned folder, flat shortcut). Objects with stable identity: NSOutlineView
/// keys rows by item — the same entry keeps its object while its folder is renamed or moved.
@MainActor
final class SidebarItem: NSObject {
    let entryID: UUID
    var title: String
    var url: URL
    var missing: Bool

    init(entry: FavoriteEntry, missing: Bool) {
        entryID = entry.id
        title = entry.title
        url = entry.url
        self.missing = missing
    }

    var path: String { url.path(percentEncoded: false) }

    /// The known folders get their own symbols; anything else is a folder.
    var symbol: String {
        let fm = FileManager.default
        func dir(_ d: FileManager.SearchPathDirectory) -> String? { fm.urls(for: d, in: .userDomainMask).first?.path(percentEncoded: false) }
        switch FolderTreeIO.normalizedPath(path) {
        case dir(.desktopDirectory).map(FolderTreeIO.normalizedPath): return "menubar.dock.rectangle"
        case dir(.documentDirectory).map(FolderTreeIO.normalizedPath): return "doc"
        case dir(.downloadsDirectory).map(FolderTreeIO.normalizedPath): return "arrow.down.circle"
        case "/Applications": return "square.grid.3x3"
        case FolderTreeIO.normalizedPath(fm.homeDirectoryForCurrentUser.path(percentEncoded: false)): return "house"
        default: return "folder"
        }
    }
}

@MainActor
final class SidebarSection: NSObject {
    let title: String
    var items: [SidebarItem]
    init(title: String, items: [SidebarItem]) {
        self.title = title
        self.items = items
    }
}

/// The navigation pane (P1-1, Explorer layout): **Favorites** (flat shortcuts) and **Locations** —
/// Home and every volume as roots of a lazily listed folder tree (`FolderTree`).
///
/// - Children are listed only when a node expands, off-main (`FolderTreeIO`), with a spinner after
///   150 ms; rows on screen are checked in the background for subfolders (disclosure triangles).
/// - The tree expands to the current folder ("Expand to open folder"); branches it opened collapse
///   again when left, hand-expanded ones stay.
/// - One directory-level FSEvents stream per listed root keeps listed folders current; changes are
///   applied as row inserts/removes/moves, so nothing collapses.
/// - Volumes are read off-main and refreshed on NSWorkspace mount/unmount/rename notifications.
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                   NSMenuDelegate, NSTextFieldDelegate {
    /// The user picked a folder (click, Return, or arrow keys after the pause).
    var onSelect: ((URL) -> Void)?
    /// Return in the tree: the list should take focus.
    var onReturn: (() -> Void)?
    /// A volume disappeared (eject/unmount).
    var onVolumeRemoved: ((Volume) -> Void)?
    /// For tests/measurement: fired after the volume list changes.
    var onVolumesChanged: (([Volume]) -> Void)?
    /// Whether the file list has shown its first rows (the launch reveal waits for that).
    var listHasRows: () -> Bool = { true }
    /// For tests/measurement: a reveal finished (`reached`: the current folder is selected in the tree).
    var onRevealFinished: ((URL, Bool) -> Void)?
    /// Measurement: what the tree did in this run-loop iteration.
    var traceNote: ((String) -> Void)?
    /// The file list in this window: opener, pasteboard, trasher and inline messages.
    weak var fileList: FileListViewController?

    let outlineView = SidebarOutlineView()
    let tree: FolderTree
    private let settings = ViewSettings.shared
    private let favorites: SidebarSection
    private let locations = SidebarSection(title: "Locations", items: [])
    private var sections: [SidebarSection] { [favorites, locations] }
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var volumeOfRoot: [ObjectIdentifier: Volume] = [:]
    private var currentPath: String?
    private var currentURL: URL?
    private var isSyncingSelection = false
    private var expandingAutomatically = false
    private var restoringExpansion = 0
    private var refreshTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    // Listing, checks, watching
    private var listingTasks: [ObjectIdentifier: Task<Bool, Never>] = [:]
    private var spinning: Set<ObjectIdentifier> = []
    private var checks: [ObjectIdentifier: CancellationFlag] = [:]
    /// Whether each row was last drawn with a disclosure triangle (redraw only when that changes).
    private var shownDisclosure: [ObjectIdentifier: Bool] = [:]
    private var watchers: [ObjectIdentifier: TreeWatcher] = [:]
    private let watchFilter = TreeWatchFilter()
    private var pendingRelist: [ObjectIdentifier: TreeNode] = [:]
    private var relistTask: Task<Void, Never>?
    private var relistGeneration: [ObjectIdentifier: Int] = [:]

    // Reveal and selection
    private var revealTask: Task<Void, Never>?
    private var revealGeneration = 0
    private var hasRevealedOnce = false
    private var keyNavigationTask: Task<Void, Never>?
    private var marked: [AnyObject] = []
    private var renaming: (node: TreeNode, field: NSTextField)?

    static let cellIdentifier = NSUserInterfaceItemIdentifier("SidebarCell")
    static let treeCellIdentifier = NSUserInterfaceItemIdentifier("TreeCell")
    static let headerIdentifier = NSUserInterfaceItemIdentifier("SidebarHeader")

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        // Pinned folders (P1-2); Home is the first root under Locations, so it isn't a default favorite.
        favorites = SidebarSection(title: "Favorites", items: [])
        tree = FolderTree(showHidden: ViewSettings.shared.showHidden)
        super.init(nibName: nil, bundle: nil)
        tree.setRoots([homeSpec])
        favorites.items = Self.favoriteItems(reusing: [])
    }

    /// Favorites rows from the store, reusing the row object of each entry (stable identity).
    private static func favoriteItems(reusing old: [SidebarItem]) -> [SidebarItem] {
        let store = FavoritesStore.shared
        return store.entries.map { entry in
            let missing = store.missing.contains(entry.id)
            if let item = old.first(where: { $0.entryID == entry.id }) {
                item.title = entry.title
                item.url = entry.url
                item.missing = missing
                return item
            }
            return SidebarItem(entry: entry, missing: missing)
        }
    }

    private func favoritesChanged() {
        let selected = outlineView.item(atRow: outlineView.selectedRow) as AnyObject?
        favorites.items = Self.favoriteItems(reusing: favorites.items)
        isSyncingSelection = true
        outlineView.reloadItem(favorites, reloadChildren: true)
        isSyncingSelection = false
        // Keep the highlight: the current folder may have become (or stopped being) a favorite.
        let favorite = favorites.items.first { FolderTreeIO.normalizedPath($0.path) == currentPath }
        if let node = selected as? TreeNode {
            highlight(selected: node, marked: [favorite as AnyObject?].compactMap { $0 } + marked.filter { $0 is TreeNode })
        } else {
            highlight(selected: favorite, marked: marked.filter { $0 is TreeNode })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        MainActor.assumeIsolated {
            observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
            watchers.values.forEach { $0.stop() }
        }
    }

    private var homeSpec: FolderTree.RootSpec {
        .init(url: home, title: "Home (\(NSUserName()))", kind: .home, isNetwork: false)
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Sidebar"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 10
        outlineView.autoresizesOutlineColumn = false
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked(_:))
        outlineView.setAccessibilityLabel("Navigation pane")
        outlineView.onReturn = { [weak self] in self?.returnPressed() }
        outlineView.onArrow = { [weak self] right in self?.arrowPressed(right: right) ?? false }
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.frame = NSRect(x: 0, y: 0, width: 200, height: 600)
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        outlineView.reloadData()
        sections.forEach { outlineView.expandItem($0) }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            })
        }
        NotificationCenter.default.addObserver(forName: .favoritesDidChange, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.favoritesChanged() }
        }
        outlineView.registerForDraggedTypes([.fileURL, .kansioFavorite])
        outlineView.setDraggingSourceOperationMask([.copy], forLocal: false) // never a move into another app
        outlineView.setDraggingSourceOperationMask([.move, .copy, .link, .generic], forLocal: true)
        NotificationCenter.default.addObserver(forName: .viewSettingsDidChange, object: nil, queue: nil) { [weak self] note in
            let key = (note.userInfo?["key"] as? String).flatMap(ViewSettings.Key.init(rawValue:))
            MainActor.assumeIsolated { if let key { self?.settingChanged(key) } }
        }
        refreshVolumes()
    }

    // MARK: Volumes → roots

    /// Re-reads mounted volumes off the main thread and updates the roots in place.
    func refreshVolumes() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let volumes = await VolumeList.mountedVolumes()
            guard let self, !Task.isCancelled else { return }
            self.apply(volumes)
        }
    }

    /// The mounted volumes as last read (startup disk first).
    private(set) var volumes: [Volume] = []

    private func apply(_ volumes: [Volume]) {
        let oldVolumes = self.volumes
        self.volumes = volumes
        let oldRoots = tree.roots
        let specs = [homeSpec] + volumes.map {
            FolderTree.RootSpec(url: $0.url, title: $0.name, kind: .volume, isNetwork: $0.isNetwork)
        }
        let removedRoots = tree.setRoots(specs)
        volumeOfRoot = [:]
        for (root, volume) in zip(tree.roots.dropFirst(), volumes) { volumeOfRoot[ObjectIdentifier(root)] = volume }
        for root in removedRoots {
            watchers.removeValue(forKey: ObjectIdentifier(root))?.stop()
        }
        apply(TreeDiff.plan(old: oldRoots, new: tree.roots), in: locations)
        updateWatchFilter()
        let removed = oldVolumes.filter { o in !volumes.contains { $0.url == o.url } }
        removed.forEach { onVolumeRemoved?($0) }
        onVolumesChanged?(volumes)
        if let currentURL, !removedRoots.isEmpty || oldVolumes.isEmpty { reveal(currentURL) }
    }

    private static func symbol(for volume: Volume) -> String {
        if volume.isNetwork { return "network" }
        if volume.isRoot || (volume.isInternal && !volume.isEjectable) { return "internaldrive" }
        return "externaldrive"
    }

    // MARK: Current folder → reveal

    /// Called on every navigation (and on other state changes — a no-op unless the folder changed).
    func showCurrentFolder(_ url: URL) {
        let path = FolderTreeIO.normalizedPath(url.path(percentEncoded: false))
        guard path != currentPath else { return }
        currentPath = path
        currentURL = url
        reveal(url)
    }

    /// Expands the tree to `url` (most specific root), selects it, and collapses branches the reveal
    /// opened earlier that aren't on the way. Off when the setting is off, and on network volumes
    /// unless that setting is on: then only what's already visible is marked.
    private func reveal(_ url: URL) {
        revealGeneration += 1
        let generation = revealGeneration
        revealTask?.cancel()
        keyNavigationTask?.cancel()
        // Launch: wait for the list's first rows, so the tree never competes with them.
        if !hasRevealedOnce && !listHasRows() {
            revealTask = Task { [weak self] in
                for _ in 0..<100 {
                    try? await Task.sleep(for: .milliseconds(15))
                    guard let self, !Task.isCancelled, generation == self.revealGeneration else { return }
                    if self.listHasRows() { break }
                }
                self?.hasRevealedOnce = true
                self?.reveal(url)
            }
            return
        }
        hasRevealedOnce = true
        guard let (root, names) = tree.revealTarget(for: url) else {
            finishReveal(url, path: [], target: nil, mark: nil)
            return
        }
        let expand = settings.treeExpandToCurrent && (!root.isNetwork || settings.treeExpandOnNetwork)
        guard expand else {
            let visible = tree.deepestVisible(toward: url)
            finishReveal(url, path: visible?.node.ancestry ?? [], target: visible?.isTarget == true ? visible?.node : nil,
                         mark: visible?.isTarget == true ? nil : visible?.node)
            return
        }
        revealTask = Task { [weak self] in
            guard let self else { return }
            // Walk (listing levels as needed) first, expand at the end: expanding one level at a time
            // re-lays out the rows below on every step.
            var node = root
            var path = [root]
            for name in names {
                let listed = await self.ensureListed(node, within: root.isNetwork ? .seconds(2) : nil)
                guard !Task.isCancelled, generation == self.revealGeneration else { return }
                guard listed else { // timed out / failed: stop here, mark how far we got
                    guard await self.expandAutomatically(path.dropLast(), generation: generation) else { return }
                    self.finishReveal(url, path: path, target: nil, mark: node)
                    return
                }
                guard let child = self.tree.child(of: node, named: name) else {
                    // Inside a package or a hidden folder (not shown): reveal to here, highlight nothing.
                    guard await self.expandAutomatically(path, generation: generation) else { return }
                    self.finishReveal(url, path: path, target: nil, mark: nil)
                    return
                }
                node = child
                path.append(child)
            }
            guard await self.expandAutomatically(path.dropLast(), generation: generation) else { return }
            // Selecting and scrolling to the target lays out a screenful of rows: its own frame too.
            try? await Task.sleep(for: .milliseconds(1))
            guard generation == self.revealGeneration else { return }
            self.finishReveal(url, path: path, target: node, mark: nil)
        }
    }

    /// Expands `nodes` (a path, root first), deepest first — the branch appears when its top opens —
    /// and at most ~4 ms of it per run-loop turn: each expansion costs AppKit ~1 ms in a pane with a
    /// few hundred rows, and a deep reveal must not take a frame over 16 ms. False if superseded.
    private func expandAutomatically(_ nodes: some Collection<TreeNode>, generation: Int) async -> Bool {
        var slice = ContinuousClock.now
        let pending = nodes.reversed().filter { !outlineView.isItemExpanded($0) }
        for node in pending {
            // The last (top) one inserts the whole branch and its rows get laid out: give it a frame of its own.
            let isTop = node === pending.last && pending.count > 1
            if ContinuousClock.now - slice > .milliseconds(4) || isTop {
                try? await Task.sleep(for: .milliseconds(1)) // let a frame through
                guard generation == revealGeneration else { return false }
                slice = .now
            }
            expandingAutomatically = true
            restoringExpansion += 1 // expanded here explicitly, not restored level by level
            let t0 = ContinuousClock.now
            expandRow(node)
            traceNote?("tree expand \(node.name) \((ContinuousClock.now - t0).formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
            restoringExpansion -= 1
            expandingAutomatically = false
            tree.didExpand(node, automatically: true)
        }
        for node in nodes { tree.didExpand(node, automatically: true) } // already open ones keep their state
        return true
    }

    private func expandRow(_ node: TreeNode) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            outlineView.expandItem(node)
        }
    }

    static let trace = ProcessInfo.processInfo.environment["KANSIO_TRACE"] != nil

    private func finishReveal(_ url: URL, path: [TreeNode], target: TreeNode?, mark: TreeNode?) {
        let t0 = ContinuousClock.now
        defer { traceNote?("tree finishReveal \((ContinuousClock.now - t0).formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))") }
        // Branches the reveal opened earlier close in the next frame (not in the one that selects and scrolls).
        let generation = revealGeneration
        let collapse = tree.autoExpandedToCollapse(keeping: path).filter { outlineView.isItemExpanded($0) }
        if !collapse.isEmpty {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, generation == self.revealGeneration else { return }
                    let t0 = ContinuousClock.now
                    self.collapseRows(collapse.filter { self.outlineView.isItemExpanded($0) && $0.expandedAutomatically })
                    self.traceNote?("tree collapse \(collapse.count) \((ContinuousClock.now - t0).formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
                }
            }
        }
        let favorite = favorites.items.first { FolderTreeIO.normalizedPath($0.path) == currentPath }
        if let target {
            highlight(selected: target, marked: [favorite as AnyObject?, mark as AnyObject?].compactMap { $0 })
            let row = outlineView.row(forItem: target)
            if row >= 0 { outlineView.scrollRowToVisible(row) }
        } else {
            highlight(selected: favorite, marked: [mark as AnyObject?].compactMap { $0 })
        }
        onRevealFinished?(url, target != nil)
    }

    private func highlight(selected: AnyObject?, marked: [AnyObject]) {
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        let row = selected.map { outlineView.row(forItem: $0) } ?? -1
        if row >= 0 {
            if outlineView.selectedRow != row { outlineView.selectRowIndexes([row], byExtendingSelection: false) }
        } else {
            outlineView.deselectAll(nil)
        }
        self.marked = marked
        outlineView.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? SidebarRowView else { return }
            let item = self.outlineView.item(atRow: row) as AnyObject?
            rowView.isMarked = item.map { i in marked.contains { $0 === i } } ?? false
        }
    }

    // MARK: Listing

    /// Lists `node` if it hasn't been (shared by expansion and the reveal). `within`: stop waiting
    /// after that long (the listing itself continues and is applied when it arrives).
    @discardableResult
    func ensureListed(_ node: TreeNode, within limit: Duration? = nil) async -> Bool {
        if node.isListed { return true }
        let id = ObjectIdentifier(node)
        let task = listingTasks[id] ?? startListing(node)
        guard let limit else { return await task.value }
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: limit); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
    }

    private func startListing(_ node: TreeNode) -> Task<Bool, Never> {
        let id = ObjectIdentifier(node)
        let url = node.url
        let timeout: Duration? = node.isNetwork ? .seconds(30) : nil
        let task = Task { [weak self] () -> Bool in
            let spinnerTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self else { return }
                self.spinning.insert(id)
                self.outlineView.reloadItem(node)
            }
            let result = await FolderTreeIO.listFolders(url, timeout: timeout)
            spinnerTask.cancel()
            guard let self else { return false }
            self.listingTasks[id] = nil
            if self.spinning.remove(id) != nil { self.outlineView.reloadItem(node) }
            switch result {
            case .success(let listing):
                self.apply(self.tree.apply(listing.items, realPath: listing.realPath, to: node))
                if node.isRoot { self.startWatching(node) }
                return true
            case .failure(let error):
                self.tree.listingFailed(node, message: error.description)
                self.outlineView.reloadItem(node)
                return false
            }
        }
        listingTasks[id] = task
        return task
    }

    /// Applies one node's children change to the outline view without collapsing anything.
    private func apply(_ change: FolderTree.ChildrenChange) {
        let parent = change.parent
        let t0 = ContinuousClock.now
        defer { traceNote?("tree apply \(parent.name) \(change.plan.inserted.count)+/\(change.plan.removed.count)- \((ContinuousClock.now - t0).formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))") }
        updateWatchFilter()
        // A re-read that found nothing new (FSEvents rescans re-read every listed folder) costs nothing here.
        guard !change.plan.isEmpty || !change.renamed.isEmpty else {
            refreshDisclosure(of: parent)
            return
        }
        cancelChecks(for: change.removed)
        if collapsingRows[ObjectIdentifier(parent)] != nil {
            // Being collapsed in chunks: the model has the change; the rows are going away anyway.
        } else if outlineView.isItemExpanded(parent) {
            apply(change.plan, in: parent)
            change.renamed.forEach { outlineView.reloadItem($0) }
        } else {
            outlineView.reloadItem(parent, reloadChildren: true)
        }
        refreshDisclosure(of: parent)
        if let renaming, change.removed.contains(where: { $0 === renaming.node }) { endRename(commit: false) }
    }

    private func collapseRows(_ nodes: [TreeNode]) {
        guard !nodes.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            outlineView.beginUpdates()
            nodes.forEach { outlineView.collapseItem($0) }
            outlineView.endUpdates()
        }
    }

    /// Redraws a row only if its disclosure triangle appeared or went away.
    private func refreshDisclosure(of node: TreeNode) {
        let shows = node.showsDisclosure(checkNetwork: settings.treeCheckNetwork)
        if let shown = shownDisclosure[ObjectIdentifier(node)], shown != shows { outlineView.reloadItem(node) }
    }

    private func apply(_ plan: TreeDiff.Plan, in parent: Any) {
        guard !plan.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            outlineView.beginUpdates()
            if !plan.removed.isEmpty { outlineView.removeItems(at: plan.removed, inParent: parent, withAnimation: []) }
            for move in plan.moves { outlineView.moveItem(at: move.from, inParent: parent, to: move.to, inParent: parent) }
            if !plan.inserted.isEmpty { outlineView.insertItems(at: plan.inserted, inParent: parent, withAnimation: []) }
            outlineView.endUpdates()
        }
    }

    // MARK: Subfolder checks (rows on screen)

    private func checkSubfolders(_ node: TreeNode) {
        let id = ObjectIdentifier(node)
        guard isActive, checks[id] == nil, node.needsSubfolderCheck(checkNetwork: settings.treeCheckNetwork) else { return }
        let flag = CancellationFlag()
        checks[id] = flag
        let url = node.url, showHidden = settings.showHidden, network = node.isNetwork
        Task { [weak self] in
            let result = await FolderTreeIO.hasShownSubfolder(url, showHidden: showHidden,
                                                              timeout: network ? .seconds(2) : nil, cancel: flag)
            guard let self, self.checks[id] === flag else { return }
            self.checks[id] = nil
            guard !flag.isCancelled, !node.isListed else { return }
            // Network timeout: fall back to showing the triangle.
            node.hasSubfolders = result ?? network
            let shows = node.showsDisclosure(checkNetwork: self.settings.treeCheckNetwork)
            if self.shownDisclosure[id] != shows { self.outlineView.reloadItem(node) }
        }
    }

    private func cancelCheck(_ node: TreeNode) {
        checks.removeValue(forKey: ObjectIdentifier(node))?.cancel()
    }

    private func cancelChecks(for nodes: [TreeNode]) {
        for node in nodes {
            cancelCheck(node)
            shownDisclosure[ObjectIdentifier(node)] = nil
            node.allChildren.map(cancelChecks)
        }
    }

    // MARK: Watching (directory-level FSEvents per listed root)

    // MARK: Background tabs (P1-3)

    private(set) var isActive = true
    private var pausedSince: UInt64?

    /// Background tab: stop watching and checking (keep the model); on return, FSEvents replays what
    /// changed meanwhile and only the affected listed folders are re-read.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if !active {
            pausedSince = FolderWatcher.currentEventID
            watchers.values.forEach { $0.stop() }
            watchers = [:]
            checks.values.forEach { $0.cancel() }
            checks = [:]
            keyNavigationTask?.cancel()
        } else {
            let since = pausedSince
            pausedSince = nil
            for root in tree.roots where root.isListed { startWatching(root, since: since) }
        }
    }

    /// The tab was closed: stop everything it started.
    func shutdown() {
        isActive = false
        watchers.values.forEach { $0.stop() }
        watchers = [:]
        checks.values.forEach { $0.cancel() }
        checks = [:]
        revealTask?.cancel()
        keyNavigationTask?.cancel()
        relistTask?.cancel()
        listingTasks.values.forEach { $0.cancel() }
    }

    var watcherCount: Int { watchers.count }

    private func startWatching(_ root: TreeNode, since: UInt64? = nil) {
        let id = ObjectIdentifier(root)
        guard watchers[id] == nil, isActive else { return }
        let filter = watchFilter
        let watcher = TreeWatcher(rootPath: root.path) { [weak self] event in
            // Off the main thread: keep only folders the tree has listed (or their direct children),
            // and hand them over in coalesced batches (at most one every 150 ms).
            filter.submit(event) { batch in
                Task { @MainActor in self?.handle(batch) }
            }
        }
        watchers[id] = watcher
        watcher.start(latency: 0.15, since: since)
    }

    private func updateWatchFilter() { watchFilter.update(tree.listedRealPaths) }

    /// Watcher batches that reached the main thread, and the longest one's main-thread time (measurement).
    private(set) var watcherBatches = 0
    private(set) var longestWatcherBatch: Duration = .zero

    func resetWatcherStatistics() {
        watcherBatches = 0
        longestWatcherBatch = .zero
    }

    private func handle(_ events: [TreeWatcher.Event]) {
        let start = ContinuousClock.now
        watcherBatches += 1
        events.forEach(handle)
        longestWatcherBatch = max(longestWatcherBatch, ContinuousClock.now - start)
    }

    private func handle(_ event: TreeWatcher.Event) {
        switch event {
        case .changed(let paths):
            for path in paths {
                let listed = tree.listedNodes(atRealPath: path)
                listed.forEach(scheduleRelist)
                guard listed.isEmpty else { continue }
                // An unlisted folder changed: its "has subfolders" answer may be stale.
                let parentPath = (path as NSString).deletingLastPathComponent
                let name = (path as NSString).lastPathComponent
                for parent in tree.listedNodes(atRealPath: parentPath) {
                    guard let child = parent.allChildren?.first(where: { $0.name == name }), !child.isListed else { continue }
                    child.hasSubfolders = nil
                    // Re-check in the background; the row is redrawn only if its triangle changes.
                    if outlineView.row(forItem: child) >= 0 { checkSubfolders(child) }
                }
            }
        case .rescan(let path):
            tree.listedNodes(underRealPath: path).forEach(scheduleRelist)
        }
    }

    private func scheduleRelist(_ node: TreeNode) {
        pendingRelist[ObjectIdentifier(node)] = node
        guard relistTask == nil else { return }
        relistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30)) // let duplicate events (two roots) coalesce
            guard let self else { return }
            let nodes = Array(self.pendingRelist.values)
            self.pendingRelist = [:]
            self.relistTask = nil
            for node in nodes { self.relist(node) }
        }
    }

    /// Re-reads a listed folder and applies the difference (nothing collapses).
    func relist(_ node: TreeNode) {
        let id = ObjectIdentifier(node)
        let generation = (relistGeneration[id] ?? 0) + 1
        relistGeneration[id] = generation
        let url = node.url
        Task { [weak self] in
            let result = await FolderTreeIO.listFolders(url, timeout: node.isNetwork ? .seconds(30) : nil)
            guard let self, self.relistGeneration[id] == generation, node.isListed, self.isInTree(node) else { return }
            if case .success(let listing) = result {
                self.apply(self.tree.apply(listing.items, realPath: listing.realPath, to: node))
            }
        }
    }

    private func isInTree(_ node: TreeNode) -> Bool {
        let chain = node.ancestry
        guard let root = chain.first, tree.roots.contains(where: { $0 === root }) else { return false }
        return zip(chain, chain.dropFirst()).allSatisfy { parent, child in parent.allChildren?.contains { $0 === child } == true }
    }

    // MARK: Settings

    private func settingChanged(_ key: ViewSettings.Key) {
        switch key {
        case .showHidden:
            for change in tree.setShowHidden(settings.showHidden) { apply(change) }
            reloadVisibleRows() // unlisted rows re-check (the answer depends on the setting)
            if let currentURL { reveal(currentURL) }
        case .treeCheckNetwork:
            reloadVisibleRows()
        case .treeExpandToCurrent, .treeExpandOnNetwork:
            if let currentURL { reveal(currentURL) }
        default:
            break
        }
    }

    private func reloadVisibleRows() {
        let range = outlineView.rows(in: outlineView.visibleRect)
        for row in range.location..<(range.location + range.length) {
            if let node = outlineView.item(atRow: row) as? TreeNode { outlineView.reloadItem(node) }
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: sections.count
        case let section as SidebarSection: section === locations ? tree.roots.count : section.items.count
        case let node as TreeNode: collapsingRows[ObjectIdentifier(node)] ?? node.children.count
        default: 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case let section as SidebarSection: section === locations ? tree.roots[index] : section.items[index]
        case let node as TreeNode: node.children[index]
        default: sections[index]
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        switch item {
        case is SidebarSection: true
        case let node as TreeNode: node.showsDisclosure(checkNetwork: settings.treeCheckNetwork)
        default: false
        }
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is SidebarSection }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { !(item is SidebarSection) }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { item is TreeNode }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = outlineView.makeView(withIdentifier: SidebarRowView.identifier, owner: nil) as? SidebarRowView ?? SidebarRowView()
        rowView.identifier = SidebarRowView.identifier // reused, like cells
        rowView.node = item as? TreeNode
        rowView.isMarked = marked.contains { $0 === item as AnyObject }
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, didRemove rowView: NSTableRowView, forRow row: Int) {
        // Scrolled off screen: its pending subfolder check isn't needed any more.
        if let node = (rowView as? SidebarRowView)?.node { cancelCheck(node) }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        switch item {
        case let section as SidebarSection:
            let cell = outlineView.makeView(withIdentifier: Self.headerIdentifier, owner: nil) as? NSTableCellView ?? Self.makeHeaderCell()
            cell.textField?.stringValue = section.title
            return cell
        case let favorite as SidebarItem:
            let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: nil) as? TreeCellView
                ?? TreeCellView(identifier: Self.cellIdentifier)
            cell.configure(title: favorite.title, image: NSImage(systemSymbolName: favorite.symbol, accessibilityDescription: nil),
                           dimmed: favorite.missing, spinning: false, error: nil)
            cell.toolTip = favorite.missing ? "Can’t be found (deleted, in the Trash, or on a volume that isn’t connected)" : favorite.path
            return cell
        case let node as TreeNode:
            let cell = outlineView.makeView(withIdentifier: Self.treeCellIdentifier, owner: nil) as? TreeCellView
                ?? TreeCellView(identifier: Self.treeCellIdentifier)
            cell.configure(title: node.displayName, image: image(for: node), dimmed: node.isHidden,
                           spinning: spinning.contains(ObjectIdentifier(node)), error: node.listingError)
            shownDisclosure[ObjectIdentifier(node)] = node.showsDisclosure(checkNetwork: settings.treeCheckNetwork)
            checkSubfolders(node)
            return cell
        default:
            return nil
        }
    }

    private func image(for node: TreeNode) -> NSImage? {
        switch node.kind {
        case .home: NSImage(systemSymbolName: "house", accessibilityDescription: nil)
        case .volume:
            NSImage(systemSymbolName: volumeOfRoot[ObjectIdentifier(node)].map(Self.symbol(for:)) ?? "internaldrive",
                    accessibilityDescription: nil)
        case .folder: TreeCellView.folderImage
        case .link: TreeCellView.linkImage
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? TreeNode else { return true }
        guard collapsingRows[ObjectIdentifier(node)] == nil else { return false } // still collapsing in chunks
        // ⌥-click expands everything below — but only levels already listed (never a recursive listing).
        if !node.isListed, NSApp.currentEvent?.modifierFlags.contains(.option) == true,
           outlineView.item(atRow: outlineView.clickedRow) as AnyObject? !== node {
            return false
        }
        return true
    }

    /// Nodes being collapsed in chunks: how many of their rows the outline view still has.
    private var collapsingRows: [ObjectIdentifier: Int] = [:]
    static let largeNode = 500

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        // Collapsing a node with 10,000 shown children costs AppKit ~20 ms in one go. Remove its rows
        // in chunks across frames (from the end), then collapse the empty node.
        guard let node = item as? TreeNode, node.children.count > Self.largeNode, outlineView.isItemExpanded(node) else { return true }
        let id = ObjectIdentifier(node)
        if collapsingRows[id] == 0 { return true } // the final, cheap collapse
        if collapsingRows[id] == nil { collapseLarge(node) }
        return false
    }

    private func removeRows(_ rows: IndexSet, in parent: TreeNode) {
        let t0 = ContinuousClock.now
        defer { traceNote?("tree remove \(rows.count) rows \((ContinuousClock.now - t0).formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))") }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            outlineView.removeItems(at: rows, inParent: parent, withAnimation: [])
        }
    }

    private func collapseLarge(_ node: TreeNode) {
        let id = ObjectIdentifier(node)
        collapsingRows[id] = node.children.count
        Task { [weak self] in
            while let self, let remaining = self.collapsingRows[id], remaining > 0 {
                // Big chunks while the rows are far below the screen; the last ~100 (the ones that may be
                // visible) 20 per frame, so no frame lays out a whole screen of changes at once.
                let chunk = remaining > 120 ? min(remaining - 100, 800) : min(remaining, 20)
                self.collapsingRows[id] = remaining - chunk
                self.removeRows(IndexSet((remaining - chunk)..<remaining), in: node)
                if remaining - chunk > 0 { try? await Task.sleep(for: .milliseconds(1)) } // let a frame through
            }
            guard let self else { return }
            let t0 = ContinuousClock.now
            self.outlineView.collapseItem(node)
            self.traceNote?("tree collapse (empty) \((ContinuousClock.now - t0).formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
            self.collapsingRows[id] = nil
        }
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? TreeNode, !node.isListed else { return }
        _ = listingTasks[ObjectIdentifier(node)] ?? startListing(node)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? TreeNode else { return }
        if restoringExpansion == 0 { tree.didExpand(node, automatically: expandingAutomatically) }
        // Children that were open when an ancestor collapsed open again (as they were: by hand or not).
        restoringExpansion += 1
        defer { restoringExpansion -= 1 }
        for child in node.children where child.isExpanded && !outlineView.isItemExpanded(child) {
            outlineView.expandItem(child)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? TreeNode else { return }
        // AppKit also reports expanded descendants of a collapsing node: they keep their state (hidden),
        // so a hand-expanded branch is still open when its parent opens again.
        if let parent = node.parent, !outlineView.isItemExpanded(parent) { return }
        tree.didCollapse(node)
        if let renaming, renaming.node.ancestry.contains(where: { $0 === node }) && renaming.node !== node { endRename(commit: false) }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, let url = url(of: outlineView.item(atRow: outlineView.selectedRow)) else { return }
        keyNavigationTask?.cancel()
        if let favorite = outlineView.item(atRow: outlineView.selectedRow) as? SidebarItem, favorite.missing {
            openMissing(favorite)
            return
        }
        // Arrow keys: navigate after a pause, so holding ↓ doesn't list every folder it passes.
        let delay = settings.treeKeyDelay
        if outlineView.isHandlingKey, delay > 0 {
            keyNavigationTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                self?.onSelect?(url)
            }
        } else {
            onSelect?(url)
        }
    }

    /// A dimmed favorite: look once more (it may be back), else say why nothing opens.
    private func openMissing(_ favorite: SidebarItem) {
        let store = FavoritesStore.shared
        let passes = store.resolvePasses
        store.resolveAll()
        Task { [weak self] in
            let deadline = ContinuousClock.now + .seconds(3)
            while store.resolvePasses == passes && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            guard let self else { return }
            if let entry = store.entries.first(where: { $0.id == favorite.entryID }), !store.missing.contains(entry.id) {
                self.onSelect?(entry.url)
            } else {
                self.fileList?.showMessage("“\(favorite.title)” can’t be found — it was deleted, moved to the Trash, or is on a volume that isn’t connected. Unpin it from its context menu.")
                if let currentURL = self.currentURL { self.currentPath = nil; self.showCurrentFolder(currentURL) } // restore the highlight
            }
        }
    }

    private func url(of item: Any?) -> URL? {
        switch item {
        case let favorite as SidebarItem: favorite.url
        case let node as TreeNode: node.url
        default: nil
        }
    }

    // MARK: Mouse & keyboard

    /// Double-click: navigate (the click did) and toggle the branch.
    @objc private func doubleClicked(_ sender: Any?) {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? TreeNode else { return }
        if outlineView.isItemExpanded(node) { outlineView.collapseItem(node) } else { outlineView.expandItem(node) }
    }

    /// Return: navigate at once and hand focus to the list.
    private func returnPressed() {
        keyNavigationTask?.cancel()
        if let url = url(of: outlineView.item(atRow: outlineView.selectedRow)) { onSelect?(url) }
        onReturn?()
    }

    /// →: expand, or go to the first child. ←: collapse, or go to the parent.
    private func arrowPressed(right: Bool) -> Bool {
        guard let node = outlineView.item(atRow: outlineView.selectedRow) as? TreeNode else { return false }
        if right {
            if !outlineView.isItemExpanded(node) {
                if node.showsDisclosure(checkNetwork: settings.treeCheckNetwork) { outlineView.expandItem(node) }
            } else if let first = node.children.first {
                select(first)
            }
        } else {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else if let parent = node.parent {
                select(parent)
            }
        }
        return true
    }

    /// Selects a row as the user would (the selection handler navigates, after the key pause).
    private func select(_ item: AnyObject) {
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    // MARK: Context menu (P1-1: Open, Show in Finder, Copy Path, Get Info, New Folder)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        contextMenuItems(forRow: outlineView.clickedRow).forEach(menu.addItem)
    }

    func contextMenuItems(forRow row: Int) -> [NSMenuItem] {
        let item = outlineView.item(atRow: row)
        guard let url = url(of: item) else { return [] }
        func entry(_ title: String, _ action: Selector) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item
            return menuItem
        }
        var items: [NSMenuItem] = []
        let favorite = item as? SidebarItem
        if favorite?.missing != true {
            items += [entry("Open", #selector(openItem(_:))), entry("Open in New Tab", #selector(openItemInNewTab(_:))),
                      entry("Open in New Window", #selector(openItemInNewWindow(_:))), .separator(),
                      entry("Show in Finder", #selector(showItemInFinder(_:))), entry("Copy Path", #selector(copyItemPath(_:))),
                      entry("Get Info", #selector(getItemInfo(_:))), .separator(),
                      entry("New Folder", #selector(newFolderInItem(_:))), .separator()]
        }
        if let favorite, let index = favorites.items.firstIndex(of: favorite) {
            // Reordering without the mouse (also by dragging).
            if index > 0 { items.append(entry("Move Up", #selector(moveFavoriteUp(_:)))) }
            if index < favorites.items.count - 1 { items.append(entry("Move Down", #selector(moveFavoriteDown(_:)))) }
            items.append(entry("Unpin from Favorites", #selector(unpinItem(_:))))
        } else {
            items.append(entry(FavoritesStore.shared.isPinned(url) ? "Unpin from Favorites" : "Pin to Favorites", #selector(togglePinnedItem(_:))))
        }
        return items
    }

    /// The folder in `row` (a favorite that isn't missing, or a tree node), for middle-click.
    func folderURL(atRow row: Int) -> URL? {
        let item = outlineView.item(atRow: row)
        if let favorite = item as? SidebarItem, favorite.missing { return nil }
        return url(of: item)
    }

    @objc func openItemInNewTab(_ sender: Any?) {
        guard let url = menuURL(sender) else { return }
        (view.window?.windowController as? MainWindowController)?.openInNewTab(url)
    }

    @objc func openItemInNewWindow(_ sender: Any?) {
        guard let url = menuURL(sender) else { return }
        (view.window?.windowController as? MainWindowController)?.openInNewWindow(url)
    }

    @objc func unpinItem(_ sender: Any?) {
        guard let favorite = (sender as? NSMenuItem)?.representedObject as? SidebarItem else { return }
        FavoritesStore.shared.unpin(favorite.entryID)
    }

    @objc func togglePinnedItem(_ sender: Any?) {
        guard let url = menuURL(sender) else { return }
        let store = FavoritesStore.shared
        if let entry = store.entry(for: url) { store.unpin(entry.id) } else { store.pin([url]) }
    }

    @objc func moveFavoriteUp(_ sender: Any?) { moveFavorite(sender, by: -1) }
    @objc func moveFavoriteDown(_ sender: Any?) { moveFavorite(sender, by: 1) }

    private func moveFavorite(_ sender: Any?, by offset: Int) {
        guard let favorite = (sender as? NSMenuItem)?.representedObject as? SidebarItem,
              let index = favorites.items.firstIndex(of: favorite) else { return }
        FavoritesStore.shared.move(from: index, to: offset < 0 ? index - 1 : index + 2)
    }

    // MARK: Drag and drop (pin by dropping folders on Favorites; reorder by dragging favorites)

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        switch item {
        case let favorite as SidebarItem:
            // Only the internal type: dragging Documents out of the sidebar must never hand the folder itself to Finder.
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(favorite.entryID.uuidString, forType: .kansioFavorite)
            return pasteboardItem
        case let node as TreeNode:
            return node.url as NSURL
        default:
            return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        let isFavorite = info.draggingPasteboard.types?.contains(.kansioFavorite) == true
        // Only onto Favorites: between rows, on a row (→ before it) or on the header (→ at the end).
        // Drops on tree folders (copy/move into them) come with drag and drop, P1-4.
        let target: Int
        switch item {
        case let section as SidebarSection where section === favorites:
            target = index == NSOutlineViewDropOnItemIndex ? favorites.items.count : index
        case let favorite as SidebarItem:
            target = favorites.items.firstIndex(of: favorite) ?? favorites.items.count
        default:
            return []
        }
        outlineView.setDropItem(favorites, dropChildIndex: target)
        return isFavorite ? .move : .link
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let pasteboard = info.draggingPasteboard
        let target = index == NSOutlineViewDropOnItemIndex ? favorites.items.count : index
        if let id = pasteboard.pasteboardItems?.first?.string(forType: .kansioFavorite).flatMap(UUID.init(uuidString:)) {
            guard let from = favorites.items.firstIndex(where: { $0.entryID == id }) else { return false }
            FavoritesStore.shared.move(from: from, to: target)
            return true
        }
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        FavoritesStore.shared.pin(urls, at: target) { [weak self] pinned, notFolders in
            if notFolders > 0 { self?.fileList?.showMessage(notFolders == 1 && pinned == 0 ? "Only folders can be pinned to Favorites." : "Pinned \(pinned); only folders can be pinned to Favorites.") }
        }
        return true
    }

    private func menuURL(_ sender: Any?) -> URL? { url(of: (sender as? NSMenuItem)?.representedObject) }

    @objc func openItem(_ sender: Any?) { if let url = menuURL(sender) { onSelect?(url) } }

    @objc func showItemInFinder(_ sender: Any?) { if let url = menuURL(sender) { fileList?.opener.reveal([url]) } }

    @objc func copyItemPath(_ sender: Any?) {
        guard let url = menuURL(sender), let pasteboard = fileList?.pasteboard else { return }
        pasteboard.clearContents()
        pasteboard.setString(url.path(percentEncoded: false), forType: .string)
    }

    @objc func getItemInfo(_ sender: Any?) {
        if let url = menuURL(sender) { InfoWindowController.show(items: [], in: url) }
    }

    /// Creates "New folder" inside, expands the branch and starts renaming it in the tree (undoable).
    @objc func newFolderInItem(_ sender: Any?) {
        guard let url = menuURL(sender) else { return }
        let node = (sender as? NSMenuItem)?.representedObject as? TreeNode
        Task { [weak self] in
            let result = await FileOperations.createFolder(in: url)
            guard let self else { return }
            switch result {
            case .success(let name):
                let created = url.appending(path: name, directoryHint: .isDirectory)
                if let trasher = self.fileList?.trasher {
                    FileUndo.shared.register(UndoStep("New Folder", [.created(created, slot: TrashSlot())]), trasher: trasher)
                }
                self.announce([created])
                guard let node else { return }
                if node.isListed {
                    await self.relistNow(node)
                } else {
                    await self.ensureListed(node)
                }
                if !self.outlineView.isItemExpanded(node) { self.outlineView.expandItem(node) }
                if let child = self.tree.child(of: node, named: name) { self.beginRename(child) }
            case .failure(let error):
                self.fileList?.showMessage("Couldn’t create a folder there. \(error.description)")
            }
        }
    }

    private func relistNow(_ node: TreeNode) async {
        let result = await FolderTreeIO.listFolders(node.url, timeout: node.isNetwork ? .seconds(30) : nil)
        if case .success(let listing) = result { apply(tree.apply(listing.items, realPath: listing.realPath, to: node)) }
    }

    private func announce(_ urls: [URL]) {
        NotificationCenter.default.post(name: .kansioFilesChanged, object: self, userInfo: ["urls": urls])
    }

    // MARK: Rename in the tree (after New Folder)

    /// The node being renamed (self-test).
    var renamingNode: TreeNode? { renaming?.node }

    func beginRename(_ node: TreeNode) {
        let row = outlineView.row(forItem: node)
        guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? TreeCellView else { return }
        outlineView.scrollRowToVisible(row)
        let field = cell.beginEditing()
        renaming = (node, field)
        field.delegate = self
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard renaming?.field === control else { return false }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)): endRename(commit: false); return true
        case #selector(NSResponder.insertNewline(_:)): endRename(commit: true); return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let renaming, notification.object as AnyObject? === renaming.field else { return }
        endRename(commit: true)
    }

    /// Ends the rename; `commit` renames on disk (RENAME_EXCL, undoable) unless the name didn't change.
    func endRename(commit: Bool) {
        guard let (node, field) = renaming else { return }
        renaming = nil
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        view.window?.makeFirstResponder(outlineView)
        (field.superview as? TreeCellView)?.endEditing()
        guard commit, !newName.isEmpty, newName != node.name, let parent = node.parent else { return }
        let oldURL = node.url
        Task { [weak self] in
            let result = await FileOperations.rename(oldURL, to: newName)
            guard let self else { return }
            switch result {
            case .success(let newURL):
                if let trasher = self.fileList?.trasher {
                    FileUndo.shared.register(UndoStep("Rename", [.renamed(from: oldURL, to: newURL)]), trasher: trasher)
                }
                self.announce([oldURL, newURL])
                await self.relistNow(parent)
            case .failure(let error):
                self.fileList?.showMessage("Couldn’t rename “\(node.name)”. \(error.description)")
            }
        }
    }

    // MARK: Cells

    private static func makeHeaderCell() -> NSTableCellView {
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 180, height: 20))
        cell.identifier = headerIdentifier
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 2, y: 2, width: 176, height: 16)
        label.autoresizingMask = [.width]
        cell.addSubview(label)
        cell.textField = label
        return cell
    }

    /// Visible titles per section (for tests/measurement output).
    var debugTitles: [String] {
        favorites.items.map { "Favorites/\($0.title)" } + tree.roots.map { "Locations/\($0.displayName)" }
    }

    /// Favorites rows (self-test).
    func favoriteItem(titled title: String) -> SidebarItem? { favorites.items.first { $0.title == title } }
    func favoriteRow(titled title: String) -> Int? {
        favoriteItem(titled: title).map { outlineView.row(forItem: $0) }.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// The tree node selected (self-test/measurement).
    var selectedNode: TreeNode? { outlineView.item(atRow: outlineView.selectedRow) as? TreeNode }
    /// Items with the light "you are somewhere in here" mark (self-test).
    var markedItems: [AnyObject] { marked }
}

/// Folder paths the tree has listed, readable from the watcher's queue: events for anything else
/// are dropped there, before they reach the main thread.
final class TreeWatchFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    private var pendingChanged = Set<String>()
    private var pendingRescans = Set<String>()
    private var scheduled = false

    func update(_ paths: Set<String>) { lock.withLock { self.paths = paths } }

    /// Keeps the relevant part of `event` and delivers everything gathered at most every 150 ms.
    func submit(_ event: TreeWatcher.Event, deliver: @escaping @Sendable ([TreeWatcher.Event]) -> Void) {
        guard let relevant = relevant(event) else { return }
        let schedule: Bool = lock.withLock {
            switch relevant {
            case .changed(let paths): pendingChanged.formUnion(paths)
            case .rescan(let path): pendingRescans.insert(path)
            }
            defer { scheduled = true }
            return !scheduled
        }
        guard schedule else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) { [self] in
            let batch: [TreeWatcher.Event] = lock.withLock {
                defer { pendingChanged = []; pendingRescans = []; scheduled = false }
                return pendingRescans.map { .rescan($0) } + (pendingChanged.isEmpty ? [] : [.changed(pendingChanged)])
            }
            if !batch.isEmpty { deliver(batch) }
        }
    }

    /// The part of `event` the tree cares about: listed folders and their direct children (a child
    /// whose contents changed may have gained or lost subfolders). Nil when nothing is relevant.
    func relevant(_ event: TreeWatcher.Event) -> TreeWatcher.Event? {
        lock.withLock {
            switch event {
            case .changed(let changed):
                let keep = changed.filter { paths.contains($0) || paths.contains(($0 as NSString).deletingLastPathComponent) }
                return keep.isEmpty ? nil : .changed(keep)
            case .rescan(let path):
                let prefix = path == "/" ? "/" : path + "/"
                return paths.contains { $0 == path || $0.hasPrefix(prefix) } ? event : nil
            }
        }
    }
}

/// Return and ←/→ follow Explorer; everything else is NSOutlineView's.
@MainActor
final class SidebarOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    var onArrow: ((_ right: Bool) -> Bool)?
    /// True while a key press is being handled: a selection change then came from the keyboard.
    private(set) var isHandlingKey = false

    override func keyDown(with event: NSEvent) {
        isHandlingKey = true
        defer { isHandlingKey = false }
        switch event.keyCode {
        case 36, 76: onReturn?()
        case 124 where onArrow?(true) == true: break
        case 123 where onArrow?(false) == true: break
        default: super.keyDown(with: event)
        }
    }
}

/// Draws the light "the current folder is in here" mark (the selection is drawn by AppKit).
@MainActor
final class SidebarRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarRow")
    weak var node: TreeNode?
    var isMarked = false {
        didSet { if oldValue != isMarked { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isMarked, !isSelected else { return }
        NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds.safelyInset(dx: 10, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

/// One sidebar row's content, drawn by the cell itself (icon + name; warning icon after a failed
/// listing; a spinner while listing). Like `FileCellView`: a reveal brings a screenful of new rows
/// at once, and an image view + text field per row (with Auto Layout and vibrancy updates) made
/// that a > 16 ms frame. The spinner and the rename field are created only when needed.
@MainActor
final class TreeCellView: NSTableCellView {
    private var title = ""
    private var image: NSImage?
    private var tint: NSColor = .controlAccentColor
    private var dimmed = false
    private var spinner: NSProgressIndicator?
    private var editor: NSTextField?

    static let folderImage = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    /// A folder with a small arrow: a symlink to a folder.
    static let linkImage: NSImage? = {
        guard let folder = NSImage(systemSymbolName: "folder", accessibilityDescription: "Link"),
              let arrow = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil) else { return nil }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            folder.draw(in: rect)
            let badge = NSRect(x: 0, y: 0, width: 8, height: 8)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: badge).fill()
            arrow.draw(in: badge.insetBy(dx: 1, dy: 1), from: .zero, operation: .destinationOut, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        self.identifier = identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: max(0, newSize.width), height: max(0, newSize.height)))
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        // Laid out by hand, clamped (deep rows can be narrower than the text offset).
        spinner?.frame = iconRect
        editor?.frame = textRect.insetBy(dx: -3, dy: -2)
    }

    func configure(title: String, image: NSImage?, dimmed: Bool, spinning: Bool, error: String?) {
        let newImage = error == nil ? image : NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Error")
        let newTint: NSColor = error == nil ? .controlAccentColor : .systemOrange
        if title != self.title || newImage !== self.image || newTint != tint || dimmed != self.dimmed {
            self.title = title
            self.image = newImage
            tint = newTint
            self.dimmed = dimmed
            needsDisplay = true
        }
        toolTip = error
        setAccessibilityLabel(error.map { "\(title), \($0)" } ?? title)
        if spinning, spinner == nil {
            let indicator = NSProgressIndicator(frame: iconRect)
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.isDisplayedWhenStopped = false
            addSubview(indicator)
            indicator.startAnimation(nil)
            spinner = indicator
            needsDisplay = true
        } else if !spinning, let indicator = spinner {
            indicator.stopAnimation(nil)
            indicator.removeFromSuperview()
            spinner = nil
            needsDisplay = true
        }
    }

    // MARK: Drawing

    private var iconRect: NSRect { NSRect(x: 2, y: ((bounds.height - 16) / 2).rounded(), width: min(16, max(0, bounds.width - 2)), height: 16) }
    private var textRect: NSRect { NSRect(x: 24, y: 0, width: max(0, bounds.width - 26), height: bounds.height) }

    private static var tinted: [String: NSImage] = [:]

    /// Template symbols drawn in a colour (cached per image and colour).
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        guard image.isTemplate else { return image }
        let key = "\(ObjectIdentifier(image).hashValue)-\(color)"
        if let hit = tinted[key] { return hit }
        let result = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted[key] = result
        return result
    }

    private static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    override func draw(_ dirtyRect: NSRect) {
        let emphasized = backgroundStyle == .emphasized
        let alpha: CGFloat = dimmed ? 0.55 : 1
        if spinner == nil, let image {
            let color: NSColor = emphasized ? .alternateSelectedControlTextColor : tint
            effectiveAppearance.performAsCurrentDrawingAppearance {
                Self.tinted(image, color).draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: alpha,
                                               respectFlipped: true, hints: nil)
            }
        }
        guard editor == nil, !title.isEmpty, textRect.width > 4 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let color: NSColor = (emphasized ? NSColor.alternateSelectedControlTextColor : .labelColor).withAlphaComponent(alpha)
        let lineHeight = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
        var rect = textRect
        rect.origin.y = floor((bounds.height - lineHeight) / 2)
        rect.size.height = lineHeight
        (title as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: [.font: Self.font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    // MARK: Renaming (a text field only while editing)

    /// Shows an editable field over the name and returns it.
    func beginEditing() -> NSTextField {
        let field = NSTextField(string: title)
        field.font = Self.font
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.focusRingType = .default
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.frame = textRect.insetBy(dx: -3, dy: -2)
        addSubview(field)
        editor = field
        textField = field
        needsDisplay = true
        return field
    }

    func endEditing() {
        editor?.removeFromSuperview()
        editor = nil
        textField = nil
        needsDisplay = true
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { title }
}

extension NSPasteboard.PasteboardType {
    /// A Favorites row being dragged within the sidebar (its entry id).
    static let kansioFavorite = NSPasteboard.PasteboardType("dev.kansio.favorite")
}
