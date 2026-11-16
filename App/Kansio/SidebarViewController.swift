import AppKit
import FileSystemKit

/// Sidebar items must be objects with stable identity (NSOutlineView keys rows by item).
@MainActor
final class SidebarItem: NSObject {
    let title: String
    let url: URL
    let symbol: String
    let volume: Volume?

    init(title: String, url: URL, symbol: String, volume: Volume? = nil) {
        self.title = title
        self.url = url
        self.symbol = symbol
        self.volume = volume
    }

    var path: String { url.path(percentEncoded: false) }
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

/// The navigation pane: Favorites + Volumes, as a source list.
///
/// Volumes are read off the main thread (a stale network mount can block that call) and
/// refreshed on NSWorkspace mount/unmount/rename notifications — never by polling.
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// The user picked an item.
    var onSelect: ((URL) -> Void)?
    /// A volume disappeared (eject/unmount).
    var onVolumeRemoved: ((Volume) -> Void)?
    /// For tests/measurement: fired after the volume list changes.
    var onVolumesChanged: (([Volume]) -> Void)?

    private let outlineView = NSOutlineView()
    private let favorites: SidebarSection
    private let volumesSection = SidebarSection(title: "Volumes", items: [])
    private var sections: [SidebarSection] { [favorites, volumesSection] }
    private var currentPath: String?
    private var isSyncingSelection = false
    private var refreshTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    static let cellIdentifier = NSUserInterfaceItemIdentifier("SidebarCell")
    static let headerIdentifier = NSUserInterfaceItemIdentifier("SidebarHeader")

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        let fm = FileManager.default
        func dir(_ d: FileManager.SearchPathDirectory) -> URL {
            fm.urls(for: d, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser
        }
        favorites = SidebarSection(title: "Favorites", items: [
            SidebarItem(title: "Home", url: fm.homeDirectoryForCurrentUser, symbol: "house"),
            SidebarItem(title: "Desktop", url: dir(.desktopDirectory), symbol: "menubar.dock.rectangle"),
            SidebarItem(title: "Documents", url: dir(.documentDirectory), symbol: "doc"),
            SidebarItem(title: "Downloads", url: dir(.downloadsDirectory), symbol: "arrow.down.circle"),
            SidebarItem(title: "Applications", url: URL(filePath: "/Applications", directoryHint: .isDirectory), symbol: "square.grid.3x3"),
        ])
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        MainActor.assumeIsolated {
            observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        }
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Sidebar"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 0
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityLabel("Sidebar")

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
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
        refreshVolumes()
    }

    /// Re-reads mounted volumes off the main thread and updates the section in place.
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
        self.volumes = volumes
        let old = volumesSection.items
        let removed = old.compactMap(\.volume).filter { o in !volumes.contains { $0.url == o.url } }
        // Keep existing item objects for unchanged volumes (stable identity keeps selection).
        volumesSection.items = volumes.map { v in
            old.first { $0.volume == v } ?? SidebarItem(title: v.name, url: v.url, symbol: Self.symbol(for: v), volume: v)
        }
        if old.map(\.volume) != volumesSection.items.map(\.volume) {
            outlineView.reloadItem(volumesSection, reloadChildren: true)
            syncSelection()
        }
        removed.forEach { onVolumeRemoved?($0) }
        onVolumesChanged?(volumes)
    }

    private static func symbol(for volume: Volume) -> String {
        if volume.isNetwork { return "network" }
        if volume.isRoot || (volume.isInternal && !volume.isEjectable) { return "internaldrive" }
        return "externaldrive"
    }

    /// Highlights the sidebar item for `url` (exact match), or nothing.
    func showCurrentFolder(_ url: URL) {
        let path = url.path(percentEncoded: false)
        currentPath = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        syncSelection()
    }

    private func syncSelection() {
        guard let currentPath else { return }
        let match = sections.flatMap(\.items).first { Self.normalized($0.path) == currentPath }
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        if let match {
            let row = outlineView.row(forItem: match)
            if row >= 0 { outlineView.selectRowIndexes([row], byExtendingSelection: false) }
        } else {
            outlineView.deselectAll(nil)
        }
    }

    private static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Visible titles per section (for tests/measurement output).
    var debugTitles: [String] { sections.flatMap { s in s.items.map { "\(s.title)/\($0.title)" } } }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: sections.count
        case let section as SidebarSection: section.items.count
        default: 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case let section as SidebarSection: section.items[index]
        default: sections[index]
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is SidebarSection }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is SidebarSection }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is SidebarItem }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? SidebarSection {
            let cell = outlineView.makeView(withIdentifier: Self.headerIdentifier, owner: nil) as? NSTableCellView ?? Self.makeHeaderCell()
            cell.textField?.stringValue = section.title
            return cell
        }
        guard let item = item as? SidebarItem else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: nil) as? NSTableCellView ?? Self.makeItemCell()
        cell.textField?.stringValue = item.title
        cell.imageView?.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        cell.setAccessibilityLabel(item.title)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, let item = outlineView.item(atRow: outlineView.selectedRow) as? SidebarItem else { return }
        onSelect?(item.url)
    }

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

    private static func makeItemCell() -> NSTableCellView {
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        cell.identifier = cellIdentifier
        let image = NSImageView(frame: NSRect(x: 2, y: 4, width: 16, height: 16))
        image.imageScaling = .scaleProportionallyDown
        image.contentTintColor = .controlAccentColor
        image.autoresizingMask = [.minYMargin, .maxYMargin]
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 24, y: 4, width: 154, height: 16)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        cell.addSubview(image)
        cell.addSubview(label)
        cell.imageView = image
        cell.textField = label
        return cell
    }
}
