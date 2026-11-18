import AppKit
import FileSystemKit

/// One browser window (P1-3 redesigned 2026-11-16, Explorer layout): the title-bar row holds the tab
/// strip; under it, the selected tab's Back/Forward/Up, path and search; then navigation pane | list.
/// Tabs live in this one window — switching hides one list view and shows another — and a tab that
/// isn't shown pauses (no listing, watching or icon loading; FSEvents catches it up when shown).
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation, NSMenuDelegate {
    private(set) var tabs: [FileListViewController] = []
    private(set) var selectedIndex = 0
    /// The selected tab's list (everything window-level acts on it).
    var fileList: FileListViewController { tabs[selectedIndex] }
    let sidebar = SidebarViewController()
    let addressBar = AddressBarController()
    let tabStrip = TabStripView(frame: NSRect(x: 0, y: 0, width: 600, height: TabStripView.height))
    private let split = NSSplitViewController()
    private let container = TabContainerViewController()
    private let backButton = MainWindowController.navigationButton(symbol: "chevron.left", label: "Back")
    private let forwardButton = MainWindowController.navigationButton(symbol: "chevron.right", label: "Forward")
    private let upButton = MainWindowController.navigationButton(symbol: "arrow.up", label: "Up")

    private static let tabsID = NSToolbarItem.Identifier("tabs")
    /// Counts the folder shown here once it has stayed a while (most used folders).
    private let usageTracker = FolderUsageTracker()

    /// Called when the window closes, after all its tabs' work was stopped.
    var onClose: (() -> Void)?

    convenience init(initialFolder: URL, startsActive: Bool = true) {
        self.init(tabs: [FileListViewController(folder: initialFolder, startsActive: startsActive)])
    }

    /// A window with these tabs (the first selected) — also how a tab moves to a new window.
    init(tabs initialTabs: [FileListViewController]) {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        // Not full height: the title-bar row (tabs) and the address row span the whole window, as in Explorer.
        sidebarItem.allowsFullHeightLayout = false
        let contentItem = NSSplitViewItem(viewController: container)
        contentItem.minimumThickness = 320
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        LaunchTrace.mark("  split items")
        split.splitView.autosaveName = "MainSplit"

        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        LaunchTrace.mark("  NSWindow")
        window.contentViewController = split
        LaunchTrace.mark("  contentViewController (loads sidebar + list views)")
        window.setContentSize(NSSize(width: 1100, height: 660))
        window.minSize = NSSize(width: 560, height: 320)
        window.center()
        window.setFrameAutosaveName("MainWindow") // the first window; later ones cascade from it
        window.tabbingMode = .disallowed // our own tabs (one window), not AppKit's tab windows
        window.titleVisibility = .hidden // the tab strip shows the folders
        window.toolbarStyle = .unifiedCompact
        super.init(window: window)
        window.delegate = self
        window.onMouseBack = { [weak self] in self?.fileList.goBack() }
        window.onMouseForward = { [weak self] in self?.fileList.goForward() }
        window.onMiddleClick = { [weak self] event in self?.middleClick(event) ?? false }
        // Minimized / app hidden: the shown tab pauses too.
        let center = NotificationCenter.default
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            center.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateActivity() }
            }
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateActivity() }
            }
        }

        backButton.target = self
        backButton.action = #selector(goBack(_:))
        forwardButton.target = self
        forwardButton.action = #selector(goForward(_:))
        upButton.target = self
        upButton.action = #selector(goUp(_:))
        // Right-click Back/Forward: jump several steps (Explorer's recent-locations dropdown).
        for button in [backButton, forwardButton] {
            let menu = NSMenu()
            menu.delegate = self
            button.menu = menu
        }

        window.addTitlebarAccessoryViewController(addressBar)
        addressBar.setLeadingButtons([backButton, forwardButton, upButton])
        addressBar.volumes = StartupPrefetch.takeVolumes() ?? []
        addressBar.onNavigate = { [weak self] url, select in self?.fileList.navigate(to: url, select: select) }
        addressBar.onFinishEditing = { [weak self] in self?.fileList.focusList() }
        addressBar.includeHidden = { [weak self] in self?.fileList.showsHiddenFiles ?? false }
        addressBar.onSearch = { [weak self] text in self?.fileList.setSearch(text) }
        addressBar.onSearchReturn = { [weak self] in self?.fileList.focusList() }
        addressBar.onSearchEscape = { [weak self] in self?.fileList.focusList() }
        addressBar.onSearchFocus = { [weak self] in self?.fileList.prepareSearchIndex() }

        tabStrip.onSelect = { [weak self] index in self?.selectTab(at: index) }
        tabStrip.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabStrip.onCloseOthers = { [weak self] index in self?.closeOtherTabs(keeping: index) }
        tabStrip.onMoveToNewWindow = { [weak self] index in self?.moveTabToNewWindow(at: index) }
        tabStrip.onMove = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        tabStrip.onNewTab = { [weak self] in self?.newTab(nil) }
        tabStrip.onMostUsed = { [weak self] button in self?.showMostUsedMenu(from: button) }
        tabStrip.dropTarget = { [weak self] index in self.flatMap { index < $0.tabs.count ? $0.tabs[index] : nil } }
        tabStrip.onTabDragBegan = { [weak self] index, grab in self?.tabDragBegan(at: index, grab: grab) }
        tabStrip.onTabDragOver = { [weak self] slot in self?.tabDragOver(slot: slot) ?? false }
        tabStrip.onTabDrop = { [weak self] slot in self?.tabDropped(slot: slot) ?? false }
        tabStrip.onTabDragEnded = { [weak self] point, accepted in self?.tabDragEnded(at: point, accepted: accepted) }

        let toolbar = NSToolbar(identifier: "Tabs")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        LaunchTrace.mark("  toolbar")

        sidebar.onSelect = { [weak self] url in self?.fileList.navigate(to: url) }
        sidebar.onReturn = { [weak self] in self?.fileList.focusList() }
        sidebar.listHasRows = { [weak self] in self?.fileList.lastDisplayEvent != nil }
        sidebar.onVolumeRemoved = { [weak self] volume in self?.volumeRemoved(volume) }
        let traceVolumes = ProcessInfo.processInfo.environment["KANSIO_TRACE"] != nil
        sidebar.onVolumesChanged = { [weak self] volumes in
            self?.addressBar.volumes = volumes
            if traceVolumes {
                print("sidebar volumes: \(volumes.map(\.name))")
                fflush(stdout)
            }
        }
        for list in initialTabs { attach(list) }
        tabs = initialTabs
        selectTab(at: 0, force: true, usage: .opened)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Tabs (one window)

    private func attach(_ list: FileListViewController) {
        list.onStateChange = { [weak self, weak list] state in
            guard let self, let list else { return }
            if list === self.fileList { self.update(for: state) }
            self.updateTabStrip()
        }
        list.onSearchEnded = { [weak self, weak list] in
            if let self, list === self.fileList { self.addressBar.clearSearch() }
        }
    }

    /// Shows tab `index`: the others pause; the navigation pane, address bar and search follow it.
    /// `usage`: how showing it counts for the most used folders (a new tab is an opened folder).
    func selectTab(at index: Int, force: Bool = false, usage: FolderUsageStore.Event = .tabSwitch) {
        guard tabs.indices.contains(index), force || index != selectedIndex else { return }
        let previous = tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil
        selectedIndex = index
        let list = tabs[index]
        Trace.time("show view") { container.show(list, hiding: tabs) }
        if let previous, previous !== list { Trace.time("pause previous") { previous.setActive(false) } }
        sidebar.fileList = list
        addressBar.setSearchText(list.searchQuery)
        Trace.time("resume") { updateActivity() }
        noteFolderShown(usage) // before update(for:), which would count it as opened
        Trace.time("update chrome") { update(for: list.state) }
        Trace.time("tab strip") { updateTabStrip() }
        if window?.firstResponder is NSTableView || window?.firstResponder === window { list.focusList() }
    }

    /// Adds a tab after the selected one. `background`: not selected (lists when first shown).
    @discardableResult
    func addTab(at url: URL, background: Bool = false) -> FileListViewController {
        let list = FileListViewController(folder: url, startsActive: false)
        attach(list)
        let index = min(selectedIndex + 1, tabs.count)
        tabs.insert(list, at: index)
        if background {
            if index <= selectedIndex { selectedIndex += 1 }
            container.show(fileList, hiding: tabs) // loads the new tab's view (hidden), keeps this one shown
            updateTabStrip()
        } else {
            selectTab(at: index, force: true, usage: .opened)
        }
        return list
    }

    /// Closes a tab and stops its work; the last tab closes the window.
    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        guard tabs.count > 1 else { window?.performClose(nil); return }
        let list = tabs.remove(at: index)
        list.shutdown()
        container.remove(list)
        if index < selectedIndex || selectedIndex >= tabs.count { selectedIndex = max(0, selectedIndex - 1) }
        selectTab(at: min(index < selectedIndex ? selectedIndex : min(index, tabs.count - 1), tabs.count - 1), force: true)
    }

    private func closeOtherTabs(keeping index: Int) {
        guard tabs.indices.contains(index) else { return }
        let keep = tabs[index]
        for list in tabs where list !== keep {
            list.shutdown()
            container.remove(list)
        }
        tabs = [keep]
        selectTab(at: 0, force: true)
    }

    private func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        let selected = fileList
        tabs.insert(tabs.remove(at: from), at: to)
        selectedIndex = tabs.firstIndex { $0 === selected } ?? 0
        updateTabStrip()
    }

    /// The tab leaves this window for a new one (its folder, history and selection go with it).
    func moveTabToNewWindow(at index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        WindowManager.shared.openWindow(adopting: detachTab(at: index), cascadingFrom: window)
    }

    // MARK: Tabs between windows (tear-off, drop on another window's strip, Merge All Windows)

    /// A tab being dragged out of a strip. `grab`: where it was grabbed, in window coordinates as if it were the
    /// first tab (so a torn-off window appears with its tab under the pointer).
    struct DraggedTab {
        weak var from: MainWindowController?
        let list: FileListViewController
        let grab: NSPoint
    }

    /// The tab drag in progress (one at a time; only within Kansio).
    static var draggedTab: DraggedTab?

    private func tabDragBegan(at index: Int, grab: NSPoint) {
        guard tabs.indices.contains(index) else { return }
        let itemX = tabStrip.itemViews.indices.contains(index) ? tabStrip.itemViews[index].frame.minX : 0
        Self.draggedTab = DraggedTab(from: self, list: tabs[index], grab: NSPoint(x: grab.x - itemX, y: grab.y))
    }

    /// Over this window's strip: its own tab reorders live; another window's tab may drop here.
    func tabDragOver(slot: Int) -> Bool {
        guard let drag = Self.draggedTab, drag.from != nil else { return false }
        if drag.from === self, let from = tabs.firstIndex(where: { $0 === drag.list }) {
            let to = min(slot > from ? slot - 1 : slot, tabs.count - 1)
            if to != from { moveTab(from: from, to: to) }
        }
        return true
    }

    /// Dropped on this window's strip: a tab from another window joins this one at `slot`.
    func tabDropped(slot: Int) -> Bool {
        guard let drag = Self.draggedTab, let source = drag.from else { return false }
        guard source !== self else { return true } // reordered while hovering
        guard let index = source.tabs.firstIndex(where: { $0 === drag.list }) else { return false }
        Self.draggedTab = nil
        adoptTab(source.detachTab(at: index), at: slot, select: true)
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    /// The drag ended. On nothing that takes a tab: it becomes a window of its own there (a window's only tab
    /// moves its window instead).
    func tabDragEnded(at screenPoint: NSPoint, accepted: Bool) {
        defer { Self.draggedTab = nil }
        guard !accepted, let drag = Self.draggedTab, drag.from === self, let window,
              let index = tabs.firstIndex(where: { $0 === drag.list }) else { return }
        let topLeft = NSPoint(x: screenPoint.x - drag.grab.x, y: screenPoint.y + window.frame.height - drag.grab.y)
        if tabs.count == 1 {
            window.setFrameTopLeftPoint(topLeft)
            return
        }
        let list = detachTab(at: index)
        WindowManager.shared.openWindow(adopting: list, cascadingFrom: window, topLeft: topLeft)
    }

    /// Takes tab `index` out of this window, paused, without stopping its work for good (it moves to another
    /// window). The last tab leaving closes the window.
    @discardableResult
    func detachTab(at index: Int) -> FileListViewController {
        if tabs.count == 1 { window?.makeFirstResponder(nil) } // ends any editing while the tab is still here
        let list = tabs.remove(at: index)
        list.setActive(false)
        list.onStateChange = nil
        list.onSearchEnded = nil
        container.remove(list)
        if tabs.isEmpty {
            window?.orderOut(nil)
            window?.close() // nothing left to stop: the tabs went elsewhere
        } else {
            if index <= selectedIndex { selectedIndex = max(0, selectedIndex - 1) }
            selectTab(at: selectedIndex, force: true)
        }
        return list
    }

    /// A tab from another window joins this one at `slot`.
    func adoptTab(_ list: FileListViewController, at slot: Int, select: Bool) {
        attach(list)
        let index = min(max(0, slot), tabs.count)
        tabs.insert(list, at: index)
        if index <= selectedIndex { selectedIndex += 1 }
        if select {
            selectTab(at: index, force: true)
        } else {
            list.view.isHidden = true
            updateTabStrip()
        }
    }

    /// Window ▸ Merge All Windows: every other window's tabs move into this one, after its own (in window
    /// order); this window's selected tab stays selected.
    @objc func mergeAllWindows(_ sender: Any?) {
        for other in WindowManager.shared.controllers where other !== self {
            while !other.tabs.isEmpty { adoptTab(other.detachTab(at: 0), at: tabs.count, select: false) }
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Window ▸ Move Tab to New Window (the selected tab).
    @objc func moveSelectedTabToNewWindow(_ sender: Any?) { moveTabToNewWindow(at: selectedIndex) }

    private func updateTabStrip() {
        tabStrip.update(tabs.enumerated().map { i, list in
            let url = list.folder
            let path = url.path(percentEncoded: false)
            let title = list.isSearching ? "Search: \(list.searchQuery)" : TrashService.title(for: url)
            return TabStripView.Tab(title: title, path: path, isSelected: i == selectedIndex)
        })
    }

    /// Minimized or app hidden: the shown tab pauses too; the others are always paused.
    var isInBackground: Bool {
        guard let window else { return true }
        return window.isMiniaturized || NSApp.isHidden
    }

    static var activityUpdates = 0
    /// Main-thread time spent pausing/resuming tabs (measurement).
    static var activityTime: Duration = .zero

    func updateActivity() {
        Self.activityUpdates += 1
        let start = ContinuousClock.now
        defer { Self.activityTime += ContinuousClock.now - start }
        let active = !isInBackground
        for (i, list) in tabs.enumerated() { list.setActive(active && i == selectedIndex) }
        sidebar.setActive(active)
    }

    /// ⌃Tab / ⌃⇧Tab.
    @objc func showNextTab(_ sender: Any?) { selectTab(offset: 1) }
    @objc func showPreviousTab(_ sender: Any?) { selectTab(offset: -1) }

    private func selectTab(offset: Int) {
        guard tabs.count > 1 else { return }
        selectTab(at: (selectedIndex + offset + tabs.count) % tabs.count)
    }

    func windowWillClose(_ notification: Notification) {
        usageTracker.stop()
        tabs.forEach { $0.shutdown() }
        sidebar.shutdown()
        onClose?()
    }

    /// ⌘T: a new tab at Home (Explorer), selected.
    @objc func newTab(_ sender: Any?) {
        addTab(at: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// ⌘N: a new window showing this folder (Explorer).
    @objc func newWindow(_ sender: Any?) {
        WindowManager.shared.openWindow(at: fileList.folder, cascadingFrom: window)
    }

    /// ⌘W: closes the selected tab (or the window when it's the last).
    @objc func closeTab(_ sender: Any?) { closeTab(at: selectedIndex) }

    /// ⇧⌘W: closes the window with all its tabs.
    @objc func closeWindowAndTabs(_ sender: Any?) { window?.performClose(sender) }

    func openInNewTab(_ url: URL, background: Bool = false) {
        addTab(at: url, background: background)
    }

    func openInNewWindow(_ url: URL) {
        WindowManager.shared.openWindow(at: url, cascadingFrom: window)
    }

    /// Middle-click on a folder (list or navigation pane): open it in a background tab (Explorer).
    private func middleClick(_ event: NSEvent) -> Bool {
        if let hit = window?.contentView?.superview?.hitTest(event.locationInWindow), hit.isDescendant(of: tabStrip) {
            return false // the tab handles it (closes)
        }
        guard let url = folderURL(at: event.locationInWindow) else { return false }
        openInNewTab(url, background: true)
        return true
    }

    private func folderURL(at point: NSPoint) -> URL? {
        guard let hit = window?.contentView?.hitTest(point) else { return nil }
        let table = fileList.tableForTesting
        if hit.isDescendant(of: table) {
            let row = table.row(at: table.convert(point, from: nil))
            return fileList.folderURL(atRow: row)
        }
        let outline = sidebar.outlineView
        if hit.isDescendant(of: outline) {
            return sidebar.folderURL(atRow: outline.row(at: outline.convert(point, from: nil)))
        }
        return nil
    }

    /// Text editing (rename field, address bar) keeps its own undo; everything else uses the
    /// app-wide file-operation history.
    private let textUndoManager = UndoManager()

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        window.firstResponder is NSTextView ? textUndoManager : FileUndo.shared.manager
    }

    private func update(for state: FileListViewController.State) {
        guard let window else { return }
        noteFolderShown(.opened) // a no-op unless the folder changed
        let url = state.folder
        window.title = TrashService.title(for: url) // Window menu, Mission Control
        window.subtitle = "" // counts live in the status bar (M14)
        sidebar.showCurrentFolder(url)
        addressBar.show(folder: url)
        backButton.isEnabled = state.canGoBack
        forwardButton.isEnabled = state.canGoForward
        upButton.isEnabled = state.canGoUp
    }

    /// The volume we're browsing was ejected: go Home and say why (inline, no alert).
    private func volumeRemoved(_ volume: Volume) {
        defer { fileList.forgetHistory { volume.contains(path: $0.path(percentEncoded: false)) } }
        guard volume.contains(path: fileList.folder.path(percentEncoded: false)) else { return }
        if ProcessInfo.processInfo.environment["KANSIO_TRACE"] != nil { print("ejected while browsing: \(volume.name) → Home"); fflush(stdout) }
        fileList.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
        fileList.showMessage("“\(volume.name)” was ejected.")
    }

    // MARK: Most used folders

    private func noteFolderShown(_ event: FolderUsageStore.Event) {
        guard tabs.indices.contains(selectedIndex) else { return }
        usageTracker.shown(fileList, event) { [weak self] in
            guard let self, self.tabs.indices.contains(self.selectedIndex) else { return nil }
            return self.fileList
        }
    }

    /// The ⌄ after "+": the most used folders; choosing one opens it in a new tab.
    func showMostUsedMenu(from button: NSView) {
        let menu = mostUsedMenu()
        let y = button.isFlipped ? button.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: button)
    }

    func mostUsedMenu() -> NSMenu {
        let menu = NSMenu(title: "Most Used Folders")
        FolderUsageStore.shared.fill(menu, target: self, action: #selector(openMostUsed(_:)))
        return menu
    }

    @objc func openMostUsed(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        addTab(at: url)
    }

    // MARK: Zoom (View menu, ⌘-scroll over the list)

    @objc func makeTextBigger(_ sender: Any?) { if !ViewSettings.shared.stepTextSize(1) { NSSound.beep() } }
    @objc func makeTextSmaller(_ sender: Any?) { if !ViewSettings.shared.stepTextSize(-1) { NSSound.beep() } }
    @objc func makeTextActualSize(_ sender: Any?) { ViewSettings.shared.listTextSize = ViewSettings.defaultTextSize }
    @objc func setListDensity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let density = ViewSettings.Density(rawValue: raw) else { return }
        ViewSettings.shared.listDensity = density
    }

    // MARK: Go menu

    enum Favorite: Int { case home, desktop, documents, downloads, applications }

    @objc func goToFavorite(_ sender: NSMenuItem) {
        let fm = FileManager.default
        func dir(_ d: FileManager.SearchPathDirectory) -> URL { fm.urls(for: d, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser }
        let url: URL = switch Favorite(rawValue: sender.tag) {
        case .desktop: dir(.desktopDirectory)
        case .documents: dir(.documentDirectory)
        case .downloads: dir(.downloadsDirectory)
        case .applications: URL(filePath: "/Applications", directoryHint: .isDirectory)
        default: fm.homeDirectoryForCurrentUser
        }
        fileList.navigate(to: url)
        fileList.focusList()
    }

    // MARK: Navigation actions (window controller = in the responder chain whichever pane has focus)

    @objc func goBack(_ sender: Any?) { fileList.goBack() }
    @objc func goForward(_ sender: Any?) { fileList.goForward() }
    @objc func goUp(_ sender: Any?) { fileList.goUp() }
    @objc func toggleHiddenFiles(_ sender: Any?) { fileList.toggleHiddenFiles() }
    @objc func toggleStatusBar(_ sender: Any?) { fileList.setStatusBarVisible(!ViewSettings.shared.showStatusBar) }
    /// View ▸ Columns works whichever pane has focus.
    @objc func toggleColumn(_ sender: Any?) { fileList.toggleColumn(sender) }
    @objc func resetColumns(_ sender: Any?) { fileList.resetColumns(sender) }
    /// ⇧⌘N works whichever pane has focus (it creates in the current folder).
    @objc func newFolder(_ sender: Any?) {
        fileList.focusList()
        fileList.newFolder(sender)
    }

    /// ⌘L / ⇧⌘G: edit the path in the address bar.
    @objc func editLocation(_ sender: Any?) { addressBar.beginEditing() }

    /// ⌘F: search this folder and its subfolders.
    @objc func find(_ sender: Any?) { addressBar.focusSearch() }

    /// ⌥⌘F: the search filters popover (size, date modified).
    @objc func showSearchFilters(_ sender: Any?) { addressBar.toggleSearchFilters(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let state = fileList.state
        switch menuItem.action {
        case #selector(goBack(_:)): return state.canGoBack
        case #selector(goForward(_:)): return state.canGoForward
        case #selector(goUp(_:)): return state.canGoUp
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = fileList.showsHiddenFiles ? .on : .off
            return true
        case #selector(toggleStatusBar(_:)):
            menuItem.title = ViewSettings.shared.showStatusBar ? "Hide Status Bar" : "Show Status Bar"
            return true
        case #selector(toggleColumn(_:)): return fileList.validateColumnItem(menuItem)
        case #selector(closeTab(_:)):
            menuItem.title = tabs.count > 1 ? "Close Tab" : "Close Window"
            return true
        case #selector(closeWindowAndTabs(_:)), #selector(showNextTab(_:)), #selector(showPreviousTab(_:)),
             #selector(moveSelectedTabToNewWindow(_:)):
            return tabs.count > 1
        case #selector(mergeAllWindows(_:)): return WindowManager.shared.controllers.count > 1
        case #selector(makeTextBigger(_:)):
            return ViewSettings.shared.listTextSize < ViewSettings.textSizes.last!
        case #selector(makeTextSmaller(_:)):
            return ViewSettings.shared.listTextSize > ViewSettings.textSizes.first!
        case #selector(makeTextActualSize(_:)):
            return ViewSettings.shared.listTextSize != ViewSettings.defaultTextSize
        case #selector(setListDensity(_:)):
            menuItem.state = menuItem.representedObject as? String == ViewSettings.shared.listDensity.rawValue ? .on : .off
            return true
        default: return true
        }
    }

    /// Builds the Back/Forward history menu when it's about to open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let isBack = menu === backButton.menu
        let entries = isBack ? Array(fileList.history.back.reversed()) : fileList.history.forward
        for (i, entry) in entries.prefix(20).enumerated() {
            let item = menu.addItem(withTitle: Self.displayTitle(entry.url), action: #selector(jumpInHistory(_:)), keyEquivalent: "")
            item.target = self
            item.tag = isBack ? -(i + 1) : i + 1
            item.toolTip = entry.url.path(percentEncoded: false)
        }
    }

    @objc private func jumpInHistory(_ sender: NSMenuItem) {
        if sender.tag < 0 { fileList.goBack(-sender.tag) } else { fileList.goForward(sender.tag) }
    }

    private static func displayTitle(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        if path == "/" { return "/" }
        if url.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL { return "Home" }
        return TrashService.title(for: url)
    }

    // MARK: Toolbar: the tab strip fills the title-bar row

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.tabsID] }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.tabsID] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.tabsID else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        // A width range (min < max) makes the item flexible: it fills the row next to the traffic lights.
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.setContentHuggingPriority(.init(1), for: .horizontal)
        NSLayoutConstraint.activate([
            tabStrip.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            tabStrip.widthAnchor.constraint(lessThanOrEqualToConstant: 6000),
            tabStrip.heightAnchor.constraint(equalToConstant: TabStripView.height),
        ])
        item.view = tabStrip
        item.label = "Tabs"
        item.visibilityPriority = .high
        return item
    }

    private static func navigationButton(symbol: String, label: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: nil)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isEnabled = false
        return button
    }
}

/// Window that routes the mouse's side buttons (button 4 = Back, 5 = Forward) to history,
/// wherever the pointer is: list, sidebar, toolbar or empty space. Handled here, before
/// hit-testing, because no individual view would otherwise see them consistently.
@MainActor
final class BrowserWindow: NSWindow {
    var onMouseBack: (() -> Void)?
    var onMouseForward: (() -> Void)?
    /// Middle button: true when handled (opened a folder in a new tab).
    var onMiddleClick: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .otherMouseDown {
            switch event.buttonNumber {
            case 2: if onMiddleClick?(event) == true { return } // middle button
            case 3: onMouseBack?(); return     // "button 4" (0-based 3)
            case 4: onMouseForward?(); return  // "button 5"
            default: break
            }
        }
        if event.type == .otherMouseUp, event.buttonNumber == 3 || event.buttonNumber == 4 { return }
        super.sendEvent(event)
    }
}
